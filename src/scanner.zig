//! Indentation-aware streaming scanner for block-context YAML.
//!
//! Modeled on the structure of libyaml's scanner.c (not its code): a flat
//! loop that emits a stream of structural tokens, driven by an explicit
//! indentation stack and a token queue. The queue exists because two YAML
//! constructs need tokens emitted out of scan order:
//!
//!   1. A decrease in indentation closes one or more block collections at
//!      once, so a single newline can produce several `block_end` tokens.
//!   2. A block collection's start token must appear BEFORE the `key` or
//!      `block_entry` that revealed it (the "roll indent" / simple-key
//!      retroactive insert). We buffer pending tokens and splice the
//!      collection-start ahead of the trigger.
//!
//! Columns are tracked 0-based internally (matching libyaml's indentation
//! arithmetic) and carried 1-based on the internal `RawSpan.col` for the
//! parser's structural decisions. The public `Span` stores byte offsets only;
//! 1-based line/col are derived on demand via `Span.lineCol`.
//!
//! Produces the full token stream: block mappings/sequences, plain and
//! single/double-quoted and literal/folded block scalars, node properties
//! (anchors, aliases, tags), flow collections (`[]`/`{}`), document
//! markers (`---`/`...`), and directives (`%...`). A tab in indentation,
//! an unterminated quote, or nesting past `max_depth` yields an `.invalid`
//! token. Scalar text is recorded as a raw byte span; unescaping, folding,
//! chomping, and tag/handle resolution are the composer's job (the
//! block-scalar header is carried on the token via `block_header`).
//!
//! Inside a flow collection the indentation machinery is suspended: no
//! block_*_start/block_end tokens and no column-driven indent rolling.
//!
//! Allocation-free: the indentation stack and token queue are fixed
//! bounded arrays. Nesting deeper than `max_depth` yields an `.invalid`
//! token rather than allocating or crashing.

const std = @import("std");
const value = @import("value.zig");
/// Public span: offset-only u64, what `Token.span` and re-exports expose.
const Span = value.Span;
/// Internal usize span with incremental line/col: what the queue and all
/// hot-path code carries.
const RawSpan = value.RawSpan;
const satAdd = value.satAdd;

pub const TokenKind = enum {
    stream_start,
    stream_end,
    document_start,
    document_end, // --- and ...
    block_sequence_start,
    block_mapping_start,
    block_end,
    flow_sequence_start,
    flow_sequence_end, // [ ]
    flow_mapping_start,
    flow_mapping_end, // { }
    block_entry,
    flow_entry, // "- " and ","
    key,
    value, // "? " (or implicit) and ": "
    scalar,
    anchor,
    alias,
    tag,
    directive,
    /// A `#` comment, from the `#` to end-of-line (excluding the trailing
    /// line break). Emitted only when the scanner runs in comment mode
    /// (`initWithComments`); the default scan path skips comments entirely.
    comment,
    invalid,
};

pub const ScalarStyle = enum { plain, single, double, literal, folded };

/// Why a scanner produced an `.invalid` token. Carried on the token so the
/// parser can render a specific diagnostic message at the point of failure
/// (the invalid token's span does not always start on the offending byte).
pub const InvalidReason = enum {
    none,
    tab_indentation,
    unterminated_single_quote,
    unterminated_double_quote,
    queue_overflow,
    /// A multi-line plain scalar's continuation line carries a `: ` value
    /// indicator (a mis-indented mapping key); the plain scalar is invalid.
    plain_key_in_continuation,
    /// A block-scalar header (`|`/`>`) is malformed: a zero or multi-digit
    /// indent indicator, or non-comment content after the indicators.
    block_scalar_header,
    /// A `#` comment indicator not preceded by white space (e.g. `a,#x` in
    /// flow, or `"v"#x`): YAML requires a comment to be separated from
    /// preceding content by a space or tab.
    unseparated_comment,
    /// A node property (anchor/tag) standing alone on its line at an open
    /// block mapping's own indent, where the reference parser rejects it
    /// (`seq:\n&anchor\n- a`).
    misindented_property,
    /// A scalar spanning more than one line is used as a block-context
    /// implicit key (`"a\nb": v`); implicit keys must fit on a single line.
    multiline_implicit_key,
    /// A key opening a new block mapping appears mid-line after other content
    /// (`a: b: c`): block mappings do not nest inline after a value indicator.
    nested_block_mapping_inline,
    /// A bare block indicator (`-`/`?`) glued to a flow indicator inside a flow
    /// collection (`[-]`, `[?]`): it cannot begin a plain scalar there.
    bare_indicator_in_flow,
};

/// Chomping mode for a block scalar (`|`/`>`), parsed from the header
/// indicator: `clip` (default, one trailing newline), `strip` (`-`, no
/// trailing newline), `keep` (`+`, all trailing newlines).
pub const Chomp = enum { clip, strip, keep };

/// Block-scalar header info, recorded on the scalar token so the composer
/// can fold/chomp without re-parsing the indicator line. Only meaningful
/// when `style` is `.literal` or `.folded`.
pub const BlockHeader = struct {
    chomp: Chomp = .clip,
    /// Explicit indentation indicator digit (1-9) from the header, if
    /// present; otherwise the composer auto-detects from the first body
    /// line.
    explicit_indent: ?u8 = null,
    /// Absolute column (0-based, in source bytes) that the composer strips
    /// from each body line. The scanner resolves auto-detection and the
    /// parent-relative explicit indicator into this single column so the
    /// composer never needs the surrounding indentation context. Zero when
    /// the body is empty.
    content_indent: u32 = 0,
    /// True when a leading all-blank body line was MORE indented than the
    /// detected content indentation: per YAML 1.2 a block scalar's first
    /// non-empty line must be at least as indented as every preceding empty
    /// line. The parser turns this into a parse error.
    leading_overindent: bool = false,
    /// Byte offset of the `|`/`>` header indicator. The scalar token's span
    /// covers the body only, so the lossless document model uses this to span
    /// the full block-scalar presentation (header through body) for editing.
    header_start: u64 = 0,
};

/// Public token: span offsets are u64, addressing any in-memory input. Line
/// and column are not stored; derive them on demand with `Span.lineCol`. For
/// the internal usize span with incremental line/col, use `nextRaw`.
pub const Token = struct {
    kind: TokenKind,
    span: Span,
    style: ScalarStyle = .plain,
    /// Set only for `.literal`/`.folded` scalar tokens.
    block_header: BlockHeader = .{},
    /// Set only for `.invalid` tokens; classifies the failure.
    invalid_reason: InvalidReason = .none,
};

/// Internal token with usize byte offsets; never narrowed on the hot path.
/// Returned by `nextRaw`; consumed by internal callers (parser, document).
pub const RawToken = struct {
    kind: TokenKind,
    span: RawSpan,
    style: ScalarStyle = .plain,
    block_header: BlockHeader = .{},
    invalid_reason: InvalidReason = .none,
};

pub const Scanner = struct {
    /// Maximum block-collection nesting depth. Deeper input yields an
    /// `.invalid` token. 1024 is well past any realistic document and
    /// keeps the fixed arrays small.
    pub const max_depth = 1024;

    /// A block-context implicit (simple) key is capped at one line and this
    /// many source bytes, per the YAML spec. The bound makes a whole flow
    /// collection used as a block key buffer in O(bound) tokens and
    /// guarantees the candidate scan terminates.
    pub const simple_key_max = 1024;

    /// Queue must hold the worst-case burst from a single fetch. Two cases
    /// drive it: every open collection closing (max_depth `block_end`s) plus
    /// the trigger tokens, and a whole flow collection buffered as a block
    /// simple-key candidate (one token per byte at worst, capped at
    /// `simple_key_max`). The constant margin covers the splice/trigger
    /// tokens and stream_end.
    const queue_cap = max_depth + simple_key_max + 16;

    input: []const u8,
    /// Byte offset cursor; usize so scanning works past 4 GiB without
    /// narrowing. Stored/exposed spans saturate or guard at their boundary.
    pos: usize = 0,
    line: u32 = 1,
    /// 0-based column of `pos` on the current line.
    col: u32 = 0,

    /// Columns (0-based) at which each currently-open block collection
    /// began. The -1 sentinel at the base is the stream level, against
    /// which the first real indentation is compared.
    indents: [max_depth + 1]i64 = undefined,
    indents_len: usize = 0,

    /// Whether each open block collection is a mapping (true) or a sequence
    /// (false). Parallel to `indents`. Lets a bare `:`/`?` indicator at the
    /// start of a line recognize that it stands at a block mapping's own
    /// indent (an explicit-key value/key for that mapping) rather than
    /// opening a fresh implicit entry. The base stream-level slot is unused.
    indent_is_map: [max_depth + 1]bool = undefined,

    queue: [queue_cap]RawToken = undefined,
    queue_head: usize = 0,
    queue_len: usize = 0,

    /// Flow-collection nesting depth (`[`/`{` increment, `]`/`}`
    /// decrement). While > 0 the indentation machinery is suspended: no
    /// block_*_start/block_end tokens and no column-driven indent rolling.
    flow_level: u32 = 0,

    stream_start_emitted: bool = false,
    stream_end_emitted: bool = false,
    overflowed: bool = false,

    /// Opt-in lossless mode: when set, `skipToToken` records each `#`
    /// comment it would otherwise discard, and the fetch paths surface them
    /// as `.comment` tokens at their source position. Default false keeps
    /// the comment-skipping scan path byte-for-byte identical.
    emit_comments: bool = false,

    /// Spans of comments seen by `skipToToken` on the most recent skip,
    /// awaiting flush into the queue as `.comment` tokens. Bounded by the
    /// simple-key byte cap: a comment is at least two bytes (`#` plus its
    /// line break), so a single skip past the candidate bound can hold at
    /// most this many.
    pending_comments: [simple_key_max / 2 + 2]RawSpan = undefined,
    pending_comments_len: usize = 0,

    /// Whether the white space skipped before the current token contained a
    /// tab on the token's own (non-leading) line. A tab is a valid separator
    /// before a scalar value, but using it as the separation before a node
    /// that OPENS a block collection (a `-` block entry, or a key that opens a
    /// block mapping) is illegal indentation. Set by `skipToToken`, consumed
    /// by the block-entry and key-promotion paths.
    sep_had_tab: bool = false,

    /// Column of the first node property (anchor/tag) preceding the node
    /// currently being assembled, or null when none. A key carrying leading
    /// SAME-LINE properties (`!!str a: b`) opens its block mapping at the
    /// PROPERTY's column, not the key scalar's, so sibling keys at the
    /// property column stay in one mapping. Set when a leading property is
    /// emitted, cleared once the node it decorates is emitted.
    prop_start_col: ?i64 = null,
    /// Line of the first pending property, so key promotion only borrows the
    /// property column when the key is on the property's own line (a property
    /// on an earlier line decorates a separate, possibly empty, node).
    prop_start_line: u32 = 0,

    /// Line of the most recent IMPLICIT block-context value indicator -- the
    /// `:` that follows an inline mapping key (`a: ...`). A key that OPENS a new
    /// block mapping on this same line is a mapping value turned inline into a
    /// nested key (`a: b: c`), which is invalid. The explicit-key value `:` at
    /// a line start (`: moon: white`) does NOT set this: its value may legally
    /// be an inline mapping. Flow `:` does not set it either.
    value_line: u32 = 0,

    /// True when the immediately-preceding flow token was a JSON-like node
    /// (a quoted scalar emitted as a bare node, or a `]`/`}` flow close).
    /// After such a node, a `:` value indicator may be ADJACENT to the value
    /// even across a line break (`{"a"\n:b}`); set so the in-flow `:`
    /// dispatch admits the glued form there. Cleared by any other token.
    prev_flow_json_node: bool = false,

    /// Set just after an explicit `?` KEY indicator is emitted inside a flow
    /// collection. The node that follows is that key's CONTENT, so it must not
    /// be promoted to an implicit key of its own (which would emit a second
    /// `key` token, `{? a : b}` -> `key key scalar value`). Mirrors libyaml
    /// clearing `simple_key_allowed` after a flow KEY. Consumed by the next
    /// node; cleared by any intervening structural flow token.
    flow_explicit_key: bool = false,

    pub fn init(input: []const u8) Scanner {
        var s: Scanner = .{ .input = input };
        // Strip a leading UTF-8 BOM (U+FEFF, bytes EF BB BF). YAML 1.2.2
        // sec 5.2: a BOM at stream start is an encoding mark, not content.
        // Advancing pos by 3 leaves col at 0 so document-start markers and
        // indentation rules are unaffected.
        if (std.mem.startsWith(u8, s.input, "\xEF\xBB\xBF")) s.pos = 3;
        // Stream-level sentinel: real content always indents past -1.
        s.indents[0] = -1;
        s.indents_len = 1;
        return s;
    }

    /// Lossless variant of `init`: the scanner additionally emits a
    /// `.comment` token (spanning `#` to end-of-line, excluding the line
    /// break) at the source position of every `#` comment, so a consumer can
    /// interleave comments with structural tokens for round-trip tooling.
    /// The structural token stream is otherwise identical to `init`.
    pub fn initWithComments(input: []const u8) Scanner {
        var s = init(input);
        s.emit_comments = true;
        return s;
    }

    /// Drain one token with u64 byte offsets. Returns null once `stream_end`
    /// has been produced.
    pub fn next(self: *Scanner) ?Token {
        const raw = self.nextRaw() orelse return null;
        return .{
            .kind = raw.kind,
            .span = .{
                .start = raw.span.start,
                .end = raw.span.end,
            },
            .style = raw.style,
            .block_header = raw.block_header,
            .invalid_reason = raw.invalid_reason,
        };
    }

    /// Verdict from `frameDocument`: whether a buffer prefix holds a complete
    /// document, and (when it does) how many leading bytes that document plus
    /// its terminating boundary occupy.
    pub const Frame = union(enum) {
        /// The buffer holds at least one complete document. `consumed` is the
        /// byte count from the buffer start through the document's terminating
        /// boundary (a `...`/the byte before the next `---`/end of buffer when
        /// the scan ran clean to `stream_end`). A streaming reader hands the
        /// `[0..consumed]` slice to the parser, then drops it and re-frames.
        complete: usize,
        /// The scan reached raw end of buffer while still mid-construct (an
        /// unterminated quoted/block scalar, an open indentation that a later
        /// dedent or marker would resolve, or simply a single document with no
        /// terminating marker yet). More bytes may change the framing, so a
        /// reader-backed caller must pull more before deciding. When the reader
        /// is at EOF the caller treats the whole buffer as one final document.
        need_more,
    };

    /// Document framing oracle for a reader-backed streaming reader.
    ///
    /// Scans `input` as a stream prefix and reports whether its FIRST document
    /// is fully present. This reuses the real scanner as the boundary oracle:
    /// a `---`/`...` marker only frames a document when the scanner emits a
    /// `document_start`/`document_end` token for it, so a `---`/`...` sitting
    /// inside a quoted or block scalar (where it is content, not a boundary)
    /// never mis-frames -- the scanner already resolves that when it sees the
    /// surrounding scalar.
    ///
    /// Returns `.complete` with the leading byte count of the first document
    /// (including its terminating boundary) when a boundary is found, or
    /// `.need_more` when the scan runs to raw end of buffer without a boundary
    /// -- meaning either the document is genuinely unterminated mid-construct,
    /// or it is a final document whose extent only a reader EOF can confirm.
    ///
    /// Allocation-free: a fresh fixed-array `Scanner` drains over `input`.
    pub fn frameDocument(input: []const u8) Frame {
        var s = Scanner.init(input);
        // Whether the first document of this buffer has been entered: a `---`
        // marker opened it, or a content token began it implicitly. A directive
        // is NEUTRAL -- it binds to the FOLLOWING document, so it must not count
        // as entering one (else `%YAML\n---` would frame the directive alone).
        var entered = false;
        // A `...` end-marker frames a boundary only when its line tail holds no
        // content (YAML 1.2: only whitespace or a comment may follow `...`).
        // The decision needs one token of lookahead, so `pending_end` holds the
        // marker's end offset until the next token confirms the tail is clean.
        // `... x` (stray same-line content) is therefore NOT a boundary: the
        // content stays inside the frame so the per-document parse rejects it,
        // exactly as the buffered parser does, instead of the framer silently
        // splitting the stream. This restriction applies to `...` only; `---`
        // legitimately admits a node on its line (`--- foo`) and is untouched.
        var pending_end: ?usize = null;
        var pending_end_line: u32 = 0;
        while (s.nextRaw()) |t| {
            if (pending_end) |end_off| {
                if (t.span.line == pending_end_line and isFramingContent(t.kind)) {
                    pending_end = null;
                    entered = true;
                } else if (t.kind == .stream_end or t.kind == .invalid) {
                    // A buffer-boundary stream_end/invalid cannot be told apart
                    // from true EOF at this layer, so committing the `...`
                    // boundary now would race the stray same-line-content check
                    // when the tail sits just past a pull boundary. Defer: at
                    // true EOF frame() hands the whole buffer over unchanged; a
                    // mid-pull cut pulls more bytes and re-decides.
                    return .need_more;
                } else {
                    return .{ .complete = end_off };
                }
            }
            switch (t.kind) {
                .stream_start, .directive => {},
                .document_start => {
                    // A `---` while already inside a document opens the SECOND
                    // document; the boundary that closes the first is this
                    // marker's start byte. The first `---` (or a directive
                    // preceding it) opens the first document.
                    if (entered) return .{ .complete = t.span.start };
                    entered = true;
                },
                .document_end => {
                    // A `...` terminates the current document inclusively (even
                    // a bare `...` frames an empty document the parser handles),
                    // but only once the next token proves its line tail carries
                    // no content -- defer via `pending_end`.
                    pending_end = t.span.end;
                    pending_end_line = t.span.line;
                },
                .stream_end => {
                    // End of buffer with no interior boundary: a single trailing
                    // document whose extent only a reader EOF can confirm, since
                    // a trailing plain/block scalar could still grow with more
                    // bytes. The EOF decision stays with the caller.
                    return .need_more;
                },
                .invalid => {
                    // Reachable here only at raw end of buffer: an unterminated
                    // quoted scalar (cut mid-token). More bytes may terminate it
                    // and change framing, so pull more; at reader EOF the caller
                    // hands the buffer to the parser to surface the real error.
                    return .need_more;
                },
                else => entered = true,
            }
        }
        if (pending_end) |end_off| return .{ .complete = end_off };
        return .need_more;
    }

    /// True for tokens that begin a node, so a `...` end-marker followed by one
    /// on its own line is stray content (invalid) rather than a clean boundary.
    /// Mirrors the parser's same-line content rejection so the streaming framer
    /// and the buffered parser agree on which `...` lines frame a document.
    fn isFramingContent(kind: TokenKind) bool {
        return switch (kind) {
            .scalar, .alias, .anchor, .tag, .block_entry, .key, .block_sequence_start, .block_mapping_start, .flow_sequence_start, .flow_mapping_start => true,
            else => false,
        };
    }

    /// Drain one token with exact usize byte offsets; for inputs >4 GiB.
    /// Returns null once `stream_end` has been produced.
    pub fn nextRaw(self: *Scanner) ?RawToken {
        while (self.queue_len == 0) {
            if (self.stream_end_emitted) return null;
            self.fetchMore();
        }
        const t = self.queue[self.queue_head];
        self.queue_head = (self.queue_head + 1) % queue_cap;
        self.queue_len -= 1;
        return t;
    }

    fn enqueue(self: *Scanner, t: RawToken) void {
        if (self.queue_len >= queue_cap) {
            self.overflowed = true;
            return;
        }
        const tail = (self.queue_head + self.queue_len) % queue_cap;
        self.queue[tail] = t;
        self.queue_len += 1;
    }

    /// Insert `t` at logical position `idx` within the queue, shifting the
    /// tail back by one. Used to splice a collection-start token ahead of
    /// the trigger token already in the queue.
    fn insertAt(self: *Scanner, idx: usize, t: RawToken) void {
        if (self.queue_len >= queue_cap) {
            self.overflowed = true;
            return;
        }
        var i = self.queue_len;
        while (i > idx) : (i -= 1) {
            const dst = (self.queue_head + i) % queue_cap;
            const src = (self.queue_head + i - 1) % queue_cap;
            self.queue[dst] = self.queue[src];
        }
        const at = (self.queue_head + idx) % queue_cap;
        self.queue[at] = t;
        self.queue_len += 1;
    }

    fn point(self: *Scanner) RawSpan {
        return .{ .start = self.pos, .end = self.pos, .line = self.line, .col = self.col +| 1 };
    }

    fn advance(self: *Scanner) void {
        if (self.pos >= self.input.len) return;
        const c = self.input[self.pos];
        // `\n` and a lone `\r` (not paired with a following `\n`) each end a
        // line (YAML 1.2.2 section 5.4). The `\r` of a CRLF pair does not:
        // the paired `\n` performs the increment, so CRLF counts as one line
        // break rather than two.
        if (c == '\n' or (c == '\r' and self.peekAt(1) != '\n')) {
            self.line = satAdd(self.line, 1);
            self.col = 0;
        } else {
            self.col = satAdd(self.col, 1);
        }
        self.pos += 1;
    }

    /// Consume one line break: `\n`, `\r\n`, or a lone `\r`. Shared by callers
    /// that stop scanning right before a break byte and need to skip past it.
    fn consumeLineBreak(self: *Scanner) void {
        if (self.peek() == '\r') {
            self.advance();
            if (self.peek() == '\n') self.advance();
        } else if (self.peek() == '\n') {
            self.advance();
        }
    }

    fn peek(self: *Scanner) ?u8 {
        if (self.pos >= self.input.len) return null;
        return self.input[self.pos];
    }

    fn peekAt(self: *Scanner, ahead: usize) ?u8 {
        const i = self.pos + ahead;
        if (i >= self.input.len) return null;
        return self.input[i];
    }

    /// A separation byte: space/tab, newline, carriage return, or end of
    /// input. The `:` and `-` indicators only act as such when separated this
    /// way; otherwise they are ordinary scalar content (e.g. `http://x`).
    /// CR is included so that CRLF line endings (`\r\n`) are recognized: the
    /// `:` in `key:\r\n` sees `\r` as the next byte, which must count as a
    /// separator for the value indicator to fire.
    fn isBlankOrEnd(b: ?u8) bool {
        return b == null or b == ' ' or b == '\t' or b == '\n' or b == '\r';
    }

    /// Top-level pump: emit stream_start, skip insignificant whitespace and
    /// comments to the next token, unroll indentation, then dispatch on the
    /// leading byte. Each call enqueues at least one token (or stream_end).
    fn fetchMore(self: *Scanner) void {
        if (!self.stream_start_emitted) {
            self.stream_start_emitted = true;
            self.enqueue(.{ .kind = .stream_start, .span = self.point() });
            return;
        }

        const tab_indent = self.skipToToken();

        // Surface any comments seen while skipping at their source position,
        // ahead of the indentation unroll and the next node's tokens (and,
        // for a trailing comment, ahead of the closing block_end/stream_end).
        self.flushComments();

        if (self.overflowed) {
            self.enqueue(.{ .kind = .invalid, .span = self.point(), .invalid_reason = .queue_overflow });
            self.finishStream();
            return;
        }

        if (self.peek() == null) {
            self.finishStream();
            return;
        }

        // A tab in indentation position (block context only; flow ignores
        // indentation) is invalid per YAML 1.2. A leading tab before a flow
        // collection (`\t[1]`, `\t{}`) is separation white space, not block
        // indentation: a flow node's content is not indentation-sensitive, so
        // the tab is allowed there.
        if (tab_indent and self.flow_level == 0) {
            const c = self.peek().?;
            if (c != '[' and c != '{') {
                self.enqueue(.{ .kind = .invalid, .span = self.point(), .invalid_reason = .tab_indentation });
                self.advance();
                return;
            }
        }

        // Inside a flow collection the indentation stack is frozen; column
        // changes do not open or close block collections.
        if (self.flow_level > 0) {
            self.fetchInFlow();
            return;
        }

        // Document markers and directives only act at column 0.
        if (self.col == 0) {
            if (self.atDocumentMarker()) |kind| {
                self.fetchDocumentMarker(kind);
                return;
            }
            if (self.peek() == '%') {
                self.fetchDirective();
                return;
            }
        }

        // Close any collections whose indent is deeper than this column.
        self.unrollIndent(@intCast(self.col));

        // A block sequence that shares its parent mapping's indent (`key:\n-
        // a`) is closed by any non-`- ` token at that column: the token
        // belongs to the parent mapping, not the sequence.
        self.closeIndentlessSeq(@intCast(self.col));

        self.fetchToken();
    }

    /// Pop a block sequence opened at its parent mapping's own indent once a
    /// non-block-entry token appears at that column. Such a sequence is not
    /// closed by `unrollIndent` (its indent is not strictly greater than the
    /// column), so a following key at the same indent would otherwise be
    /// mis-framed inside the sequence.
    fn closeIndentlessSeq(self: *Scanner, col: i64) void {
        while (self.indents_len > 1 and
            !self.indent_is_map[self.indents_len - 1] and
            self.indents[self.indents_len - 1] == col and
            self.indents[self.indents_len - 2] == col and
            self.indent_is_map[self.indents_len - 2])
        {
            // A `- ` at this column continues the sequence; anything else ends
            // it.
            const is_entry = self.peek() == '-' and isBlankOrEnd(self.peekAt(1));
            if (is_entry) break;
            self.indents_len -= 1;
            self.enqueue(.{ .kind = .block_end, .span = self.point() });
        }
    }

    /// Dispatch a single token on the leading byte (block or flow context).
    /// Scalar/quoted/tag producers handle their own key promotion.
    fn fetchToken(self: *Scanner) void {
        const c = self.peek().?;
        // In flow context a plain scalar may not begin with `-`/`?` immediately
        // followed by a flow indicator (`[-]`, `[?,`): such a `-`/`?` is a
        // block indicator with no role in flow, so the would-be scalar is
        // invalid. (A separated `- ` / `? ` is handled below; a `:` glued to a
        // flow indicator is the value-indicator path in fetchInFlow.)
        if (self.flow_level > 0 and (c == '-' or c == '?')) {
            const n = self.peekAt(1);
            if (n != null and isFlowIndicator(n.?)) {
                self.enqueue(.{ .kind = .invalid, .span = self.point(), .invalid_reason = .bare_indicator_in_flow });
                self.advance();
                return;
            }
        }
        switch (c) {
            '-' => {
                if (isBlankOrEnd(self.peekAt(1))) {
                    // A tab separating this `-` from a preceding block
                    // indicator (`-<tab>-`) is indentation for the nested
                    // sequence, which must be spaces.
                    if (self.flow_level == 0 and self.sep_had_tab) {
                        self.enqueue(.{ .kind = .invalid, .span = self.point(), .invalid_reason = .tab_indentation });
                        return;
                    }
                    self.fetchBlockEntry();
                } else {
                    self.fetchPlainOrKey();
                }
            },
            '?' => {
                // Explicit-key indicator; treated as plain when not a
                // separated `? `. A `? ` opens (or continues) a block
                // mapping at its column, then emits the `key` indicator;
                // the key node follows on this or subsequent lines.
                if (isBlankOrEnd(self.peekAt(1))) {
                    // A tab separating this `?` from a preceding block
                    // indicator is indentation for the explicit-key mapping.
                    if (self.flow_level == 0 and self.sep_had_tab) {
                        self.enqueue(.{ .kind = .invalid, .span = self.point(), .invalid_reason = .tab_indentation });
                        return;
                    }
                    // In flow context the indentation stack is frozen, so no
                    // block mapping is opened; the parser frames the explicit
                    // key against the enclosing flow collection.
                    if (self.flow_level == 0) {
                        const col: i64 = @intCast(self.col);
                        _ = self.rollIndent(col, .block_mapping_start, self.queue_len);
                    } else {
                        // The following node is this explicit key's content;
                        // suppress its own simple-key promotion.
                        self.flow_explicit_key = true;
                    }
                    self.enqueue(.{ .kind = .key, .span = self.point() });
                    self.advance();
                } else self.fetchPlainOrKey();
            },
            ':' => {
                // A `:` value indicator at the start of a token in block
                // context. When it stands at the current block mapping's own
                // indent it is the explicit value for the pending key (the
                // key node was already emitted). Otherwise it is an ordinary
                // implicit entry with an empty key, handled as a plain scalar
                // that promotes to a key.
                const col: i64 = @intCast(self.col);
                if (isBlankOrEnd(self.peekAt(1)) and self.atOpenMappingIndent(col)) {
                    self.enqueue(.{ .kind = .value, .span = self.point() });
                    self.advance();
                } else self.fetchPlainOrKey();
            },
            '\'' => self.fetchQuotedScalar(.single),
            '"' => self.fetchQuotedScalar(.double),
            '|' => self.fetchBlockScalar(.literal),
            '>' => self.fetchBlockScalar(.folded),
            '&' => self.fetchAnchorOrAlias(.anchor),
            '*' => self.fetchAnchorOrAlias(.alias),
            '!' => self.fetchTag(),
            '[' => if (self.flow_level == 0) self.fetchFlowNodeAsPossibleKey(.flow_sequence_start) else self.fetchFlowStart(.flow_sequence_start),
            '{' => if (self.flow_level == 0) self.fetchFlowNodeAsPossibleKey(.flow_mapping_start) else self.fetchFlowStart(.flow_mapping_start),
            '#' => {
                // skipToToken stops on a `#` glued to preceding content; a
                // comment indicator can never begin a node, so this is an
                // unseparated comment.
                self.enqueue(.{ .kind = .invalid, .span = self.point(), .invalid_reason = .unseparated_comment });
                self.advance();
            },
            else => self.fetchPlainOrKey(),
        }
    }

    /// Drain comment spans recorded by the most recent `skipToToken` into
    /// the queue as `.comment` tokens, preserving source order. A no-op in
    /// the default scan path (the buffer is never filled there).
    fn flushComments(self: *Scanner) void {
        var i: usize = 0;
        while (i < self.pending_comments_len) : (i += 1) {
            self.enqueue(.{ .kind = .comment, .span = self.pending_comments[i] });
        }
        self.pending_comments_len = 0;
    }

    fn finishStream(self: *Scanner) void {
        self.unrollIndent(-1);
        self.enqueue(.{ .kind = .stream_end, .span = self.point() });
        self.stream_end_emitted = true;
    }

    /// Skip spaces, tabs, newlines, and comments until the next content
    /// byte or end of input. Returns true if a tab appeared in the
    /// indentation (leading whitespace) of the line the next token starts
    /// on -- that is an invalid indent in block context. A tab after any
    /// non-blank byte, or after a newline-resetting comment line, does not
    /// set the flag for a later line.
    fn skipToToken(self: *Scanner) bool {
        // A tab is in indentation only when the line up to it is blank. When
        // skipToToken starts mid-line (right after a `:`/`-` indicator, where
        // `self.col > 0`), a tab is a separator, not indentation, until the
        // next newline resets the line.
        var at_line_start = self.col == 0;
        var tab_in_indent = false;
        var mid_line_tab = false;
        while (self.peek()) |c| {
            switch (c) {
                ' ' => self.advance(),
                '\r' => {
                    // A line break: the carriage return of a CRLF pair, or a
                    // lone CR (YAML 1.2.2 section 5.4). Either way the line
                    // resets, whether or not a `\n` follows.
                    tab_in_indent = false;
                    mid_line_tab = false;
                    at_line_start = true;
                    self.advance();
                },
                '\t' => {
                    // A tab in leading whitespace (line still blank) is an
                    // illegal block indent; a tab after content on the line is
                    // a valid separator (recorded so the block-entry/key paths
                    // can still reject it before a block-opening construct).
                    if (at_line_start) tab_in_indent = true else mid_line_tab = true;
                    self.advance();
                },
                '\n' => {
                    tab_in_indent = false;
                    mid_line_tab = false;
                    at_line_start = true;
                    self.advance();
                },
                '#' => {
                    // A comment must be separated from preceding content by
                    // white space or a line start. A `#` glued to content
                    // (`a,#x`, `"v"#x`) is not a comment; stop here so
                    // fetchMore flags it as an unseparated comment.
                    if (self.pos > 0) {
                        const prev = self.input[self.pos - 1];
                        if (prev != ' ' and prev != '\t' and prev != '\n' and prev != '\r') {
                            self.sep_had_tab = mid_line_tab;
                            return tab_in_indent;
                        }
                    }
                    tab_in_indent = false;
                    const comment_start = self.pos;
                    const comment_line = self.line;
                    const comment_col = self.col;
                    while (self.peek()) |h| {
                        if (h == '\n') break;
                        self.advance();
                    }
                    // Span excludes the trailing line break; a CRLF ending
                    // leaves a `\r` just before the `\n` that is not comment
                    // content either.
                    var comment_end = self.pos;
                    if (comment_end > comment_start and self.input[comment_end - 1] == '\r')
                        comment_end -= 1;
                    if (self.emit_comments and self.pending_comments_len < self.pending_comments.len) {
                        self.pending_comments[self.pending_comments_len] = .{
                            .start = comment_start,
                            .end = comment_end,
                            .line = comment_line,
                            .col = comment_col +| 1,
                        };
                        self.pending_comments_len += 1;
                    }
                },
                else => {
                    self.sep_had_tab = mid_line_tab;
                    return tab_in_indent;
                },
            }
        }
        self.sep_had_tab = mid_line_tab;
        return tab_in_indent;
    }

    /// Pop collections whose start column is greater than `col`, enqueuing
    /// a `block_end` for each. The stream-level -1 sentinel is never
    /// popped by a non-negative column.
    fn unrollIndent(self: *Scanner, col: i64) void {
        while (self.indents_len > 1 and self.indents[self.indents_len - 1] > col) {
            self.indents_len -= 1;
            self.enqueue(.{ .kind = .block_end, .span = self.point() });
        }
    }

    /// Open a new collection at `col` if it indents past the current top,
    /// splicing the start token into the queue at `insert_idx`. Returns
    /// true if a collection was opened.
    fn rollIndent(self: *Scanner, col: i64, kind: TokenKind, insert_idx: usize) bool {
        if (self.indents[self.indents_len - 1] >= col) return false;
        if (self.indents_len > max_depth) {
            self.overflowed = true;
            return false;
        }
        self.indents[self.indents_len] = col;
        self.indent_is_map[self.indents_len] = kind == .block_mapping_start;
        self.indents_len += 1;
        self.insertAt(insert_idx, .{ .kind = kind, .span = self.point() });
        return true;
    }

    /// True when the current top open block collection is a mapping whose
    /// own indent is `col`. A `?`/`:` indicator at the line start standing
    /// at this column is an explicit-key key/value for that mapping, not a
    /// fresh implicit entry.
    fn atOpenMappingIndent(self: *Scanner, col: i64) bool {
        return self.indents_len > 1 and
            self.indent_is_map[self.indents_len - 1] and
            self.indents[self.indents_len - 1] == col;
    }

    /// `- ` block entry. Opens a block sequence if this column starts one. A
    /// block sequence that is a mapping's value may sit at the SAME column as
    /// the mapping key (`key:\n- a\n- b`): the `-` indicator supplies the
    /// indentation, so a sequence opens even at the enclosing mapping's own
    /// indent. (A bare `- ` at a sequence's own indent is just its next entry,
    /// handled by the normal `col > top` rollIndent.)
    fn fetchBlockEntry(self: *Scanner) void {
        // A `-` starts a fresh entry node: a property still pending decorated
        // the PREVIOUS (empty) node and does not carry to this entry's key.
        self.prop_start_col = null;
        const entry_col: i64 = @intCast(self.col);
        if (atOpenMappingIndent(self, entry_col) and self.indents_len <= max_depth) {
            self.indents[self.indents_len] = entry_col;
            self.indent_is_map[self.indents_len] = false;
            self.indents_len += 1;
            self.insertAt(self.queue_len, .{ .kind = .block_sequence_start, .span = self.point() });
        } else {
            _ = self.rollIndent(entry_col, .block_sequence_start, self.queue_len);
        }
        self.enqueue(.{ .kind = .block_entry, .span = self.point() });
        self.advance(); // consume '-'
        // The separating space (if any) is skipped by the next fetch.
    }

    /// Scan a plain scalar. If a value indicator follows it on the same
    /// line, it is a mapping key: splice `block_mapping_start` (when this
    /// opens a new block mapping) and `key` ahead of the scalar, then emit
    /// the scalar and a `value` token. In flow context no block mapping is
    /// opened and `:` need not be followed by a blank.
    fn fetchPlainOrKey(self: *Scanner) void {
        const scalar_col: i64 = @intCast(self.col);
        const scalar = self.scanPlainScalar();
        self.emitNodeWithOptionalKey(scalar, scalar_col);
    }

    /// Emit `node` (a scalar/quoted token already scanned), promoting it to
    /// a mapping key when a `:` value indicator follows on the same line.
    /// `node_col` is the column the node began at (for indent rolling).
    fn emitNodeWithOptionalKey(self: *Scanner, node: RawToken, node_col: i64) void {
        // A scan that failed (e.g. a value indicator inside a multi-line
        // plain continuation) is emitted as-is; no key promotion applies.
        if (node.kind == .invalid) {
            self.enqueue(node);
            return;
        }
        const in_flow = self.flow_level > 0;
        // A value indicator may be separated from its key by blanks on the
        // same line (`"top1" : v`, `top5   : v`). Look past same-line spaces
        // and tabs (not a line break) for the `:`.
        var look: usize = 0;
        while (true) {
            const b = self.peekAt(look) orelse break;
            if (b == ' ' or b == '\t') look += 1 else break;
        }
        const after_colon = self.peekAt(look + 1);
        // In flow, a JSON-like key (a quoted scalar) permits the value `:` to
        // be ADJACENT to the value with no separator (`{"a":b}`); a plain key
        // still requires the `:` to be followed by a separator or flow byte.
        const json_key = in_flow and (node.style == .single or node.style == .double);
        // A node right after an explicit `?` in flow is the key's content, not
        // a new implicit key; emit it bare and let the `:` arrive as the value
        // indicator (Y: `{? a : b}` is `key scalar value scalar`, not doubled).
        const explicit_key_content = in_flow and self.flow_explicit_key;
        self.flow_explicit_key = false;
        const is_key = !explicit_key_content and self.peekAt(look) == ':' and
            (isBlankOrEnd(after_colon) or (in_flow and isFlowEnd(after_colon)) or json_key);

        // An implicit key must fit on a single line. A quoted scalar that spans
        // a line break (`"c\n d": 1`) cannot serve as a block-context key.
        // (Flow context handles its own multi-line keys via single-pair
        // promotion.)
        if (is_key and !in_flow and
            std.mem.indexOfScalar(u8, self.input[node.span.start..node.span.end], '\n') != null)
        {
            self.enqueue(.{ .kind = .invalid, .span = node.span, .invalid_reason = .multiline_implicit_key });
            return;
        }

        // Consume the intervening blanks so the value indicator lands on `:`.
        if (is_key) {
            var k: usize = 0;
            while (k < look) : (k += 1) self.advance();
        }

        // A key carrying leading SAME-LINE node properties opens its block
        // mapping at the FIRST property's column (`!!str a: b` -> the mapping
        // is at the tag), so sibling keys at that column stay in one mapping.
        // A property on an earlier line decorates a separate (empty) node, so
        // it does not move this key's column. With no properties this is just
        // the node's own column. Consumed here.
        const key_col = if (self.prop_start_col) |pc|
            (if (self.prop_start_line == node.span.line) pc else node_col)
        else
            node_col;
        self.prop_start_col = null;

        // Index where a key/block_mapping_start would be spliced: ahead of
        // the node token we are about to enqueue.
        const insert_idx = self.queue_len;

        if (is_key) {
            if (!in_flow) {
                // A key reached via a tab separation that OPENS a new block
                // mapping uses that tab as the mapping's indentation, which
                // must be spaces (`?\tkey:`). A tab before a key in an
                // already-open mapping, or before a non-key scalar, is fine.
                if (self.sep_had_tab and
                    self.indents[self.indents_len - 1] < key_col)
                {
                    self.enqueue(.{ .kind = .invalid, .span = node.span, .invalid_reason = .tab_indentation });
                    // Consume the `:` so the scanner advances past it; leaving
                    // it would re-enter this path on the same byte forever
                    // (an unbounded zero-width error stream the error-recovery
                    // path then spins on).
                    self.advance();
                    return;
                }
                // A key that OPENS a new block mapping after a value indicator
                // already appeared earlier on the same line is a mapping value
                // turned into a nested key (`a: b: c`): block mappings do not
                // nest inline after a value indicator, so it is invalid.
                if (self.indents[self.indents_len - 1] < key_col and
                    self.value_line == node.span.line)
                {
                    self.enqueue(.{ .kind = .invalid, .span = node.span, .invalid_reason = .nested_block_mapping_inline });
                    // Consume the `:` to guarantee forward progress (see above).
                    self.advance();
                    return;
                }
                _ = self.rollIndent(key_col, .block_mapping_start, insert_idx);
            }
            self.insertAt(self.queue_len, .{ .kind = .key, .span = self.point() });
            self.enqueue(node);
            self.enqueue(.{ .kind = .value, .span = .{
                .start = self.pos,
                .end = self.pos + 1,
                .line = self.line,
                .col = self.col +| 1,
            } });
            // Only record value_line for a real (non-empty) implicit key.  A
            // synthesized empty key -- the `: value` at line start with no
            // open mapping -- has an empty span (start == end).  Its inline
            // value may legally be a mapping (`: moon: white`), so we must
            // not arm the nested-block-mapping rejection for that line.
            if (!in_flow and node.span.start != node.span.end) self.value_line = self.line;
            self.advance(); // consume ':'
        } else {
            self.enqueue(node);
            // A quoted scalar emitted as a bare flow node is JSON-like: a
            // following `:` (even across a line break) is its adjacent value
            // indicator (`{"a"\n:b}`).
            if (in_flow and (node.style == .single or node.style == .double))
                self.prev_flow_json_node = true;
        }
    }

    // --- Flow context -----------------------------------------------------

    /// Dispatch one token while inside a flow collection. The structural
    /// flow bytes are handled here; everything else (scalars, quoted,
    /// anchors, tags, nested flow) routes through `fetchToken`.
    fn fetchInFlow(self: *Scanner) void {
        const c = self.peek().?;
        // Whether the previous token was a JSON-like node, admitting an
        // adjacent value `:` here. Captured before this dispatch clears it.
        const prev_json = self.prev_flow_json_node;
        self.prev_flow_json_node = false;
        switch (c) {
            ',' => {
                // A comma ends any pending explicit-key suppression: the key's
                // content was empty (`{? , ...}`).
                self.flow_explicit_key = false;
                self.enqueue(.{ .kind = .flow_entry, .span = self.point() });
                self.advance();
            },
            ']' => self.fetchFlowEnd(.flow_sequence_end),
            '}' => self.fetchFlowEnd(.flow_mapping_end),
            ':' => {
                // A bare `:` is a value indicator when followed by a separator
                // or flow terminator (`{: v}`, `{a: :b}` value, explicit-key
                // value), or when ADJACENT to a preceding JSON-like key node
                // (`{"a"\n:b}`). A `:` glued to following content after a plain
                // node (`:x`) begins a plain scalar instead.
                if (isBlankOrEnd(self.peekAt(1)) or isFlowEnd(self.peekAt(1)) or prev_json) {
                    // The value indicator ends explicit-key suppression: the
                    // key's content (if any) is complete (`{? : v}` empty key).
                    self.flow_explicit_key = false;
                    self.enqueue(.{ .kind = .value, .span = self.point() });
                    self.advance();
                } else self.fetchToken();
            },
            else => self.fetchToken(),
        }
    }

    fn fetchFlowStart(self: *Scanner, kind: TokenKind) void {
        // The flow collection is the node any pending property decorates.
        self.prop_start_col = null;
        // A nested collection opening is the explicit key's content (a fresh
        // node), so it carries no further simple-key suppression of its own.
        self.flow_explicit_key = false;
        self.flow_level += 1;
        self.enqueue(.{ .kind = kind, .span = self.point() });
        self.advance();
    }

    fn fetchFlowEnd(self: *Scanner, kind: TokenKind) void {
        self.flow_explicit_key = false;
        if (self.flow_level > 0) self.flow_level -= 1;
        self.enqueue(.{ .kind = kind, .span = self.point() });
        self.advance();
        // A closing `]`/`}` is a JSON-like node: a following `:` may be the
        // adjacent value indicator (`{[1]:2}`).
        if (self.flow_level > 0) self.prev_flow_json_node = true;
    }

    /// Scan a whole block-context flow collection (`[...]`/`{...}`), buffering
    /// all its tokens in the queue, then -- if a `:` value indicator follows
    /// it on the same line within the simple-key bound -- retroactively splice
    /// a `block_mapping_start` (when this opens a new block mapping) and a
    /// `key` ahead of the flow node's start token, turning the flow collection
    /// into a block mapping key (`[a, b]: v`, `{a: 1}: v`).
    ///
    /// Buffering the node is what makes the retroactive splice possible: the
    /// scanner emits tokens eagerly, so the flow start would otherwise be long
    /// drained by the time the `:` is seen. The simple-key bound (one line,
    /// `simple_key_max` bytes) caps the buffered burst and guarantees the
    /// candidate scan terminates. When no `:` follows, the flow node is left
    /// exactly as before (an ordinary flow value), so this changes nothing for
    /// the flow-as-value path.
    fn fetchFlowNodeAsPossibleKey(self: *Scanner, kind: TokenKind) void {
        const insert_idx = self.queue_len;
        const start_pos = self.pos;
        const start_line = self.line;
        const node_col: i64 = @intCast(self.col);
        // A key carrying leading SAME-LINE properties opens its block mapping
        // at the property's column (mirrors emitNodeWithOptionalKey).
        const key_col = if (self.prop_start_col) |pc|
            (if (self.prop_start_line == start_line) pc else node_col)
        else
            node_col;
        const sep_had_tab = self.sep_had_tab;

        self.fetchFlowStart(kind);

        // Buffer the rest of the flow node. The loop terminates when the
        // collection closes (flow_level back to 0), at end of input, on a
        // scanner overflow, or once the simple-key byte bound is exceeded (a
        // flow node longer than a simple key can never BE one, so stop
        // buffering and let the normal streaming path finish it).
        var overlong = false;
        while (self.flow_level > 0) {
            if (self.peek() == null or self.overflowed) break;
            if (self.pos - start_pos > simple_key_max) {
                overlong = true;
                break;
            }
            _ = self.skipToToken();
            self.flushComments();
            if (self.peek() == null or self.overflowed) break;
            self.fetchInFlow();
        }

        // Only a cleanly-closed, single-line, within-bound flow node can be a
        // block simple key. A node that crossed a line break, ran long, or did
        // not close is left as an ordinary value (or its own error).
        if (overlong or self.flow_level > 0) return;
        const crossed_line = self.line != start_line;

        // Look past same-line blanks for the `:` value indicator.
        var look: usize = 0;
        while (true) {
            const b = self.peekAt(look) orelse break;
            if (b == ' ' or b == '\t') look += 1 else break;
        }
        if (self.peekAt(look) != ':') return;
        const after = self.peekAt(look + 1);
        if (!(isBlankOrEnd(after) or isFlowEnd(after))) return;
        if (crossed_line) return;

        // Consume the intervening blanks so the value indicator lands on `:`.
        var k: usize = 0;
        while (k < look) : (k += 1) self.advance();

        // A key that OPENS a new block mapping via a tab separation, or after a
        // value indicator already fired on this line (`a: [x]: y`), is invalid
        // -- the same guards the plain/quoted key path enforces. Splice an
        // invalid token ahead of the buffered flow node so the parser rejects;
        // the buffered tokens are harmless trailing noise the recovery skips.
        const opens_mapping = self.indents[self.indents_len - 1] < key_col;
        if (opens_mapping and (sep_had_tab or self.value_line == start_line)) {
            const reason: InvalidReason = if (sep_had_tab)
                .tab_indentation
            else
                .nested_block_mapping_inline;
            // Splice the rejection ahead of the buffered flow tokens so the
            // parser hits it first. Consume the `:` so the scanner makes
            // progress past it rather than re-processing it on a later fetch.
            self.insertAt(insert_idx, .{ .kind = .invalid, .span = self.point(), .invalid_reason = reason });
            self.advance(); // consume ':'
            return;
        }

        var idx = insert_idx;
        if (self.rollIndent(key_col, .block_mapping_start, idx)) idx += 1;
        self.insertAt(idx, .{ .kind = .key, .span = self.point() });
        self.prop_start_col = null;
        self.enqueue(.{ .kind = .value, .span = .{
            .start = self.pos,
            .end = self.pos + 1,
            .line = self.line,
            .col = self.col +| 1,
        } });
        self.value_line = self.line;
        self.advance(); // consume ':'
    }

    // --- Quoted scalars ----------------------------------------------------

    /// Single- or double-quoted scalar. The span covers the inner content
    /// only (between the quotes); the composer unescapes. Unterminated ->
    /// `.invalid`. Key promotion mirrors plain scalars so a quoted key
    /// (`"a": 1`) still produces key/value tokens.
    fn fetchQuotedScalar(self: *Scanner, style: ScalarStyle) void {
        const node_col: i64 = @intCast(self.col);
        const quote = self.peek().?;
        self.advance(); // opening quote
        const start = self.pos;
        const start_line = self.line;
        const start_col = self.col;

        var terminated = false;
        while (self.peek()) |c| {
            // SIMD fast-path: bulk-skip the run of content bytes that cannot
            // terminate or escape. The skipped run holds no control bytes
            // (<0x20), so no `\n`/`\r` -- `col` advances linearly. Only enter
            // from col > 0: a `---`/`...` marker can only sit at col 0, and the
            // skip set does not include `-`/`.`, so SIMD must not run there or
            // it could skip past the column-0 marker check.
            if (self.input.len - self.pos >= simd_w and self.col != 0) {
                const skip = if (style == .double)
                    scanDoubleQuotedFast(self.input[self.pos..])
                else
                    scanSingleQuotedFast(self.input[self.pos..]);
                if (skip > 0) {
                    self.pos += skip;
                    self.col = satAdd(self.col, skip);
                    continue;
                }
            }
            // A `---`/`...` document marker at column 0 ends the document, so a
            // quoted scalar may not span across one: the quote is unterminated.
            if (self.col == 0 and self.isDocumentMarkerAt(self.pos)) break;
            if (style == .double and c == '\\') {
                // Backslash escapes the next byte for termination purposes;
                // the scanner does not interpret the escape.
                self.advance();
                if (self.peek() == null) break;
                self.advance();
                continue;
            }
            if (c == quote) {
                if (style == .single and self.peekAt(1) == '\'') {
                    // `''` is an escaped quote in single-quoted scalars.
                    self.advance();
                    self.advance();
                    continue;
                }
                terminated = true;
                break;
            }
            self.advance();
        }

        if (!terminated) {
            const reason: InvalidReason = if (style == .single)
                .unterminated_single_quote
            else
                .unterminated_double_quote;
            self.enqueue(.{ .kind = .invalid, .invalid_reason = reason, .span = .{
                .start = start,
                .end = self.pos,
                .line = start_line,
                .col = start_col +| 1,
            } });
            return;
        }

        const end = self.pos;
        self.advance(); // closing quote
        const node: RawToken = .{ .kind = .scalar, .style = style, .span = .{
            .start = start,
            .end = end,
            .line = start_line,
            .col = start_col +| 1,
        } };
        self.emitNodeWithOptionalKey(node, node_col);
    }

    // --- Block scalars -----------------------------------------------------

    /// Literal (`|`) or folded (`>`) block scalar. Parses the header
    /// (chomping `+`/`-` and an optional explicit indent digit, in either
    /// order) up to the line break, then consumes the indented body. The
    /// recorded span covers the raw body bytes (from the first body byte to
    /// the last non-break byte); the composer strips indentation and folds
    /// using the recorded `block_header`. An empty body yields an empty span.
    fn fetchBlockScalar(self: *Scanner, style: ScalarStyle) void {
        // A block scalar is a node (never a key); it consumes any pending
        // property column.
        self.prop_start_col = null;
        const start_line = self.line;
        const start_col = self.col;
        const parent_indent: i64 = self.indents[self.indents_len - 1];
        const header_start = self.pos;
        self.advance(); // consume '|' or '>'

        var header: BlockHeader = .{ .header_start = header_start };
        // Two header indicators may appear in either order: a chomping
        // sign (+/-) and one explicit-indent digit (1-9).
        var i: u8 = 0;
        while (i < 2) : (i += 1) {
            const c = self.peek() orelse break;
            if (c == '-') {
                header.chomp = .strip;
                self.advance();
            } else if (c == '+') {
                header.chomp = .keep;
                self.advance();
            } else if (c >= '1' and c <= '9') {
                header.explicit_indent = c - '0';
                self.advance();
            } else break;
        }

        // Validate the rest of the header line: after the indicators only
        // white space and an optional `# comment` may appear before the line
        // break. A stray digit (a `0` or a second indent digit) or any other
        // content -- including a `#` not separated by white space -- is a
        // malformed header.
        var saw_space = false;
        var bad_header = false;
        while (self.peek()) |c| {
            if (c == '\n' or c == '\r') break;
            if (c == ' ' or c == '\t') {
                saw_space = true;
                self.advance();
                continue;
            }
            if (c == '#' and saw_space) {
                // A comment (only valid when white space separates it from the
                // indicators) runs to the end of the line.
                while (self.peek()) |h| {
                    if (h == '\n' or h == '\r') break;
                    self.advance();
                }
                break;
            }
            // Any other byte (a stray digit, a `#` not preceded by space, or
            // content) is a malformed header.
            bad_header = true;
            self.advance();
        }
        self.consumeLineBreak();

        if (bad_header) {
            self.enqueue(.{ .kind = .invalid, .invalid_reason = .block_scalar_header, .span = .{
                .start = self.pos,
                .end = self.pos,
                .line = start_line,
                .col = start_col +| 1,
            } });
            return;
        }

        // The minimum column a content line may occupy: one past the parent
        // collection's indent (the stream-level -1 sentinel maps to 0).
        const min_content: i64 = if (parent_indent < 0) 0 else parent_indent + 1;

        // With an explicit indicator the content indentation is fixed up
        // front (parent column + n); auto-detection waits for the first
        // non-empty body line.
        const explicit_abs: ?i64 = if (header.explicit_indent) |n|
            @max(min_content - 1, 0) + n
        else
            null;

        const body_start = self.pos;
        // First pass over the raw body: find the auto-detected content
        // indentation (the first non-empty line's indent) and the body's
        // byte limit (the start of the terminating line). A non-blank line
        // terminates the body when it is less indented than the content
        // indentation, or when it is a `---`/`...` marker at column 0. The
        // threshold is `min_content` until the indentation is known, then the
        // resolved content column.
        var detected: ?u32 = null;
        var max_leading_blank: u32 = 0;
        var body_limit = self.pos;
        var scan = self.pos;
        while (scan < self.input.len) {
            const ls = scan;
            var sp: u32 = 0;
            while (scan < self.input.len and self.input[scan] == ' ') : (scan += 1) sp += 1;
            const at = if (scan < self.input.len) self.input[scan] else 0;
            const blank = scan >= self.input.len or at == '\n' or at == '\r';
            // A document marker at column 0 terminates the body even when the
            // parent is the stream level (where indent 0 would otherwise be a
            // content line).
            if (sp == 0 and !blank and self.isDocumentMarkerAt(ls)) {
                body_limit = ls;
                break;
            }
            // The active dedent threshold: the resolved content indent once
            // known (explicit, or auto-detected), else the parent minimum.
            const threshold: i64 = explicit_abs orelse
                (if (detected) |d| @as(i64, d) else min_content);
            if (!blank and @as(i64, sp) < threshold) {
                body_limit = ls;
                break;
            }
            if (blank) {
                if (sp > max_leading_blank) max_leading_blank = sp;
            } else if (detected == null) {
                detected = sp;
            }
            // Advance to the next line, past its line break: `\n`, `\r\n`,
            // or a lone `\r`.
            while (scan < self.input.len and self.input[scan] != '\n' and self.input[scan] != '\r') scan += 1;
            if (scan < self.input.len) {
                scan += if (self.input[scan] == '\r' and scan + 1 < self.input.len and self.input[scan + 1] == '\n')
                    2
                else
                    1;
            }
            body_limit = scan;
        }

        if (explicit_abs) |e| {
            header.content_indent = @intCast(e);
        } else if (detected) |d| {
            header.content_indent = d;
            // A leading blank line more indented than the first content line
            // makes the content indentation ambiguous: that is an error.
            if (max_leading_blank > d) header.leading_overindent = true;
        } else {
            // Empty body (only blank lines): the content indentation is the
            // deepest blank line, so every line strips to empty. A body with
            // no lines at all strips nothing.
            const floor: u32 = if (min_content < 0) 0 else @intCast(min_content);
            header.content_indent = @max(floor, max_leading_blank);
        }

        // Advance the real scan position to the body limit, fixing up the
        // line/col counters by replaying the consumed bytes.
        while (self.pos < body_limit) self.advance();

        self.enqueue(.{ .kind = .scalar, .style = style, .block_header = header, .span = .{
            .start = body_start,
            .end = body_limit,
            .line = start_line,
            .col = start_col +| 1,
        } });
    }

    // --- Node properties: anchors, aliases, tags ---------------------------

    /// `&name` (anchor) or `*name` (alias). The span covers the NAME only
    /// (excluding the sigil) so the consumer can slice it directly. A name
    /// runs until whitespace, a line break, or a flow indicator.
    fn fetchAnchorOrAlias(self: *Scanner, kind: TokenKind) void {
        const sigil_col: i64 = @intCast(self.col);
        const start_line = self.line;
        self.advance(); // consume '&' or '*'
        const start = self.pos;
        const start_col = self.col;
        while (self.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or isFlowIndicator(c)) break;
            self.advance();
        }
        if (self.propertyMisindented(sigil_col)) {
            self.enqueue(.{ .kind = .invalid, .span = self.point(), .invalid_reason = .misindented_property });
            return;
        }
        const tok: RawToken = .{ .kind = kind, .span = .{
            .start = start,
            .end = self.pos,
            .line = start_line,
            .col = start_col +| 1,
        } };
        if (kind == .anchor) {
            // An anchor is a node property; record its column so a key it
            // precedes opens its block mapping at the anchor's column.
            if (self.flow_level == 0 and self.prop_start_col == null) {
                self.prop_start_col = sigil_col;
                self.prop_start_line = start_line;
            }
            self.enqueue(tok);
        } else {
            // An alias is a complete node; it may itself be a mapping key
            // (`*a : v`), so route it through key promotion like a scalar.
            self.emitNodeWithOptionalKey(tok, sigil_col);
        }
    }

    /// A node property (anchor/tag) standing alone at an open block mapping's
    /// own indent is mis-indented: it sits at the key level (`seq:\n&a\n- x`),
    /// where the reference parser rejects it. A property at a deeper column
    /// (`seq:\n &a\n- x`), or one followed on the SAME line by its node, is
    /// fine. The shared reason code reuses `tab_indentation` only to route a
    /// clear "bad indentation" diagnostic.
    fn propertyMisindented(self: *Scanner, prop_col: i64) bool {
        if (self.flow_level != 0) return false;
        if (!atOpenMappingIndent(self, prop_col)) return false;
        // Same-line content after the property (a key or scalar) is valid:
        // peek past spaces/tabs for a line break before any content.
        var i = self.pos;
        while (i < self.input.len and (self.input[i] == ' ' or self.input[i] == '\t')) i += 1;
        return i >= self.input.len or self.input[i] == '\n' or self.input[i] == '\r';
    }

    /// A tag token. The span covers the whole tag text including the leading
    /// `!`, in all forms: `!`, `!suffix`, `!!suffix`, `!handle!suffix`,
    /// `!<verbatim>`. Handle/suffix resolution is the parser's job; the raw
    /// span carries enough to distinguish the forms. A tag may itself be a
    /// node property preceding a key, so key promotion is not applied here.
    fn fetchTag(self: *Scanner) void {
        const start = self.pos;
        const start_line = self.line;
        const start_col = self.col;
        const sigil_col: i64 = @intCast(self.col);
        self.advance(); // consume '!'
        if (self.peek() == '<') {
            // Verbatim `!<uri>`: run to the closing `>`.
            while (self.peek()) |c| {
                self.advance();
                if (c == '>') break;
            }
        } else {
            while (self.peek()) |c| {
                if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or isFlowIndicator(c)) break;
                self.advance();
            }
        }
        if (self.propertyMisindented(sigil_col)) {
            self.enqueue(.{ .kind = .invalid, .span = self.point(), .invalid_reason = .misindented_property });
            return;
        }
        // A tag is a node property; record its column so a key it precedes
        // opens its block mapping at the tag's column (`!!str a: b`).
        if (self.flow_level == 0 and self.prop_start_col == null) {
            self.prop_start_col = sigil_col;
            self.prop_start_line = start_line;
        }
        self.enqueue(.{ .kind = .tag, .span = .{
            .start = start,
            .end = self.pos,
            .line = start_line,
            .col = start_col +| 1,
        } });
    }

    // --- Documents and directives ------------------------------------------

    /// At column 0, classify a `---`/`...` marker line. Returns the marker
    /// kind when the three bytes are present and followed by a blank or end
    /// of line; otherwise null (the line is ordinary content).
    fn atDocumentMarker(self: *Scanner) ?TokenKind {
        const a = self.peek() orelse return null;
        const b = self.peekAt(1) orelse return null;
        const c = self.peekAt(2) orelse return null;
        const after = self.peekAt(3);
        const sep = after == null or after == ' ' or after == '\t' or
            after == '\n' or after == '\r';
        if (a == '-' and b == '-' and c == '-' and sep) return .document_start;
        if (a == '.' and b == '.' and c == '.' and sep) return .document_end;
        return null;
    }

    /// Emit a `---`/`...` marker. Both first close any open block
    /// collections (a document boundary ends all block structure), then
    /// emit the marker token spanning the three bytes.
    fn fetchDocumentMarker(self: *Scanner, kind: TokenKind) void {
        self.unrollIndent(-1);
        const span: RawSpan = .{
            .start = self.pos,
            .end = self.pos + 3,
            .line = self.line,
            .col = self.col +| 1,
        };
        self.advance();
        self.advance();
        self.advance();
        self.enqueue(.{ .kind = kind, .span = span });
    }

    /// A `%`-directive line (`%YAML 1.2`, `%TAG !h! prefix`). The span
    /// covers the whole line (excluding the trailing break); the parser
    /// interprets it.
    fn fetchDirective(self: *Scanner) void {
        const start = self.pos;
        const start_line = self.line;
        const start_col = self.col;
        var end = self.pos;
        while (self.peek()) |c| {
            if (c == '\n' or c == '\r') break;
            self.advance();
            if (c != ' ' and c != '\t') end = self.pos;
        }
        self.enqueue(.{ .kind = .directive, .span = .{
            .start = start,
            .end = end,
            .line = start_line,
            .col = start_col +| 1,
        } });
    }

    /// Plain scalar, possibly spanning multiple lines. The span runs from
    /// the first content byte to the last non-break content byte; the
    /// composer folds the interior line breaks (a lone break -> a space,
    /// blank lines -> newlines) per YAML's plain-fold rule.
    ///
    /// The first line ends at a value indicator (`: ` or `:` at EOL), a
    /// comment (` #`), or a line break. In flow context it also ends at
    /// `,`/`[`/`]`/`{`/`}` and at a bare `:`. A continuation line is folded
    /// in when, in BLOCK context, it indents past the enclosing block's
    /// indent and is not a comment or document marker; in FLOW context any
    /// line that is not a flow terminator continues. `scanPlainLine` stops
    /// at the first interior `: `/`#` that would end the scalar.
    fn scanPlainScalar(self: *Scanner) RawToken {
        const start = self.pos;
        const start_line = self.line;
        const start_col = self.col;
        const in_flow = self.flow_level > 0;
        // Continuation lines must indent past the enclosing block's indent
        // (the -1 stream sentinel lets a top-level scalar continue at col 0).
        const min_indent: i64 = self.indents[self.indents_len - 1];

        var line = self.scanPlainLine(start, in_flow);
        var end = line.end;

        // Fold in continuation lines while the structural conditions hold.
        while (self.peek() == '\n' or self.peek() == '\r') {
            if (!self.plainContinues(in_flow, min_indent)) break;
            // Consume the line break and the next line's leading blanks, then
            // scan its content; `end` advances to the last non-break byte.
            self.consumePlainBreaks();
            line = self.scanPlainLine(self.pos, in_flow);
            // A continuation line bearing a `: ` value indicator is a
            // mis-indented mapping key, not scalar content: the plain scalar
            // is invalid. (On the FIRST line a `: ` makes the scalar a key,
            // handled by the caller, so this only fires on continuations.)
            if (line.stopped_at_colon) {
                return .{ .kind = .invalid, .invalid_reason = .plain_key_in_continuation, .span = .{
                    .start = start,
                    .end = line.end,
                    .line = start_line,
                    .col = start_col +| 1,
                } };
            }
            end = line.end;
        }

        return .{
            .kind = .scalar,
            .style = .plain,
            .span = .{
                .start = start,
                .end = end,
                .line = start_line,
                .col = start_col +| 1,
            },
        };
    }

    const PlainLine = struct {
        /// Offset just past the last non-blank content byte (blanks trimmed).
        end: usize,
        /// Whether scanning stopped on a `: ` (or flow bare `:`) value
        /// indicator rather than a line break / comment / flow terminator.
        stopped_at_colon: bool,
    };

    /// Scan one line of plain-scalar content from the current position,
    /// stopping at the line break, an ending `: `/`:`-at-EOL, a ` #`
    /// comment, or (in flow) a flow indicator / bare `:`.
    fn scanPlainLine(self: *Scanner, line_start: usize, in_flow: bool) PlainLine {
        var end = self.pos;
        while (self.peek()) |c| {
            // SIMD fast-path: when a full vector of runway remains, bulk-skip
            // the run of plain content bytes that cannot be any stop candidate.
            // The skipped run contains no blanks (` `/`\t` are stop candidates),
            // so it is all content and `end` advances with `pos`. Gated on the
            // vector width so short scalars never pay the vector setup. The
            // per-byte loop then makes the context-dependent stop decision.
            if (self.input.len - self.pos >= simd_w and !isPlainStopCandidate(c)) {
                const skip = scanPlainFast(self.input[self.pos..]);
                self.pos += skip;
                self.col = satAdd(self.col, skip);
                end = self.pos;
                continue;
            }
            if (c == '\n' or c == '\r') break;
            if (c == ':' and (isBlankOrEnd(self.peekAt(1)) or
                (in_flow and isFlowEnd(self.peekAt(1)))))
                return .{ .end = end, .stopped_at_colon = true };
            if (c == '#' and (self.pos == line_start or isBlankPrev(self.input, self.pos))) break;
            if (in_flow and isFlowIndicator(c)) break;
            self.advance();
            if (c != ' ' and c != '\t') end = self.pos;
        }
        return .{ .end = end, .stopped_at_colon = false };
    }

    /// Decide whether the line after the current break belongs to the plain
    /// scalar. `self.peek()` is at a line break. Looks ahead WITHOUT
    /// advancing the scan position. In flow context the run continues unless
    /// the next content is a flow terminator. In block context the next
    /// content line must indent past `min_indent` and must not be a comment
    /// or `---`/`...` document marker. Blank lines alone do not end the run;
    /// the first non-blank line decides.
    fn plainContinues(self: *Scanner, in_flow: bool, min_indent: i64) bool {
        var i = self.pos;
        // Skip the run of blank lines (breaks + spaces/tabs). Track the column
        // of the first tab on the line that ends the run: a tab used as
        // indentation (within the required `min_indent + 1` columns, which must
        // be spaces) is illegal, but a tab past that is separation white space
        // and the line still folds in.
        var line_col: i64 = 0;
        var first_tab_col: i64 = -1;
        while (i < self.input.len) {
            const c = self.input[i];
            if (c == '\n' or c == '\r') {
                line_col = 0;
                first_tab_col = -1;
                i += 1;
            } else if (c == ' ') {
                line_col += 1;
                i += 1;
            } else if (c == '\t') {
                if (first_tab_col < 0) first_tab_col = line_col;
                line_col += 1;
                i += 1;
            } else break;
        }
        if (i >= self.input.len) return false; // trailing blanks: end of run
        // A tab inside the required indentation (at or before min_indent) is an
        // illegal block indent; let the indentation machinery flag it.
        if (!in_flow and first_tab_col >= 0 and first_tab_col <= min_indent) return false;

        // Column of the first non-blank byte. The blank-skip loop already
        // walked it forward (reset at each break, +1 per space/tab), so it
        // is `line_col`; recomputing it by scanning back to the line start
        // would be quadratic in line length.
        const col: i64 = line_col;
        const c = self.input[i];

        if (in_flow) {
            // A flow terminator or a comment line ends the run; otherwise
            // fold the next line in.
            return !(isFlowIndicator(c) or c == '#');
        }

        // Block context: dedent to/below the enclosing block ends the run.
        if (col <= min_indent) return false;
        // A comment line is not scalar content.
        if (c == '#') return false;
        // A document marker at column 0 ends the run. plainContinues only
        // sees col > min_indent >= -1, so a marker can sit at col 0 only when
        // min_indent is -1 (a top-level plain scalar); handle it there.
        if (col == 0 and self.isDocumentMarkerAt(i)) return false;
        return true;
    }

    /// True when the three bytes at `at` are a `---`/`...` document marker
    /// followed by a blank or end of line. Used by plain-scalar continuation
    /// to stop a top-level run at a document boundary.
    fn isDocumentMarkerAt(self: *Scanner, at: usize) bool {
        if (at + 3 > self.input.len) return false;
        const a = self.input[at];
        const b = self.input[at + 1];
        const c = self.input[at + 2];
        const after: ?u8 = if (at + 3 < self.input.len) self.input[at + 3] else null;
        const sep = after == null or after == ' ' or after == '\t' or
            after == '\n' or after == '\r';
        if (!sep) return false;
        return (a == '-' and b == '-' and c == '-') or (a == '.' and b == '.' and c == '.');
    }

    /// Consume the line break(s) and leading blanks up to the next line's
    /// first content byte, so the caller can scan that line's content. The
    /// blank-line folding is reconstructed by the composer from the span; the
    /// scanner only needs the position to land on content.
    fn consumePlainBreaks(self: *Scanner) void {
        while (self.peek()) |c| {
            if (c == '\n' or c == '\r' or c == ' ' or c == '\t') {
                self.advance();
            } else break;
        }
    }

    fn isFlowIndicator(c: u8) bool {
        return c == ',' or c == '[' or c == ']' or c == '{' or c == '}';
    }

    /// A byte that may directly follow a flow `:` value indicator (no space
    /// required in flow context): the flow structural bytes or end.
    fn isFlowEnd(b: ?u8) bool {
        return b == null or (b != null and isFlowIndicator(b.?));
    }

    fn isBlankPrev(input: []const u8, pos: usize) bool {
        if (pos == 0) return false;
        const p = input[pos - 1];
        return p == ' ' or p == '\t';
    }
};

// 16-wide SIMD: one @Vector(16, u8) chunk per iteration is the widest that
// maps to a single register on the targets we care about (NEON 128-bit,
// SSE2/AVX2). The bool-vector compare results OR together, @bitCast to a u16
// mask, and @ctz finds the first candidate stop byte. The skip functions only
// bulk-advance over bytes that are DEFINITELY not a stop byte; the per-byte
// scanner makes the (context-dependent) terminate-or-continue decision at the
// returned offset, so the scan stops on byte-identical positions.
const simd_w = 16;

/// Bytes inside a plain scalar that the per-byte scanner might stop on, plus
/// the blanks (` `/`\t`) -- a SUPERSET of the real stop set so SIMD never
/// skips past a terminator. Including blanks keeps the skipped run free of
/// trailing-blank bytes, so the caller's `end` (last non-blank offset) equals
/// the new position after a bulk skip. `\r` covers both CRLF and a lone CR
/// line break; flow indicators are always in the set (harmless to stop on
/// them in block context, where the per-byte loop just continues). Returns
/// bytes skipped.
fn scanPlainFast(bytes: []const u8) usize {
    var i: usize = 0;
    const nl: @Vector(simd_w, u8) = @splat('\n');
    const cr: @Vector(simd_w, u8) = @splat('\r');
    const hash: @Vector(simd_w, u8) = @splat('#');
    const colon: @Vector(simd_w, u8) = @splat(':');
    const comma: @Vector(simd_w, u8) = @splat(',');
    const lbrk: @Vector(simd_w, u8) = @splat('[');
    const rbrk: @Vector(simd_w, u8) = @splat(']');
    const lbrc: @Vector(simd_w, u8) = @splat('{');
    const rbrc: @Vector(simd_w, u8) = @splat('}');
    const sp: @Vector(simd_w, u8) = @splat(' ');
    const tab: @Vector(simd_w, u8) = @splat('\t');
    while (i + simd_w <= bytes.len) {
        const chunk: @Vector(simd_w, u8) = bytes[i..][0..simd_w].*;
        const stop = (chunk == nl) | (chunk == cr) | (chunk == hash) |
            (chunk == colon) | (chunk == comma) | (chunk == lbrk) |
            (chunk == rbrk) | (chunk == lbrc) | (chunk == rbrc) |
            (chunk == sp) | (chunk == tab);
        const mask: u16 = @bitCast(stop);
        if (mask != 0) return i + @ctz(mask);
        i += simd_w;
    }
    while (i < bytes.len) {
        if (isPlainStopCandidate(bytes[i])) return i;
        i += 1;
    }
    return i;
}

fn isPlainStopCandidate(c: u8) bool {
    return switch (c) {
        '\n', '\r', '#', ':', ',', '[', ']', '{', '}', ' ', '\t' => true,
        else => false,
    };
}

/// Skip bytes inside a double-quoted scalar that need no handling: not the
/// close quote `"`, not the escape `\`, and not a control byte (< 0x20, which
/// includes the `\n`/`\r` that drive line/col tracking and the column-0
/// document-marker check). Mirrors json's scanStringFast.
fn scanDoubleQuotedFast(bytes: []const u8) usize {
    var i: usize = 0;
    const quote: @Vector(simd_w, u8) = @splat('"');
    const backslash: @Vector(simd_w, u8) = @splat('\\');
    const ctrl_max: @Vector(simd_w, u8) = @splat(0x1f);
    while (i + simd_w <= bytes.len) {
        const chunk: @Vector(simd_w, u8) = bytes[i..][0..simd_w].*;
        const stop = (chunk == quote) | (chunk == backslash) | (chunk <= ctrl_max);
        const mask: u16 = @bitCast(stop);
        if (mask != 0) return i + @ctz(mask);
        i += simd_w;
    }
    while (i < bytes.len) {
        const c = bytes[i];
        if (c == '"' or c == '\\' or c < 0x20) return i;
        i += 1;
    }
    return i;
}

/// Skip bytes inside a single-quoted scalar: not the quote `'` (close or the
/// first half of a `''` escape) and not a control byte (< 0x20). Backslash is
/// ordinary content in single-quoted scalars, so it is not a stop byte.
fn scanSingleQuotedFast(bytes: []const u8) usize {
    var i: usize = 0;
    const quote: @Vector(simd_w, u8) = @splat('\'');
    const ctrl_max: @Vector(simd_w, u8) = @splat(0x1f);
    while (i + simd_w <= bytes.len) {
        const chunk: @Vector(simd_w, u8) = bytes[i..][0..simd_w].*;
        const stop = (chunk == quote) | (chunk <= ctrl_max);
        const mask: u16 = @bitCast(stop);
        if (mask != 0) return i + @ctz(mask);
        i += simd_w;
    }
    while (i < bytes.len) {
        const c = bytes[i];
        if (c == '\'' or c < 0x20) return i;
        i += 1;
    }
    return i;
}

const testing = std.testing;

fn kinds(src: []const u8, out: []TokenKind) !usize {
    var s: Scanner = .init(src);
    var i: usize = 0;
    while (s.next()) |t| : (i += 1) out[i] = t.kind;
    return i;
}

test "scan a simple block mapping" {
    var buf: [32]TokenKind = undefined;
    const n = try kinds("a: 1\nb: 2\n", &buf);
    try std.testing.expectEqualSlices(TokenKind, &.{
        .stream_start, .block_mapping_start,
        .key,          .scalar,
        .value,        .scalar,
        .key,          .scalar,
        .value,        .scalar,
        .block_end,    .stream_end,
    }, buf[0..n]);
}

test "scan a block sequence" {
    var buf: [32]TokenKind = undefined;
    const n = try kinds("- x\n- y\n", &buf);
    try std.testing.expectEqualSlices(TokenKind, &.{
        .stream_start, .block_sequence_start,
        .block_entry,  .scalar,
        .block_entry,  .scalar,
        .block_end,    .stream_end,
    }, buf[0..n]);
}

test "frameDocument finds the first document boundary" {
    // A `---` opening a SECOND document is the boundary that closes the first;
    // the consumed count is the marker's start byte.
    try std.testing.expectEqual(
        Scanner.Frame{ .complete = 5 },
        Scanner.frameDocument("doc1\n---\ndoc2\n"),
    );
    // A `...` terminates inclusively (through the three marker bytes).
    try std.testing.expectEqual(
        Scanner.Frame{ .complete = 8 },
        Scanner.frameDocument("doc1\n...\ndoc2\n"),
    );
    // A leading `---` opens the FIRST document, not a boundary; the next `---`
    // is the boundary.
    try std.testing.expectEqual(
        Scanner.Frame{ .complete = 9 },
        Scanner.frameDocument("---\ndoc1\n---\ndoc2\n"),
    );
    // A directive binds to the following document: it must NOT frame the
    // directive alone. With only a directive + `---` + content and no closing
    // marker, the whole buffer is one (trailing) document: need_more.
    try std.testing.expectEqual(Scanner.Frame.need_more, Scanner.frameDocument("%YAML 1.2\n---\nx: 1\n"));
}

test "frameDocument: no boundary yet is need_more" {
    // A single document with no terminating marker: the reader must confirm EOF.
    try std.testing.expectEqual(Scanner.Frame.need_more, Scanner.frameDocument("a: 1\nb: 2\n"));
    // Empty buffer.
    try std.testing.expectEqual(Scanner.Frame.need_more, Scanner.frameDocument(""));
    // A `---`/`...` inside a block scalar is content, not a boundary.
    try std.testing.expectEqual(
        Scanner.Frame.need_more,
        Scanner.frameDocument("lit: |\n  body\n  --- not a marker\n  ... nope\n"),
    );
    // A partial `--` straddling a chunk boundary is not yet a marker.
    try std.testing.expectEqual(Scanner.Frame.need_more, Scanner.frameDocument("a: 1\n--"));
}

test "nested mapping under sequence tracks indentation" {
    var buf: [64]TokenKind = undefined;
    const n = try kinds("- a: 1\n  b: 2\n- c: 3\n", &buf);
    try std.testing.expectEqualSlices(TokenKind, &.{
        .stream_start,        .block_sequence_start,
        .block_entry,         .block_mapping_start,
        .key,                 .scalar,
        .value,               .scalar,
        .key,                 .scalar,
        .value,               .scalar,
        .block_end,           .block_entry,
        .block_mapping_start, .key,
        .scalar,              .value,
        .scalar,              .block_end,
        .block_end,           .stream_end,
    }, buf[0..n]);
}

test "scalar token carries its content span" {
    var s: Scanner = .init("key: value\n");
    _ = s.next(); // stream_start
    _ = s.next(); // block_mapping_start
    _ = s.next(); // key
    const k = s.next().?; // scalar "key"
    try std.testing.expectEqualStrings("key", "key: value\n"[k.span.start..k.span.end]);
}

test "public next() span fields are u64; line/col derived via lineCol" {
    // next() returns a Token with offset-only u64 Span; nextRaw() returns a
    // RawToken with usize offsets plus incremental line/col. Both index the
    // source correctly for a normal input.
    const src = "a:\n  b: 1234\n";
    var s: Scanner = .init(src);
    _ = s.next(); // stream_start
    _ = s.next(); // block_mapping_start
    _ = s.next(); // key (a)
    const key_a = s.next().?; // scalar "a"
    // Public Token.span is u64, offset-only.
    try std.testing.expectEqual(u64, @TypeOf(key_a.span.start));
    try std.testing.expectEqual(@as(u64, 0), key_a.span.start);
    try std.testing.expectEqualStrings("a", src[key_a.span.start..key_a.span.end]);
    _ = s.next(); // value (:)
    _ = s.next(); // block_mapping_start (nested)
    _ = s.next(); // key (b)
    const key_b = s.next().?; // scalar "b" on line 2
    try std.testing.expectEqualStrings("b", src[key_b.span.start..key_b.span.end]);
    try std.testing.expectEqual(@as(u32, 2), key_b.span.lineCol(src).line);
    try std.testing.expectEqual(@as(u32, 3), key_b.span.lineCol(src).col);
    _ = s.next(); // value (:)
    const num = s.next().?; // scalar "1234"
    try std.testing.expectEqualStrings("1234", src[num.span.start..num.span.end]);
}

test "nextRaw() span fields are usize and index source directly" {
    // nextRaw() carries exact usize byte offsets plus incremental line/col,
    // consumed by the parser for indentation and same-line decisions.
    const src = "a:\n  b: 1234\n";
    var s: Scanner = .init(src);
    _ = s.nextRaw(); // stream_start
    _ = s.nextRaw(); // block_mapping_start
    _ = s.nextRaw(); // key (a)
    const key_a = s.nextRaw().?; // scalar "a"
    try std.testing.expectEqual(usize, @TypeOf(key_a.span.start));
    try std.testing.expectEqual(@as(usize, 0), key_a.span.start);
    try std.testing.expectEqualStrings("a", src[key_a.span.start..key_a.span.end]);
    _ = s.nextRaw(); // value (:)
    _ = s.nextRaw(); // block_mapping_start (nested)
    _ = s.nextRaw(); // key (b)
    const key_b = s.nextRaw().?; // scalar "b" on line 2
    try std.testing.expectEqualStrings("b", src[key_b.span.start..key_b.span.end]);
    try std.testing.expectEqual(@as(u32, 2), key_b.span.line);
    try std.testing.expectEqual(@as(u32, 3), key_b.span.col);
    _ = s.nextRaw(); // value (:)
    const num = s.nextRaw().?; // scalar "1234"
    try std.testing.expectEqualStrings("1234", src[num.span.start..num.span.end]);
}

test "mapping value on next line" {
    var buf: [32]TokenKind = undefined;
    const n = try kinds("key:\n  nested: 1\n", &buf);
    try std.testing.expectEqualSlices(TokenKind, &.{
        .stream_start, .block_mapping_start,
        .key,          .scalar,
        .value,        .block_mapping_start,
        .key,          .scalar,
        .value,        .scalar,
        .block_end,    .block_end,
        .stream_end,
    }, buf[0..n]);
}

test "empty input is just stream markers" {
    var buf: [8]TokenKind = undefined;
    const n = try kinds("", &buf);
    try std.testing.expectEqualSlices(TokenKind, &.{ .stream_start, .stream_end }, buf[0..n]);
}

/// Find the first scalar token in `src`, or null if none.
fn firstScalar(src: []const u8) ?Token {
    var s: Scanner = .init(src);
    while (s.next()) |t| if (t.kind == .scalar) return t;
    return null;
}

// --- Carried-forward correctness fixes ---

test "tab used as indentation is invalid" {
    var buf: [16]TokenKind = undefined;
    const n = try kinds("a:\n\tb: 1\n", &buf);
    try std.testing.expect(std.mem.indexOfScalar(TokenKind, buf[0..n], .invalid) != null);
}

test "leading tab before a flow collection is separation, not indentation" {
    var buf: [16]TokenKind = undefined;
    // A tab before a flow collection is separation white space; the flow
    // content carries no indentation, so no `.invalid` is produced.
    var n = try kinds("\t[\n\t]\n", &buf);
    try std.testing.expect(std.mem.indexOfScalar(TokenKind, buf[0..n], .invalid) == null);
    n = try kinds("\t{}\n", &buf);
    try std.testing.expect(std.mem.indexOfScalar(TokenKind, buf[0..n], .invalid) == null);
    // A leading tab before block content is still invalid indentation.
    n = try kinds("\tkey: v\n", &buf);
    try std.testing.expect(std.mem.indexOfScalar(TokenKind, buf[0..n], .invalid) != null);
}

test "CRLF carriage return is excluded from scalar spans" {
    const src = "a: 1\r\nb: 2\r\n";
    var s: Scanner = .init(src);
    var scalars: [4][]const u8 = undefined;
    var n: usize = 0;
    while (s.next()) |t| if (t.kind == .scalar) {
        scalars[n] = src[t.span.start..t.span.end];
        n += 1;
    };
    // keys "a","b" and values "1","2"; values must not carry the '\r'.
    try std.testing.expectEqualStrings("1", scalars[1]);
    try std.testing.expectEqualStrings("2", scalars[3]);
}

// --- New scalar styles, properties, flow, documents, directives ---

test "double and single quoted scalars carry style" {
    const tok = firstScalar("'it''s'\n").?;
    try std.testing.expectEqual(ScalarStyle.single, tok.style);
    try std.testing.expectEqualStrings("it''s", "'it''s'\n"[tok.span.start..tok.span.end]);

    const dq = firstScalar("\"a\\\"b\"\n").?;
    try std.testing.expectEqual(ScalarStyle.double, dq.style);
    try std.testing.expectEqualStrings("a\\\"b", "\"a\\\"b\"\n"[dq.span.start..dq.span.end]);
}

test "unterminated quoted scalar is invalid" {
    var buf: [8]TokenKind = undefined;
    const n = try kinds("'oops\n", &buf);
    try std.testing.expect(std.mem.indexOfScalar(TokenKind, buf[0..n], .invalid) != null);
}

test "literal and folded block scalars" {
    var found: ?ScalarStyle = null;
    var s: Scanner = .init("key: |-\n  line1\n  line2\n");
    while (s.next()) |t| if (t.kind == .scalar and (t.style == .literal or t.style == .folded)) {
        found = t.style;
    };
    try std.testing.expectEqual(ScalarStyle.literal, found.?);
}

test "block scalar header records chomp and explicit indent" {
    var s: Scanner = .init("k: |2-\n   body\n");
    var hdr: ?BlockHeader = null;
    var style: ?ScalarStyle = null;
    while (s.next()) |t| if (t.kind == .scalar and t.style == .literal) {
        hdr = t.block_header;
        style = t.style;
    };
    try std.testing.expectEqual(ScalarStyle.literal, style.?);
    try std.testing.expectEqual(Chomp.strip, hdr.?.chomp);
    try std.testing.expectEqual(@as(?u8, 2), hdr.?.explicit_indent);

    // Folded with keep chomping, indicators in the other order.
    var s2: Scanner = .init("k: >+\n  x\n");
    var hdr2: ?BlockHeader = null;
    while (s2.next()) |t| {
        if (t.kind == .scalar and t.style == .folded) hdr2 = t.block_header;
    }
    try std.testing.expectEqual(Chomp.keep, hdr2.?.chomp);
}

test "block scalar body span covers indented lines" {
    const src = "k: |\n  line1\n  line2\nnext: 1\n";
    var s: Scanner = .init(src);
    var body: ?[]const u8 = null;
    while (s.next()) |t| if (t.kind == .scalar and t.style == .literal) {
        body = src[t.span.start..t.span.end];
    };
    // The body span runs from the first body byte to the start of the
    // terminating line, so it carries each body line's trailing break.
    try std.testing.expectEqualStrings("  line1\n  line2\n", body.?);
}

test "anchor, alias, and tag tokens" {
    var buf: [24]TokenKind = undefined;
    const n = try kinds("- &a 1\n- *a\n", &buf);
    try std.testing.expect(std.mem.indexOfScalar(TokenKind, buf[0..n], .anchor) != null);
    try std.testing.expect(std.mem.indexOfScalar(TokenKind, buf[0..n], .alias) != null);
    var s: Scanner = .init("!!str x\n");
    var sawtag = false;
    while (s.next()) |t| {
        if (t.kind == .tag) sawtag = true;
    }
    try std.testing.expect(sawtag);
}

test "anchor span covers the name without the sigil" {
    const src = "- &anchor 1\n";
    var s: Scanner = .init(src);
    var name: ?[]const u8 = null;
    while (s.next()) |t| {
        if (t.kind == .anchor) name = src[t.span.start..t.span.end];
    }
    try std.testing.expectEqualStrings("anchor", name.?);
}

test "tag span covers the full tag text including sigil" {
    const src = "!!str x\n";
    var s: Scanner = .init(src);
    var tag: ?[]const u8 = null;
    while (s.next()) |t| {
        if (t.kind == .tag) tag = src[t.span.start..t.span.end];
    }
    try std.testing.expectEqualStrings("!!str", tag.?);
}

test "flow collections" {
    var buf: [32]TokenKind = undefined;
    const n = try kinds("{a: 1, b: [2, 3]}\n", &buf);
    try std.testing.expectEqual(TokenKind.flow_mapping_start, buf[1]);
    try std.testing.expect(std.mem.indexOfScalar(TokenKind, buf[0..n], .flow_sequence_start) != null);
    try std.testing.expect(std.mem.indexOfScalar(TokenKind, buf[0..n], .flow_entry) != null);
    try std.testing.expect(std.mem.indexOfScalar(TokenKind, buf[0..n], .flow_mapping_end) != null);
}

test "flow suspends block indentation" {
    // Indented content inside a flow collection produces no block_*_start.
    var buf: [32]TokenKind = undefined;
    const n = try kinds("[\n  1,\n  2,\n]\n", &buf);
    try std.testing.expect(std.mem.indexOfScalar(TokenKind, buf[0..n], .block_sequence_start) == null);
    try std.testing.expect(std.mem.indexOfScalar(TokenKind, buf[0..n], .block_mapping_start) == null);
    try std.testing.expect(std.mem.indexOfScalar(TokenKind, buf[0..n], .flow_sequence_start) != null);
    try std.testing.expect(std.mem.indexOfScalar(TokenKind, buf[0..n], .flow_sequence_end) != null);
}

test "flow as a block mapping value" {
    var buf: [32]TokenKind = undefined;
    const n = try kinds("k: [1, 2]\n", &buf);
    try std.testing.expectEqualSlices(TokenKind, &.{
        .stream_start, .block_mapping_start,
        .key,          .scalar,
        .value,        .flow_sequence_start,
        .scalar,       .flow_entry,
        .scalar,       .flow_sequence_end,
        .block_end,    .stream_end,
    }, buf[0..n]);
}

test "document markers and directives" {
    var buf: [24]TokenKind = undefined;
    const n = try kinds("%YAML 1.2\n---\na: 1\n...\n", &buf);
    try std.testing.expect(std.mem.indexOfScalar(TokenKind, buf[0..n], .directive) != null);
    try std.testing.expect(std.mem.indexOfScalar(TokenKind, buf[0..n], .document_start) != null);
    try std.testing.expect(std.mem.indexOfScalar(TokenKind, buf[0..n], .document_end) != null);
}

test "document start closes open block collections" {
    var buf: [32]TokenKind = undefined;
    const n = try kinds("a: 1\n---\nb: 2\n", &buf);
    // The block_end for the first mapping must precede document_start.
    const ds = std.mem.indexOfScalar(TokenKind, buf[0..n], .document_start).?;
    const be = std.mem.indexOfScalar(TokenKind, buf[0..n], .block_end).?;
    try std.testing.expect(be < ds);
}

// --- CRLF indicator recognition ---

test "CRLF nested mapping: colon before CR is a value indicator" {
    // c:\r\n  d: 3\r\n must produce the same token sequence as its LF form.
    var lf_buf: [32]TokenKind = undefined;
    var crlf_buf: [32]TokenKind = undefined;
    const lf_n = try kinds("c:\n  d: 3\n", &lf_buf);
    const crlf_n = try kinds("c:\r\n  d: 3\r\n", &crlf_buf);
    try std.testing.expectEqualSlices(TokenKind, lf_buf[0..lf_n], crlf_buf[0..crlf_n]);
}

test "CRLF block sequence matches LF form" {
    var lf_buf: [32]TokenKind = undefined;
    var crlf_buf: [32]TokenKind = undefined;
    const lf_n = try kinds("- a\n- b\n", &lf_buf);
    const crlf_n = try kinds("- a\r\n- b\r\n", &crlf_buf);
    try std.testing.expectEqualSlices(TokenKind, lf_buf[0..lf_n], crlf_buf[0..crlf_n]);
}

test "CRLF quoted key: value indicator recognized after closing quote" {
    // "c":\r\n  d: 3\r\n must recognize the value indicator (key, not a
    // bare scalar followed by a stray ':').
    var buf: [32]TokenKind = undefined;
    const n = try kinds("\"c\":\r\n  d: 3\r\n", &buf);
    try std.testing.expectEqualSlices(TokenKind, &.{
        .stream_start, .block_mapping_start,
        .key,          .scalar,
        .value,        .block_mapping_start,
        .key,          .scalar,
        .value,        .scalar,
        .block_end,    .block_end,
        .stream_end,
    }, buf[0..n]);
}

test "CRLF: dash before digit is not a block entry" {
    // x: -3\r\n must scan -3 as a plain scalar, not a block entry.
    var buf: [32]TokenKind = undefined;
    const n = try kinds("x: -3\r\n", &buf);
    try std.testing.expect(std.mem.indexOfScalar(TokenKind, buf[0..n], .block_entry) == null);
    try std.testing.expect(std.mem.indexOfScalar(TokenKind, buf[0..n], .scalar) != null);
}

// --- Explicit block-mapping keys (? key / : value) ---

test "block sequence at the mapping key's indent opens a sequence" {
    // `one:\n- a\n- b\ntwo: 2` -- the sequence value sits at the key column;
    // the `- ` indicators supply the indentation. The sequence must open and
    // close so `two:` is a sibling key, not mis-framed inside it.
    var buf: [40]TokenKind = undefined;
    const n = try kinds("one:\n- a\n- b\ntwo: 2\n", &buf);
    try std.testing.expectEqualSlices(TokenKind, &.{
        .stream_start,        .block_mapping_start,
        .key,                 .scalar,
        .value,               .block_sequence_start,
        .block_entry,         .scalar,
        .block_entry,         .scalar,
        .block_end,           .key,
        .scalar,              .value,
        .scalar,              .block_end,
        .stream_end,
    }, buf[0..n]);
}

test "node property alone at the mapping's own indent is invalid" {
    // `seq:\n&anchor\n- a` -- the anchor at the key column (col 0) is
    // mis-indented; an indented property (`seq:\n &anchor\n- a`) is fine.
    var buf: [24]TokenKind = undefined;
    var n = try kinds("seq:\n&anchor\n- a\n", &buf);
    try std.testing.expect(std.mem.indexOfScalar(TokenKind, buf[0..n], .invalid) != null);
    n = try kinds("seq:\n &anchor\n- a\n", &buf);
    try std.testing.expect(std.mem.indexOfScalar(TokenKind, buf[0..n], .invalid) == null);
    // A property followed on the same line by its key is valid even at the
    // mapping's indent (`!!str a: b`).
    n = try kinds("!!str a: b\n", &buf);
    try std.testing.expect(std.mem.indexOfScalar(TokenKind, buf[0..n], .invalid) == null);
}

test "explicit ? key opens a block mapping and : provides the value" {
    // `? key` rolls a block_mapping_start at the `?` column and emits a
    // `key` indicator; the line-leading `:` at that same indent is the
    // explicit value indicator for it.
    var buf: [16]TokenKind = undefined;
    const n = try kinds("? key\n: value\n", &buf);
    try std.testing.expectEqualSlices(TokenKind, &.{
        .stream_start, .block_mapping_start,
        .key,          .scalar,
        .value,        .scalar,
        .block_end,    .stream_end,
    }, buf[0..n]);
}

test "explicit ? key with no value yields no value indicator" {
    var buf: [16]TokenKind = undefined;
    const n = try kinds("? lonely\n", &buf);
    try std.testing.expectEqualSlices(TokenKind, &.{
        .stream_start, .block_mapping_start,
        .key,          .scalar,
        .block_end,    .stream_end,
    }, buf[0..n]);
}

test "tab as a separator after an indicator is valid, as indentation is not" {
    // A tab separating a `-`/`:` indicator from a SCALAR is valid white space.
    try std.testing.expect(firstScalar("- foo:\tbar\n") != null);
    var buf: [16]TokenKind = undefined;
    var n = try kinds("-\tbaz\n", &buf);
    try std.testing.expect(std.mem.indexOfScalar(TokenKind, buf[0..n], .invalid) == null);
    try std.testing.expect(std.mem.indexOfScalar(TokenKind, buf[0..n], .block_entry) != null);

    // A tab before a node that OPENS a block collection is illegal indentation.
    n = try kinds("-\t-\n", &buf); // nested compact sequence
    try std.testing.expect(std.mem.indexOfScalar(TokenKind, buf[0..n], .invalid) != null);
    n = try kinds("?\tkey:\n", &buf); // key opening a block mapping
    try std.testing.expect(std.mem.indexOfScalar(TokenKind, buf[0..n], .invalid) != null);

    // A tab in leading indentation (line start) remains illegal.
    n = try kinds("a:\n\tb: 1\n", &buf);
    try std.testing.expect(std.mem.indexOfScalar(TokenKind, buf[0..n], .invalid) != null);
}

test "explicit key mixes with implicit entries" {
    // An implicit `a: 1` opens the mapping; `? b` / `: 2` is an explicit
    // entry at the same indent; `c: 3` is implicit again.
    var buf: [32]TokenKind = undefined;
    const n = try kinds("a: 1\n? b\n: 2\nc: 3\n", &buf);
    try std.testing.expectEqualSlices(TokenKind, &.{
        .stream_start, .block_mapping_start,
        .key,          .scalar,
        .value,        .scalar,
        .key,          .scalar,
        .value,        .scalar,
        .key,          .scalar,
        .value,        .scalar,
        .block_end,    .stream_end,
    }, buf[0..n]);
}

test "explicit ? key in flow emits a single key, not a doubled one" {
    // In a flow collection the `?` emits the key indicator; the following
    // scalar is the key's content and must NOT promote to a second implicit
    // key. `{? a : b}` is `key scalar value scalar`, not `key key scalar ...`.
    var buf: [24]TokenKind = undefined;
    var n = try kinds("{? a : b}", &buf);
    try std.testing.expectEqualSlices(TokenKind, &.{
        .stream_start,        .flow_mapping_start,
        .key,                 .scalar,
        .value,               .scalar,
        .flow_mapping_end,    .stream_end,
    }, buf[0..n]);

    // Two explicit keys: each `?` arms suppression independently.
    n = try kinds("{? a: b, ? c: d}", &buf);
    try std.testing.expectEqualSlices(TokenKind, &.{
        .stream_start,        .flow_mapping_start,
        .key,                 .scalar,
        .value,               .scalar,
        .flow_entry,          .key,
        .scalar,              .value,
        .scalar,              .flow_mapping_end,
        .stream_end,
    }, buf[0..n]);
}

// --- Deferred simple keys: flow collection as a block-mapping key ---

/// Drive a scanner to stream end, asserting it terminates within `cap`
/// tokens. The cap turns a regressed unbounded candidate-buffering loop into
/// a fast FAILURE instead of a hang: the one-line + `simple_key_max` bound
/// guarantees termination, so a spin past the cap is a bug.
fn drainBoundedScan(src: []const u8, cap: usize) !void {
    var s: Scanner = .init(src);
    var n: usize = 0;
    while (s.next()) |_| {
        n += 1;
        if (n > cap) return error.ScannerRunaway;
    }
}

test "flow sequence as a block mapping key splices block_mapping_start and key" {
    var buf: [32]TokenKind = undefined;
    const n = try kinds("[a, b]: value\n", &buf);
    try std.testing.expectEqualSlices(TokenKind, &.{
        .stream_start,        .block_mapping_start,
        .key,                 .flow_sequence_start,
        .scalar,              .flow_entry,
        .scalar,              .flow_sequence_end,
        .value,               .scalar,
        .block_end,           .stream_end,
    }, buf[0..n]);
}

test "flow mapping as a block mapping key splices block_mapping_start and key" {
    var buf: [32]TokenKind = undefined;
    const n = try kinds("{a: 1}: value\n", &buf);
    try std.testing.expectEqualSlices(TokenKind, &.{
        .stream_start,        .block_mapping_start,
        .key,                 .flow_mapping_start,
        .key,                 .scalar,
        .value,               .scalar,
        .flow_mapping_end,    .value,
        .scalar,              .block_end,
        .stream_end,
    }, buf[0..n]);
}

test "flow value (no following colon) is unchanged by the candidate path" {
    // A flow collection NOT followed by a `:` stays an ordinary value: no
    // block_mapping_start/key is spliced.
    var buf: [32]TokenKind = undefined;
    const n = try kinds("k: [1, 2]\n", &buf);
    try std.testing.expectEqualSlices(TokenKind, &.{
        .stream_start, .block_mapping_start,
        .key,          .scalar,
        .value,        .flow_sequence_start,
        .scalar,       .flow_entry,
        .scalar,       .flow_sequence_end,
        .block_end,    .stream_end,
    }, buf[0..n]);
    // A bare top-level flow node is likewise untouched.
    const m = try kinds("[1, 2]\n", &buf);
    try std.testing.expectEqualSlices(TokenKind, &.{
        .stream_start,       .flow_sequence_start,
        .scalar,             .flow_entry,
        .scalar,             .flow_sequence_end,
        .stream_end,
    }, buf[0..m]);
}

test "a multi-line flow node is not promoted to a block simple key" {
    // The flow node spans a line break, so it cannot serve as a single-line
    // block implicit key: the candidate path leaves it as an ordinary value,
    // so no `key` indicator is spliced ahead of its `flow_sequence_start`.
    var buf: [32]TokenKind = undefined;
    const n = try kinds("[a,\nb]: c\n", &buf);
    const fss = std.mem.indexOfScalar(TokenKind, buf[0..n], .flow_sequence_start).?;
    try std.testing.expect(fss == 0 or buf[fss - 1] != .key);
}

test "flow-as-key opening a block mapping after an inline value is invalid" {
    // `a: [x]: y` turns a mapping value into a nested inline key, which is
    // invalid -- the candidate path must splice an `.invalid`, mirroring the
    // plain/quoted key guard.
    var buf: [64]TokenKind = undefined;
    const n = try kinds("a: [x]: y\n", &buf);
    try std.testing.expect(std.mem.indexOfScalar(TokenKind, buf[0..n], .invalid) != null);
}

test "flow-as-key candidate buffering terminates within the bound" {
    // The one-line + simple_key_max bound guarantees the candidate scan
    // terminates; a tight cap turns a regressed unbounded loop into a fast
    // failure instead of a hang. Includes an over-long flow node (past the
    // byte bound) and an unterminated one.
    const cap = 4096;
    try drainBoundedScan("[a, b]: value\n", cap);
    try drainBoundedScan("{a: 1}: value\n", cap);
    try drainBoundedScan("[" ++ ("x," ** 700) ++ "x]: v\n", cap);
    try drainBoundedScan("[a, b\n", cap);
    try drainBoundedScan("[a, b", cap);
}


test "flow node glued to inline key/value framing terminates within the bound" {
    // `a: {}b: 1` rejects the glued `b:` as a nested inline block mapping. The
    // rejection must CONSUME the offending `:`; leaving it makes the scanner
    // re-process the same byte forever, an unbounded zero-width `.invalid`
    // stream that hangs the error-recovery path. A tight cap turns that
    // regression into a fast `ScannerRunaway` instead of a hang.
    const cap = 4096;
    try drainBoundedScan("a: {}b: 1\n", cap);
    try drainBoundedScan("a: {}b: []\n", cap);
    try drainBoundedScan("tags: [x,y]\nempty_map: {}empty_seq: []\n", cap);
}

test "scanner emits comment tokens in comment mode" {
    var s = Scanner.initWithComments("a: 1 # hi\n# full line\nb: 2\n");
    var comments: usize = 0;
    while (s.next()) |t| if (t.kind == .comment) {
        comments += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), comments);
}

test "comment token span covers # to end of line, excluding newline" {
    const src = "a: 1 # hi\n";
    var s = Scanner.initWithComments(src);
    var c: ?@TypeOf(s.next().?) = null;
    while (s.next()) |t| if (t.kind == .comment) {
        c = t;
    };
    try std.testing.expectEqualStrings("# hi", src[c.?.span.start..c.?.span.end]);
}

test "default scanner still skips comments (comment mode off)" {
    var s = Scanner.init("a: 1 # hi\n# full\nb: 2\n");
    while (s.next()) |t| try std.testing.expect(t.kind != .comment);
}

test "comment mode does not alter structural tokens" {
    const src = "a: 1 # hi\nb:\n  - x # c\n";
    var def = Scanner.init(src);
    var withc = Scanner.initWithComments(src);
    while (true) {
        const d = def.next();
        var w = withc.next();
        while (w != null and w.?.kind == .comment) w = withc.next();
        if (d == null and w == null) break;
        try std.testing.expectEqual(d.?.kind, w.?.kind);
        try std.testing.expectEqual(d.?.span.start, w.?.span.start);
        try std.testing.expectEqual(d.?.span.end, w.?.span.end);
    }
}

test "BlockHeader.header_start is u64 and stores block-scalar offset verbatim" {
    // Type: field is u64, not the former u32.
    comptime try std.testing.expectEqual(u64, @TypeOf(@as(BlockHeader, .{}).header_start));

    // Value round-trip past 4 GiB: BlockHeader can hold offsets > maxInt(u32)
    // without saturation. The former @min(..., maxInt(u32)) guard would have
    // truncated this to maxInt(u32).
    const past_4gib: u64 = @as(u64, std.math.maxInt(u32)) + 100;
    const h: BlockHeader = .{ .header_start = past_4gib };
    try std.testing.expectEqual(past_4gib, h.header_start);

    // Functional: scanning a literal block scalar records the exact byte offset
    // of the | indicator in header_start, with no capping or rounding.
    // In "k: |\n  body\n" the | is at byte 3.
    var s: Scanner = .init("k: |\n  body\n");
    var hdr: ?BlockHeader = null;
    while (s.next()) |t| if (t.kind == .scalar and t.style == .literal) {
        hdr = t.block_header;
    };
    try std.testing.expectEqual(@as(u64, 3), hdr.?.header_start);
}
