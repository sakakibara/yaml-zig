//! Event-stream parser layered over the scanner.
//!
//! Turns the scanner's flat token stream into a YAML event stream: the
//! yaml-test-suite ground-truth representation. Modeled on the STRUCTURE
//! of libyaml's parser.c -- a flat explicit state stack, never recursion.
//! Descending into a collection pushes the continuation state; the matching
//! end token pops it.
//!
//! The scanner already emits explicit collection-start/end and key/value
//! indicator tokens, so this layer's job is:
//!
//!   1. Frame documents. The scanner emits `document_start`/`document_end`
//!      only for explicit `---`/`...` markers; implicit documents have no
//!      markers. The parser synthesizes a `document_start` before the first
//!      content node and a `document_end` at each boundary (end of stream,
//!      explicit marker, or a new `---`).
//!   2. Synthesize empty scalars. A mapping key with no value, a value
//!      indicator with nothing after it, or an empty document all yield an
//!      empty plain `scalar` event (value = ""); the composer resolves it.
//!   3. Attach buffered node properties (anchor/tag) to the next node event.
//!   4. Translate token kinds to event kinds, dropping the bare key/value/
//!      entry indicators that only drive state transitions.
//!
//! Allocation model: the state stack is a `std.ArrayList(State)` owned by
//! the parser, gated by `max_depth`. Properties (anchor/tag/alias-name) are
//! source slices, never copied. The caller owns the allocator (typically an
//! arena from parse()).

const std = @import("std");
const scanner = @import("scanner.zig");
const diagnostic = @import("diagnostic.zig");

const value = @import("value.zig");
/// The parser carries usize byte offsets and incremental line/col internally
/// (RawSpan). The scanner maintains line/col as it advances, and the parser
/// consults them for same-line and indentation decisions. Public `Event.span`
/// is the offset-only u64 `Span`, materialized by copying offsets straight
/// through (no cap) and dropping line/col.
const Span = value.Span;
const RawSpan = value.RawSpan;
const diagSpan = value.diagSpan;
const Sink = diagnostic.Sink;
const Scanner = scanner.Scanner;
/// Internal token type: usize byte offsets, used throughout the parser.
const Token = scanner.RawToken;
const TokenKind = scanner.TokenKind;
const ScalarStyle = scanner.ScalarStyle;
const BlockHeader = scanner.BlockHeader;

pub const EventKind = enum {
    stream_start,
    stream_end,
    document_start,
    document_end,
    mapping_start,
    mapping_end,
    sequence_start,
    sequence_end,
    scalar,
    alias,
};

pub const Event = struct {
    kind: EventKind,
    /// Source byte range as u64 offsets, addressing any in-memory input
    /// without a cap. The parser materializes this from its internal usize
    /// offsets when producing each event. Line/col are derived on demand via
    /// `Span.lineCol`.
    span: Span,
    /// Anchor name (no sigil), a slice into source. Set on the node the
    /// anchor decorates.
    anchor: ?[]const u8 = null,
    /// The node's tag, fully resolved to its qualified text: `%TAG` handles
    /// and the primary/secondary defaults are applied and the suffix is
    /// percent-decoded, so `!!str` is `tag:yaml.org,2002:str` and a local
    /// `!foo` is `!foo`. A source slice when resolution is a no-op, else
    /// arena-allocated. Null when the node has no tag.
    tag: ?[]const u8 = null,
    scalar_style: ScalarStyle = .plain,
    /// Raw scalar content slice into source (cooked by the composer:
    /// unescape / fold / chomp).
    value: []const u8 = "",
    /// Alias target name, a slice into source. Set only on `.alias`.
    alias_name: []const u8 = "",
    /// Collection style: true for flow (`[]`/`{}`), false for block.
    flow: bool = false,
    /// Document framing: true when this `.document_start`/`.document_end`
    /// corresponds to an explicit `---`/`...` marker in the source, false
    /// when the boundary is implicit. Meaningless on other event kinds.
    explicit: bool = false,
    /// Block-scalar header, threaded through for `.literal`/`.folded`
    /// scalars so the composer can fold + chomp without re-parsing.
    block_header: ?BlockHeader = null,
};

pub const Error = error{ YamlParseError, NestingTooDeep } || std.mem.Allocator.Error;

/// What to do at the next pull, given the current structural position.
/// Mirrors libyaml's parser_state enum but trimmed: the scanner does the
/// indentation bookkeeping, so we only track the cycle inside each
/// collection plus the document/stream framing.
const State = enum {
    /// Expect a block-context node (the document root, a sequence entry's
    /// node, or a mapping value's node).
    block_node,
    /// In a block sequence: expect a `block_entry` (then its node) or a
    /// `block_end`.
    block_sequence_entry,
    /// In a block mapping: expect a `key` (then key node), an implicit
    /// `value`, or a `block_end`.
    block_mapping_key,
    /// In a block mapping after a `key`+node: expect a `value` indicator.
    block_mapping_value,
    /// In a flow sequence: expect an entry node, a `flow_entry`, or end.
    flow_sequence_entry,
    /// In a flow mapping: expect a key node, a `flow_entry`, or end.
    flow_mapping_key,
    /// In a flow mapping after a key node: expect a `value` indicator.
    flow_mapping_value,
    /// In a flow mapping after a bare entry node (`{a, b}`): supply the
    /// empty value, then cycle back to the key state.
    flow_mapping_bare_value,
    /// Single-pair mapping synthesized as a flow-sequence element
    /// (`[a: 1]`): key half, value half, and close.
    flow_seq_pair_key,
    flow_seq_pair_value,
    flow_seq_pair_end,
};

/// Cursor position within a flow collection, used to reject empty entries.
/// `empty`: just opened, no element and no `,` yet (a bare `[]`/`{}` is
/// fine, but a `,` here is a leading comma). `after_elem`: an element was
/// supplied (a `,` or a close is fine). `after_comma`: a `,` was seen with
/// no following element yet (another `,` is a double comma, a close is a
/// trailing comma -- both invalid).
const FlowPos = enum { empty, after_elem, after_comma };

pub const Parser = struct {
    pub const max_depth = Scanner.max_depth;

    scanner: Scanner,
    input: []const u8,
    states: std.ArrayList(State),
    allocator: std.mem.Allocator,

    /// Error funnel, set by the composer when diagnostics are requested.
    /// When null, `fail` returns a bare `error.YamlParseError` with no
    /// allocation, preserving the bail-on-first-error path.
    sink: ?*Sink = null,

    /// One-token lookahead. Filled lazily by `peek`.
    ahead: ?Token = null,

    /// Per-flow-collection cursor position, tracking where the next token
    /// sits relative to elements and `,` separators so empty entries are
    /// rejected: a leading/doubled `,` (`[ ,` / `[a, ,`) and a trailing `,`
    /// (`[a, ]`) are both invalid. Pushed when a flow collection opens,
    /// popped when it closes; parallel to the flow states on `states`.
    flow_pos: std.ArrayList(FlowPos) = .empty,

    stream_started: bool = false,
    stream_ended: bool = false,
    /// A `%YAML` directive has been seen for the document not yet opened.
    /// A second `%YAML` before the same `---` is invalid; reset when a
    /// document opens.
    yaml_directive_seen: bool = false,
    /// Whether a document is currently open (a document_start was emitted
    /// without a matching document_end yet).
    in_document: bool = false,
    /// Line of the most recent explicit `---` marker, or null for an implicit
    /// document start. Used to reject a block collection whose first token
    /// lands on the same line as the `---` (block content cannot open on
    /// the directive-end line per the YAML spec).
    doc_start_line: ?u32 = null,

    /// `%TAG` shorthand handles in effect for the NEXT document: handle text
    /// (`!`, `!!`, `!h!`, all including their delimiters) -> prefix. Scoped
    /// per document, like the YAML spec requires; cleared at each document
    /// boundary. A handle not in the table falls back to its default (the
    /// primary `!` -> `!`, the secondary `!!` -> `tag:yaml.org,2002:`); a
    /// NAMED handle (`!h!`) with no directive is an undefined-handle error.
    tag_handles: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// Buffered node properties, attached to the next node event and then
    /// cleared. The scanner emits at most one anchor and one tag per node.
    pending_anchor: ?[]const u8 = null,
    pending_tag: ?[]const u8 = null,
    /// Span of the first buffered property, used as the synthesized node's
    /// span when the node turns out to be empty. Carried as RawSpan internally
    /// to preserve usize offsets; converted to u32 Span when an Event is built.
    pending_span: ?RawSpan = null,
    /// Line of the most recently buffered property, to detect when a new
    /// property begins on a later line (the prior line's props decorated an
    /// outer node, e.g. a mapping, while the new ones decorate its first key).
    pending_line: u32 = 0,
    /// Properties from an EARLIER line than `pending_*`, carried for an outer
    /// node (a block mapping opened retroactively at its first key). Applied
    /// to the mapping start; `pending_*` then stays for the key.
    carried_anchor: ?[]const u8 = null,
    carried_tag: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) Parser {
        return .{
            .scanner = Scanner.init(input),
            .input = input,
            .states = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.states.deinit(self.allocator);
        self.flow_pos.deinit(self.allocator);
        self.tag_handles.deinit(self.allocator);
    }

    /// Push a fresh flow collection (just opened: no element, no comma yet).
    fn pushFlow(self: *Parser) Error!void {
        try self.flow_pos.append(self.allocator, .empty);
    }

    fn popFlow(self: *Parser) void {
        _ = self.flow_pos.pop();
    }

    fn flowPos(self: *Parser) FlowPos {
        if (self.flow_pos.items.len == 0) return .after_elem;
        return self.flow_pos.items[self.flow_pos.items.len - 1];
    }

    fn setFlowPos(self: *Parser, v: FlowPos) void {
        if (self.flow_pos.items.len == 0) return;
        self.flow_pos.items[self.flow_pos.items.len - 1] = v;
    }

    fn slice(self: *Parser, span: RawSpan) []const u8 {
        return self.input[span.start..span.end];
    }

    fn peek(self: *Parser) Token {
        if (self.ahead) |t| return t;
        const t = self.scanner.nextRaw() orelse Token{
            .kind = .stream_end,
            .span = .{ .start = self.input.len, .end = self.input.len, .line = 0, .col = 1 },
        };
        self.ahead = t;
        return t;
    }

    fn take(self: *Parser) Token {
        const t = self.peek();
        self.ahead = null;
        return t;
    }

    pub fn setSink(self: *Parser, sink: *Sink) void {
        self.sink = sink;
    }

    /// Grammar-error funnel. Points the diagnostic at the current
    /// lookahead token (the one that could not be consumed). Routes
    /// through the sink when set; otherwise a bare error.
    fn fail(self: *Parser, msg: []const u8) Error {
        return self.failAt(self.peek().span, msg);
    }

    /// Funnel for a failure at a known token's RawSpan. Drops the internal
    /// line/col; the diagnostic derives location from the offset and source.
    fn failAt(self: *Parser, span: RawSpan, msg: []const u8) Error {
        return self.failSpan(diagSpan(span), msg);
    }

    /// Funnel for a failure at an already-materialized offset-only `Span`.
    fn failSpan(self: *Parser, span: Span, msg: []const u8) Error {
        if (self.sink) |s| return s.fail(span, msg);
        return error.YamlParseError;
    }

    /// Funnel a scanner `.invalid` token, mapping its reason to a specific
    /// message at the token's span.
    fn failInvalid(self: *Parser, t: Token) Error {
        const msg = switch (t.invalid_reason) {
            .tab_indentation => "found tab used for indentation",
            .unterminated_single_quote => "unterminated single-quoted scalar",
            .unterminated_double_quote => "unterminated double-quoted scalar",
            .queue_overflow => "input nesting exceeds scanner capacity",
            .plain_key_in_continuation => "mapping key in plain scalar continuation",
            .block_scalar_header => "malformed block scalar header",
            .unseparated_comment => "comment must be preceded by white space",
            .misindented_property => "node property at the mapping's own indent",
            .multiline_implicit_key => "implicit mapping key spans multiple lines",
            .nested_block_mapping_inline => "block mapping key not allowed mid-line after a value",
            .bare_indicator_in_flow => "'-' or '?' indicator not allowed before a flow indicator",
            .none => "invalid token",
        };
        return self.failAt(t.span, msg);
    }

    /// Recovery: discard the parser's in-document state and skip tokens
    /// until the next document boundary so a clean re-frame can resume on
    /// the following document. Resets the state stack and the in_document
    /// flag (both stale after a mid-document failure), then consumes
    /// tokens up to but not including the next `---`/`...`/stream end.
    /// Always makes progress: each iteration consumes one token toward EOF.
    pub fn recoverToDocumentBoundary(self: *Parser) void {
        self.states.clearRetainingCapacity();
        self.flow_pos.clearRetainingCapacity();
        self.in_document = false;
        self.pending_anchor = null;
        self.pending_tag = null;
        self.pending_span = null;
        self.carried_anchor = null;
        self.carried_tag = null;
        while (true) {
            const t = self.peek();
            switch (t.kind) {
                .stream_end => return,
                .document_start, .document_end => {
                    // Leave the marker unconsumed: the document framing
                    // re-reads it to open/close the next document.
                    return;
                },
                else => _ = self.take(),
            }
        }
    }

    fn pushState(self: *Parser, s: State) Error!void {
        if (self.states.items.len >= max_depth) return error.NestingTooDeep;
        try self.states.append(self.allocator, s);
    }

    fn popState(self: *Parser) void {
        _ = self.states.pop();
    }

    fn topState(self: *Parser) ?State {
        if (self.states.items.len == 0) return null;
        return self.states.items[self.states.items.len - 1];
    }

    fn setTop(self: *Parser, s: State) void {
        self.states.items[self.states.items.len - 1] = s;
    }

    /// Drain buffered anchor/tag onto `ev` and clear them. A node carries the
    /// merge of its carried (earlier-line) and pending (same-line) properties;
    /// only a retroactively-opened block mapping splits the two between itself
    /// and its first key.
    fn applyProperties(self: *Parser, ev: *Event) void {
        ev.anchor = self.carried_anchor orelse self.pending_anchor;
        ev.tag = self.carried_tag orelse self.pending_tag;
        self.pending_anchor = null;
        self.pending_tag = null;
        self.pending_span = null;
        self.carried_anchor = null;
        self.carried_tag = null;
    }

    /// Drain CARRIED (earlier-line) properties onto `ev` -- the outer node's
    /// properties when a mapping is opened retroactively at its first key.
    /// Leaves the same-line `pending_*` for the key node.
    fn applyCarried(self: *Parser, ev: *Event) void {
        ev.anchor = self.carried_anchor;
        ev.tag = self.carried_tag;
        self.carried_anchor = null;
        self.carried_tag = null;
    }

    /// Buffer anchor/tag tokens into the pending node properties. Records
    /// the span of the first one for empty-node synthesis. A property that
    /// opens a NEW line, when a prior line's properties are still pending,
    /// shifts those into the carried slots: they decorate an outer node (a
    /// block mapping) while the new property decorates its first key.
    fn bufferProperty(self: *Parser, t: Token) void {
        if (self.pending_anchor != null or self.pending_tag != null) {
            if (t.span.line != self.pending_line and self.carried_anchor == null and self.carried_tag == null) {
                self.carried_anchor = self.pending_anchor;
                self.carried_tag = self.pending_tag;
                self.pending_anchor = null;
                self.pending_tag = null;
                // The carried set owned the old first-property span; this new
                // property starts the pending set, so its span leads now.
                self.pending_span = null;
            }
        }
        if (self.pending_span == null) self.pending_span = t.span;
        self.pending_line = t.span.line;
        switch (t.kind) {
            .anchor => self.pending_anchor = self.slice(t.span),
            .tag => self.pending_tag = self.slice(t.span),
            else => unreachable,
        }
    }

    /// True when an anchor/tag has been buffered with no node attached yet.
    /// In a flow collection such a lone property still decorates a node -- an
    /// empty scalar -- so the close/separator paths must flush it rather than
    /// drop it (`[&x]` -> `[null]`, not `[]`).
    fn hasBufferedProperty(self: *Parser) bool {
        return self.pending_anchor != null or self.pending_tag != null or
            self.carried_anchor != null or self.carried_tag != null;
    }

    /// The empty scalar a lone buffered property decorates, anchored at the
    /// property's own span when known.
    fn emptyPropertyScalar(self: *Parser, fallback: RawSpan) Event {
        const span = self.pending_span orelse fallback;
        return self.emptyScalar(.{ .start = span.start, .end = span.start, .line = span.line, .col = span.col });
    }

    /// True for tokens that introduce a node (a scalar, alias, node
    /// property, or collection start). Used to reject content on a `...`
    /// document-end line.
    fn isContentToken(kind: TokenKind) bool {
        return switch (kind) {
            .scalar, .alias, .anchor, .tag, .block_entry, .key, .block_sequence_start, .block_mapping_start, .flow_sequence_start, .flow_mapping_start => true,
            else => false,
        };
    }

    /// Materialize the public offset-only `Span` for an Event from a RawSpan:
    /// copy the u64 byte offsets (any in-memory input fits) and drop the
    /// internal line/col. The single conversion point.
    fn toSpan(rs: RawSpan) Span {
        return .{ .start = rs.start, .end = rs.end };
    }

    /// Build an empty plain scalar event at the current position, carrying
    /// any pending properties.
    fn emptyScalar(self: *Parser, raw: RawSpan) Event {
        var ev: Event = .{ .kind = .scalar, .span = toSpan(raw), .scalar_style = .plain, .value = "" };
        self.applyProperties(&ev);
        return ev;
    }

    /// Build a node event from a content token (scalar or alias), carrying
    /// any pending properties.
    fn nodeEvent(self: *Parser, t: Token) Event {
        var ev: Event = switch (t.kind) {
            .scalar => .{
                .kind = .scalar,
                .span = toSpan(t.span),
                .scalar_style = t.style,
                .value = self.slice(t.span),
                .block_header = if (t.style == .literal or t.style == .folded) t.block_header else null,
            },
            .alias => .{
                .kind = .alias,
                .span = toSpan(t.span),
                .alias_name = self.slice(t.span),
            },
            else => unreachable,
        };
        self.applyProperties(&ev);
        return ev;
    }

    /// Pull the next event, or null once `stream_end` has been delivered.
    pub fn next(self: *Parser) Error!?Event {
        if (self.stream_ended) return null;

        if (!self.stream_started) {
            self.stream_started = true;
            const t = self.peek();
            if (t.kind == .stream_start) _ = self.take();
            return Event{ .kind = .stream_start, .span = toSpan(t.span) };
        }

        // Top-level loop: drive transitions until an event is produced. A
        // node event's tag is carried as the RAW scanner text through the
        // step logic and resolved here, once, against the document's `%TAG`
        // handles -- which are still in scope (the closing boundary that
        // drops them is a later token).
        while (true) {
            if (self.topState()) |state| {
                if (try self.stepState(state)) |ev| return try self.finishEvent(ev);
            } else {
                if (try self.stepDocument()) |ev| return try self.finishEvent(ev);
            }
        }
    }

    /// Resolve a node event's raw tag to its fully-qualified text before the
    /// event leaves the parser.
    fn finishEvent(self: *Parser, ev: Event) Error!Event {
        var out = ev;
        if (out.tag) |raw| out.tag = try self.resolveTag(raw, out.span);
        return out;
    }

    /// Stream/document framing when the state stack is empty (between
    /// documents or at stream boundaries).
    fn stepDocument(self: *Parser) Error!?Event {
        const t = self.peek();

        // A document's content just finished but its document_end has not
        // been emitted yet. Close it before handling the next marker.
        if (self.in_document) {
            // A directive directly after document content (`scalar\n%YAML...`)
            // is invalid: a directive may only follow an explicit `...` end or
            // begin the stream. Reject before the implicit-close path treats it
            // as a document boundary.
            if (t.kind == .directive)
                return self.failAt(t.span, "directive must be preceded by a document end (...)");
            switch (t.kind) {
                .document_start, .stream_end, .document_end => {
                    self.in_document = false;
                    // `%TAG` handles are document-scoped: a closing document
                    // drops them so the next document starts with only the
                    // defaults (or its own directives).
                    self.tag_handles.clearRetainingCapacity();
                    // Only an explicit `...` marker makes the close explicit;
                    // a new `---` or stream end do not. The
                    // `...` is the current document's terminator, so consume
                    // it here -- leaving it would frame a spurious empty
                    // document on the next step.
                    const explicit = t.kind == .document_end;
                    if (explicit) {
                        _ = self.take();
                        // A `...` line carries no node: content on the same
                        // line is invalid.
                        const nxt = self.peek();
                        if (nxt.span.line == t.span.line and isContentToken(nxt.kind))
                            return self.failAt(nxt.span, "content not allowed on a document end (...) line");
                    }
                    return Event{ .kind = .document_end, .explicit = explicit, .span = .{ .start = t.span.start, .end = t.span.start } };
                },
                else => {},
            }
        }

        switch (t.kind) {
            .stream_end => {
                _ = self.take();
                self.stream_ended = true;
                return Event{ .kind = .stream_end, .span = toSpan(t.span) };
            },
            .document_start => {
                // Explicit `---`. Open a document; its content is a block
                // node (possibly empty).
                _ = self.take();
                self.in_document = true;
                self.yaml_directive_seen = false;
                self.doc_start_line = t.span.line;
                try self.pushState(.block_node);
                return Event{ .kind = .document_start, .explicit = true, .span = toSpan(t.span) };
            },
            .document_end => {
                // A `...` with no open document (the open case is handled
                // above) is a redundant end marker: it frames no document.
                // Skip it; following content begins a fresh implicit document.
                // Content on the SAME line as `...` is invalid (a `...` line
                // carries no node, unlike `---`).
                _ = self.take();
                const nxt = self.peek();
                if (nxt.span.line == t.span.line and isContentToken(nxt.kind))
                    return self.failAt(nxt.span, "content not allowed on a document end (...) line");
                return null;
            },
            .directive => {
                _ = self.take();
                try self.handleDirective(t);
                // A directive applies only to a document begun with an
                // explicit `---`. The next token must be that marker (or a
                // further directive); a bare directive at end of stream, or
                // one followed by `...` or content, has no document to bind.
                const nxt = self.peek();
                switch (nxt.kind) {
                    .document_start, .directive => {},
                    else => return self.failAt(t.span, "directive not followed by a document start (---)"),
                }
                return null;
            },
            .invalid => return self.failInvalid(t),
            else => {
                // Any content token implies an implicit document start.
                self.in_document = true;
                self.yaml_directive_seen = false;
                self.doc_start_line = null;
                try self.pushState(.block_node);
                return Event{ .kind = .document_start, .span = toSpan(t.span) };
            },
        }
    }

    /// Interpret a `%`-directive line. `%YAML` is validated (a second
    /// `%YAML` before the same document is an error, a `#` glued to the
    /// version is an unseparated comment, extra fields after the version are
    /// an error); `%TAG` is parsed into the per-document handle table.
    /// Unknown `%`-directives are ignored.
    fn handleDirective(self: *Parser, t: Token) Error!void {
        const text = self.slice(t.span);
        if (std.mem.startsWith(u8, text, "%TAG") and
            (text.len == 4 or text[4] == ' ' or text[4] == '\t'))
            return self.handleTagDirective(t, text);
        if (!std.mem.startsWith(u8, text, "%YAML")) return;
        // The byte after `%YAML` must be white space or end; otherwise it is a
        // different directive name (`%YAMLL`), not the YAML directive.
        if (text.len > 5 and text[5] != ' ' and text[5] != '\t') return;

        if (self.yaml_directive_seen)
            return self.failAt(t.span, "repeated %YAML directive");
        self.yaml_directive_seen = true;

        // Strip a real (space-separated) comment before validating arity.
        // The scanner does not remove comments from the directive span, so
        // `%YAML 1.3 # comment` arrives with the full comment text included.
        var content = text[5..]; // skip `%YAML`
        if (std.mem.indexOf(u8, content, " #")) |comment_pos| {
            content = content[0..comment_pos];
        }

        // Require exactly one whitespace-delimited field (the version).
        var it = std.mem.tokenizeAny(u8, content, " \t");
        const version = it.next() orelse return self.failAt(t.span, "missing %YAML version");
        // A `#` inside the version token means the `#` was not space-separated
        // (e.g. `%YAML 1.1#...`): reject as an unseparated comment.
        if (std.mem.indexOfScalar(u8, version, '#') != null)
            return self.failAt(t.span, "comment must be preceded by white space");
        if (it.next() != null) return self.failAt(t.span, "extra content after %YAML version");
    }

    /// Parse `%TAG !handle! prefix` into the per-document handle table. The
    /// handle is `!`, `!!`, or `!name!` (delimited by `!`); the prefix is a
    /// tag prefix (verbatim or a local `!...`). A malformed directive (no
    /// handle, no prefix, a handle missing its closing `!`) is rejected; a
    /// handle redefined within the same document is rejected.
    fn handleTagDirective(self: *Parser, t: Token, text: []const u8) Error!void {
        // Split into whitespace-delimited fields after `%TAG`.
        var it = std.mem.tokenizeAny(u8, text[4..], " \t");
        const handle = it.next() orelse return self.failAt(t.span, "malformed %TAG directive: missing handle");
        const prefix = it.next() orelse return self.failAt(t.span, "malformed %TAG directive: missing prefix");
        if (it.next() != null) return self.failAt(t.span, "malformed %TAG directive: extra content");

        // A handle is `!`, `!!`, or `!name!`: starts and ends with `!`, with
        // word characters between (the `!name!` form). `!` and `!!` are the
        // primary/secondary handles.
        if (!validTagHandle(handle)) return self.failAt(t.span, "malformed %TAG directive: bad handle");

        const gop = try self.tag_handles.getOrPut(self.allocator, handle);
        if (gop.found_existing) return self.failAt(t.span, "repeated %TAG handle in one document");
        gop.value_ptr.* = prefix;
    }

    /// A well-formed `%TAG` handle: `!`, `!!`, or `!name!` where `name` is a
    /// run of word characters (`[0-9A-Za-z-]`, the YAML handle character set).
    fn validTagHandle(h: []const u8) bool {
        if (h.len == 0 or h[0] != '!') return false;
        if (h.len == 1) return true; // `!`
        if (h[h.len - 1] != '!') return false; // must close with `!`
        for (h[1 .. h.len - 1]) |c| {
            const ok = (c >= '0' and c <= '9') or (c >= 'A' and c <= 'Z') or
                (c >= 'a' and c <= 'z') or c == '-';
            if (!ok) return false;
        }
        return true;
    }

    /// Resolve a raw tag slice (the scanner's text, leading `!` included) to
    /// the fully-qualified tag text the suite renders inside `<...>`, using
    /// the per-document `%TAG` handle table plus the spec defaults:
    ///
    /// - `!`                 -> `!`              (the non-specific tag)
    /// - `!<verbatim-uri>`   -> `verbatim-uri`   (used as-is, no decode)
    /// - `!h!suffix`         -> prefix(h) ++ decode(suffix)
    /// - `!!suffix`          -> default `tag:yaml.org,2002:` ++ decode(suffix)
    ///                          (overridable by a `%TAG !! prefix`)
    /// - `!suffix`           -> default `!` ++ decode(suffix) -> `!suffix`
    ///                          (overridable by a `%TAG ! prefix`)
    ///
    /// A NAMED handle (`!h!suffix`) with no matching `%TAG` directive is an
    /// undefined-handle error. The suffix is percent-decoded; the verbatim
    /// form is not. A resolved tag that prepends a prefix is arena-allocated;
    /// a verbatim or already-complete tag is returned as a source slice.
    fn resolveTag(self: *Parser, raw: []const u8, span: Span) Error![]const u8 {
        if (std.mem.eql(u8, raw, "!")) return "!";
        if (std.mem.startsWith(u8, raw, "!<") and std.mem.endsWith(u8, raw, ">"))
            return raw[2 .. raw.len - 1];

        // Find the handle/suffix split. A `!name!suffix` has a second `!`
        // after the first; `!!suffix` is the secondary handle; `!suffix` (no
        // second `!`) is the primary handle.
        var handle: []const u8 = undefined;
        var suffix: []const u8 = undefined;
        if (raw.len >= 2 and raw[1] == '!') {
            handle = raw[0..2]; // `!!`
            suffix = raw[2..];
        } else if (std.mem.indexOfScalarPos(u8, raw, 1, '!')) |j| {
            handle = raw[0 .. j + 1]; // `!name!`
            suffix = raw[j + 1 ..];
        } else {
            handle = "!"; // primary
            suffix = raw[1..];
        }

        const decoded = try percentDecode(self.allocator, suffix);
        if (self.tag_handles.get(handle)) |prefix|
            return std.mem.concat(self.allocator, u8, &.{ prefix, decoded });

        // No directive for this handle: defaults apply. A named handle has no
        // default and is an error.
        if (std.mem.eql(u8, handle, "!"))
            return std.mem.concat(self.allocator, u8, &.{ "!", decoded });
        if (std.mem.eql(u8, handle, "!!"))
            return std.mem.concat(self.allocator, u8, &.{ "tag:yaml.org,2002:", decoded });
        return self.failSpan(span, "tag handle not declared by a %TAG directive");
    }

    /// Drive one transition for the current top-of-stack state, returning an
    /// event when one is produced (else null to loop again).
    fn stepState(self: *Parser, state: State) Error!?Event {
        return switch (state) {
            .block_node => self.stepBlockNode(),
            .block_sequence_entry => self.stepBlockSequenceEntry(),
            .block_mapping_key => self.stepBlockMappingKey(),
            .block_mapping_value => self.stepBlockMappingValue(),
            .flow_sequence_entry => self.stepFlowSequenceEntry(),
            .flow_seq_pair_key => self.stepFlowSeqPairKey(),
            .flow_seq_pair_value => self.stepFlowSeqPairValue(),
            .flow_seq_pair_end => self.stepFlowSeqPairEnd(),
            .flow_mapping_key => self.stepFlowMappingKey(),
            .flow_mapping_value => self.stepFlowMappingValue(),
            .flow_mapping_bare_value => self.stepFlowMappingBareValue(),
        };
    }

    /// Expect a node: optional properties, then scalar / alias / collection
    /// start / empty. `block_node` is the continuation set by document
    /// start, a sequence entry, or a mapping value.
    fn stepBlockNode(self: *Parser) Error!?Event {
        const t = self.peek();
        switch (t.kind) {
            .anchor, .tag => {
                _ = self.take();
                self.bufferProperty(t);
                return null;
            },
            .scalar => {
                _ = self.take();
                self.popState();
                return self.nodeEvent(t);
            },
            .alias => {
                // An alias is a reference; it cannot carry node properties
                // (`&b *alias` / `!!str *alias` are invalid).
                if (self.pending_anchor != null or self.pending_tag != null)
                    return self.failAt(t.span, "alias node cannot have an anchor or tag");
                _ = self.take();
                self.popState();
                return self.nodeEvent(t);
            },
            .block_sequence_start => {
                if (self.doc_start_line) |dl| {
                    if (t.span.line == dl)
                        return self.failAt(t.span, "block collection cannot begin on the document-start (---) line");
                }
                _ = self.take();
                self.setTop(.block_sequence_entry);
                var ev: Event = .{ .kind = .sequence_start, .span = toSpan(t.span), .flow = false };
                self.applyProperties(&ev);
                return ev;
            },
            .block_mapping_start => {
                if (self.doc_start_line) |dl| {
                    if (t.span.line == dl)
                        return self.failAt(t.span, "block collection cannot begin on the document-start (---) line");
                }
                _ = self.take();
                self.setTop(.block_mapping_key);
                var ev: Event = .{ .kind = .mapping_start, .span = toSpan(t.span), .flow = false };
                // Distribute buffered node properties between the mapping and
                // its first key. A property on the SAME line as the key (the
                // mapping start sits at the key) decorates the KEY (`!!str a:
                // b`); a property on an EARLIER line decorates the MAPPING
                // (`&a\nkey: v`). When both exist (`&a4 !!map\n&a5 !!str k: v`)
                // the carried earlier-line set goes to the mapping and the
                // same-line pending set stays for the key. When the pending
                // set is itself on an earlier line (`key: &a\n !!map\n a: b`,
                // properties split across lines but all before the key), it too
                // decorates the mapping.
                const key_line = t.span.line;
                const pending_on_key_line = if (self.pending_span) |ps| ps.line == key_line else false;
                if (pending_on_key_line) {
                    // carried (if any) -> mapping; pending stays for the key.
                    self.applyCarried(&ev);
                } else {
                    // All buffered properties precede the key -> the mapping.
                    self.applyCarried(&ev);
                    if (ev.anchor == null) ev.anchor = self.pending_anchor;
                    if (ev.tag == null) ev.tag = self.pending_tag;
                    self.pending_anchor = null;
                    self.pending_tag = null;
                    self.pending_span = null;
                }
                return ev;
            },
            .flow_sequence_start => {
                _ = self.take();
                self.setTop(.flow_sequence_entry);
                try self.pushFlow();
                var ev: Event = .{ .kind = .sequence_start, .span = toSpan(t.span), .flow = true };
                self.applyProperties(&ev);
                return ev;
            },
            .flow_mapping_start => {
                _ = self.take();
                self.setTop(.flow_mapping_key);
                try self.pushFlow();
                var ev: Event = .{ .kind = .mapping_start, .span = toSpan(t.span), .flow = true };
                self.applyProperties(&ev);
                return ev;
            },
            .key => {
                // A `key` while expecting a node is ambiguous:
                //  - At the document root (this block_node is the only state
                //    on the stack), the scanner did not wrap an explicit
                //    `? key` in a block_mapping_start, so open the mapping.
                //  - Nested as a mapping value (a block_mapping_key sits
                //    below), this `key` belongs to the NEXT entry, so the
                //    current value node is empty.
                if (self.states.items.len == 1) {
                    self.setTop(.block_mapping_key);
                    var ev: Event = .{ .kind = .mapping_start, .span = toSpan(t.span), .flow = false };
                    self.applyProperties(&ev);
                    return ev;
                }
                self.popState();
                const raw = self.pending_span orelse RawSpan{ .start = t.span.start, .end = t.span.start, .line = t.span.line, .col = t.span.col };
                return self.emptyScalar(raw);
            },
            .invalid => return self.failInvalid(t),
            else => {
                // No node present (e.g. value indicator with nothing after,
                // block_end, document boundary): an empty scalar.
                self.popState();
                const raw = self.pending_span orelse RawSpan{ .start = t.span.start, .end = t.span.start, .line = t.span.line, .col = t.span.col };
                return self.emptyScalar(raw);
            },
        }
    }

    fn stepBlockSequenceEntry(self: *Parser) Error!?Event {
        const t = self.peek();
        switch (t.kind) {
            .block_entry => {
                _ = self.take();
                // The entry's node follows; may be empty (next token is
                // another block_entry or block_end).
                try self.pushState(.block_node);
                return null;
            },
            .block_end => {
                _ = self.take();
                self.popState();
                return Event{ .kind = .sequence_end, .span = toSpan(t.span) };
            },
            .invalid => return self.failInvalid(t),
            else => return self.fail("expected block sequence entry"),
        }
    }

    fn stepBlockMappingKey(self: *Parser) Error!?Event {
        const t = self.peek();
        switch (t.kind) {
            .anchor, .tag => {
                // Node properties preceding the next key (`!!str a: b`) are
                // buffered onto the key node, which block_node emits.
                _ = self.take();
                self.bufferProperty(t);
                return null;
            },
            .key => {
                _ = self.take();
                self.setTop(.block_mapping_value);
                try self.pushState(.block_node);
                return null;
            },
            .block_end => {
                _ = self.take();
                self.popState();
                return Event{ .kind = .mapping_end, .span = toSpan(t.span) };
            },
            .value => {
                // A `value` with no preceding `key` (empty key). Emit the
                // empty key node, then proceed to the value.
                self.setTop(.block_mapping_value);
                return self.emptyScalar(.{ .start = t.span.start, .end = t.span.start, .line = t.span.line, .col = t.span.col });
            },
            .invalid => return self.failInvalid(t),
            else => return self.fail("did not find expected key"),
        }
    }

    fn stepBlockMappingValue(self: *Parser) Error!?Event {
        const t = self.peek();
        switch (t.kind) {
            .value => {
                _ = self.take();
                self.setTop(.block_mapping_key);
                try self.pushState(.block_node);
                return null;
            },
            // A key with no `value` indicator: the value is empty. Emit an
            // empty scalar and cycle back to expecting a key.
            .key, .block_end => {
                self.setTop(.block_mapping_key);
                return self.emptyScalar(.{ .start = t.span.start, .end = t.span.start, .line = t.span.line, .col = t.span.col });
            },
            .invalid => return self.failInvalid(t),
            else => return self.fail("mapping values are not allowed here"),
        }
    }

    fn stepFlowSequenceEntry(self: *Parser) Error!?Event {
        const t = self.peek();
        switch (t.kind) {
            .anchor, .tag => {
                // Properties preceding a flow-sequence element are buffered
                // here so the NEXT token decides the element: a single-pair
                // key (`[&a a: b]`, properties decorate the pair's key) or a
                // plain node (`[&a x]`, properties decorate the scalar).
                // Buffering at this level keeps a following `key` indicator
                // visible to the single-pair path below.
                _ = self.take();
                self.bufferProperty(t);
                return null;
            },
            .flow_sequence_end => {
                // A lone property before `]` (`[&x]`) decorates an empty
                // scalar element; emit it, leaving the `]` for the next step.
                if (self.hasBufferedProperty()) {
                    self.setFlowPos(.after_elem);
                    return self.emptyPropertyScalar(t.span);
                }
                // A single trailing `,` before `]` (`[a, ]`) is legal YAML,
                // as is an empty `[]`; only doubled/leading commas (caught on
                // the `flow_entry` below) are rejected.
                _ = self.take();
                self.popFlow();
                self.popState();
                return Event{ .kind = .sequence_end, .span = toSpan(t.span) };
            },
            .flow_entry => {
                // A lone property before `,` (`[&x, b]`) decorates an empty
                // scalar element; emit it, leaving the `,` for the next step.
                if (self.hasBufferedProperty()) {
                    self.setFlowPos(.after_elem);
                    return self.emptyPropertyScalar(t.span);
                }
                // A `,` with no element before it: a leading comma (`[ ,`)
                // or a doubled comma (`[a, ,`). Both yield an empty entry,
                // which is invalid. (A single trailing `,` before `]` is
                // legal and handled by `flow_sequence_end` above.)
                if (self.flowPos() != .after_elem)
                    return self.failAt(t.span, "empty entry in flow sequence");
                _ = self.take();
                self.setFlowPos(.after_comma);
                return null;
            },
            .key, .value => {
                // A single-pair mapping as a flow-sequence element
                // (`[a: 1]`, or `[: x]`/`[:x]` with an empty key): the
                // scanner does not wrap it in a flow_mapping_start.
                // Synthesize the mapping; the pair-key step supplies an
                // empty key when the next token is the `value` indicator.
                self.setFlowPos(.after_elem);
                try self.pushState(.flow_seq_pair_key);
                return Event{ .kind = .mapping_start, .span = toSpan(t.span), .flow = true };
            },
            .invalid => return self.failInvalid(t),
            // A document/stream boundary, the wrong flow closer
            // (`flow_mapping_end`, a `}` closing a `[`), or a block-structure
            // token (a `block_entry`/`block_*_start`/`block_end` the scanner
            // emits once the unterminated flow lets block context resume)
            // means the `]` is missing or mismatched. Fail rather than spin
            // synthesizing empty entries against a token the flow grammar can
            // never consume.
            .stream_end,
            .document_start,
            .document_end,
            .directive,
            .block_end,
            .block_entry,
            .block_sequence_start,
            .block_mapping_start,
            .flow_mapping_end,
            => return self.fail("unterminated flow sequence"),
            else => {
                // An entry node (scalar/alias/properties/nested collection).
                self.setFlowPos(.after_elem);
                try self.pushState(.block_node);
                return null;
            },
        }
    }

    /// The key half of a single-pair mapping inside a flow sequence.
    fn stepFlowSeqPairKey(self: *Parser) Error!?Event {
        const t = self.peek();
        switch (t.kind) {
            .key => {
                _ = self.take();
                self.setTop(.flow_seq_pair_value);
                try self.pushState(.block_node);
                return null;
            },
            .value => {
                // `[: x]` / `[:x]`: the `value` indicator with no preceding
                // key. Supply an empty key now; the value step consumes the
                // `:` next. The `value` token is intentionally left for
                // flow_seq_pair_value to take.
                self.setTop(.flow_seq_pair_value);
                return self.emptyScalar(.{ .start = t.span.start, .end = t.span.start, .line = t.span.line, .col = t.span.col });
            },
            .invalid => return self.failInvalid(t),
            else => return self.fail("did not find expected key"),
        }
    }

    fn stepFlowSeqPairValue(self: *Parser) Error!?Event {
        const t = self.peek();
        switch (t.kind) {
            .value => {
                _ = self.take();
                self.setTop(.flow_seq_pair_end);
                try self.pushState(.block_node);
                return null;
            },
            else => {
                self.setTop(.flow_seq_pair_end);
                return self.emptyScalar(.{ .start = t.span.start, .end = t.span.start, .line = t.span.line, .col = t.span.col });
            },
        }
    }

    /// Close the synthesized single-pair mapping and return to the flow
    /// sequence.
    fn stepFlowSeqPairEnd(self: *Parser) Error!?Event {
        self.popState();
        const t = self.peek();
        return Event{ .kind = .mapping_end, .span = .{ .start = t.span.start, .end = t.span.start } };
    }

    fn stepFlowMappingKey(self: *Parser) Error!?Event {
        const t = self.peek();
        switch (t.kind) {
            .anchor, .tag => {
                // Properties preceding a flow-mapping entry are buffered so a
                // following `key` indicator (`{&a a: b}`) stays visible and
                // the property decorates the key node, not a synthesized empty
                // one. A bare entry (`{&a a}`) routes through block_node below.
                _ = self.take();
                self.bufferProperty(t);
                return null;
            },
            .flow_mapping_end => {
                // A lone property before `}` (`{&x }`) decorates an empty
                // scalar KEY; emit it and route to the value step, which
                // supplies the empty value before the `}` closes the mapping.
                if (self.hasBufferedProperty()) {
                    self.setFlowPos(.after_elem);
                    self.setTop(.flow_mapping_value);
                    return self.emptyPropertyScalar(t.span);
                }
                // A single trailing `,` before `}` (`{a: 1, }`) is legal, as
                // is an empty `{}`; only doubled/leading commas (caught on the
                // `flow_entry` below) are rejected.
                _ = self.take();
                self.popFlow();
                self.popState();
                return Event{ .kind = .mapping_end, .span = toSpan(t.span) };
            },
            .flow_entry => {
                // A lone property before `,` (`{&x, b}`) decorates an empty
                // scalar KEY; emit it and route to the value step.
                if (self.hasBufferedProperty()) {
                    self.setFlowPos(.after_elem);
                    self.setTop(.flow_mapping_value);
                    return self.emptyPropertyScalar(t.span);
                }
                // A `,` with no entry before it: a leading comma (`{,`) or a
                // doubled comma (`{a, ,`). Both yield an empty entry. (A
                // single trailing `,` before `}` is legal, handled above.)
                if (self.flowPos() != .after_elem)
                    return self.failAt(t.span, "empty entry in flow mapping");
                _ = self.take();
                self.setFlowPos(.after_comma);
                return null;
            },
            .key => {
                self.setFlowPos(.after_elem);
                _ = self.take();
                self.setTop(.flow_mapping_value);
                try self.pushState(.block_node);
                return null;
            },
            .value => {
                // `{: v}`: empty key.
                self.setFlowPos(.after_elem);
                self.setTop(.flow_mapping_value);
                return self.emptyScalar(.{ .start = t.span.start, .end = t.span.start, .line = t.span.line, .col = t.span.col });
            },
            .invalid => return self.failInvalid(t),
            // A document/stream boundary, the wrong flow closer
            // (`flow_sequence_end`, a `]` closing a `{`), or a block-structure
            // token (a `block_entry`/`block_*_start`/`block_end` the scanner
            // emits once the unterminated flow lets block context resume)
            // means the `}` is missing or mismatched. Fail rather than spin
            // synthesizing empty keys against a token the flow grammar can
            // never consume.
            .stream_end,
            .document_start,
            .document_end,
            .directive,
            .block_end,
            .block_entry,
            .block_sequence_start,
            .block_mapping_start,
            .flow_sequence_end,
            => return self.fail("unterminated flow mapping"),
            else => {
                // A bare entry node with no key indicator (`{a, b}`): the
                // node is the key, value is empty. Emit the key node via
                // block_node, then an empty value.
                self.setFlowPos(.after_elem);
                self.setTop(.flow_mapping_bare_value);
                try self.pushState(.block_node);
                return null;
            },
        }
    }

    /// After a bare flow-mapping entry node, decide its value. A `:` value
    /// indicator may follow the key on a LATER line (`{"foo"\n: bar}`) or
    /// adjacent to a quoted key (`{"foo":bar}`); the scanner does not promote
    /// such a key, so the `:` arrives here. Consume it and read the value.
    /// With no `:`, the entry is a bare key with an empty value (`{a, b}`).
    fn stepFlowMappingBareValue(self: *Parser) Error!?Event {
        const t = self.peek();
        if (t.kind == .value) {
            _ = self.take();
            self.setTop(.flow_mapping_key);
            try self.pushState(.block_node);
            return null;
        }
        self.setTop(.flow_mapping_key);
        return self.emptyScalar(.{ .start = t.span.start, .end = t.span.start, .line = t.span.line, .col = t.span.col });
    }

    fn stepFlowMappingValue(self: *Parser) Error!?Event {
        const t = self.peek();
        switch (t.kind) {
            .value => {
                _ = self.take();
                self.setTop(.flow_mapping_key);
                try self.pushState(.block_node);
                return null;
            },
            .flow_entry, .flow_mapping_end => {
                // Key with no value: empty value.
                self.setTop(.flow_mapping_key);
                return self.emptyScalar(.{ .start = t.span.start, .end = t.span.start, .line = t.span.line, .col = t.span.col });
            },
            .invalid => return self.failInvalid(t),
            else => return self.fail("did not find expected ',' or '}'"),
        }
    }
};

/// Percent-decode a tag suffix: each `%XX` (two hex digits) becomes the byte
/// it names. A `%` not followed by two hex digits is kept literal (lenient,
/// matching reference parsers). Returns the input slice unchanged when it
/// holds no `%`, avoiding allocation in the common case.
fn percentDecode(a: std.mem.Allocator, s: []const u8) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, s.len);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 3 <= s.len) {
            const hi = hexDigit(s[i + 1]);
            const lo = hexDigit(s[i + 2]);
            if (hi != null and lo != null) {
                try out.append(a, hi.? << 4 | lo.?);
                i += 3;
                continue;
            }
        }
        try out.append(a, s[i]);
        i += 1;
    }
    return out.items;
}

/// Value of a single hex digit, or null when `c` is not a hex digit.
fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

const testing = std.testing;

/// Drive a parser to stream end or its first error, returning whether the
/// whole stream parsed without error.
fn parses(a: std.mem.Allocator, src: []const u8) bool {
    var p: Parser = .init(a, src);
    while (p.next() catch return false) |_| {}
    return true;
}

/// Assert that `src` is REJECTED within a bounded number of event pulls.
/// Returns `error.UnexpectedlyAccepted` if the parser accepts it, and
/// `error.ParserRunaway` if it spins past `max_events` (a grammar looping
/// against a token it never consumes). The runaway error is what makes a
/// resource-consumption regression fail the test instead of hanging the
/// runner: a plain "is it rejected" check passes whether the parser errors
/// quickly OR spins to the cap, so the two outcomes must be distinct.
fn expectRejectedBounded(a: std.mem.Allocator, src: []const u8, max_events: usize) !void {
    var p: Parser = .init(a, src);
    var n: usize = 0;
    while (true) : (n += 1) {
        if (n > max_events) return error.ParserRunaway;
        const ev = p.next() catch return; // rejected within the cap: pass
        if (ev == null) return error.UnexpectedlyAccepted;
    }
}

test "mismatched flow closer is rejected without spinning" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // A `}` closing a `[` (or vice versa) must be rejected, not spin
    // synthesizing empty entries against a token the grammar cannot consume.
    try expectRejectedBounded(a, "{a]\n", 64);
    try expectRejectedBounded(a, "[a}\n", 64);
    try expectRejectedBounded(a, "x: {a: 1]\n", 64);
    try expectRejectedBounded(a, "x: [a: 1}\n", 64);
    try expectRejectedBounded(a, "{a: 1, 2]\n", 64);
    try expectRejectedBounded(a, "flow: {a: 1, b: 2, 3], c: {d: 4}}\n", 64);
}

test "unterminated flow leaking into block context is rejected without spinning" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // An unterminated flow collection lets the scanner resume block context
    // (a `block_entry`/`block_*_start`/`block_end`), which the flow grammar
    // can never consume. Reject rather than spin synthesizing empty nodes
    // against it.
    try expectRejectedBounded(a, "a:\n  - [b: [2]\n  -", 64);
    try expectRejectedBounded(a, "matrix:\n  - [1,low: {a: 1, b: [2, 3]}\n  -", 64);
    try expectRejectedBounded(a, "a:\n  - {b: 1\n  - c", 64);
    try expectRejectedBounded(a, "a:\n  - [1\nb: 2", 64);
}

test "leading flow comma is rejected" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    try std.testing.expect(!parses(ar.allocator(), "[ , a]\n"));
    try std.testing.expect(!parses(ar.allocator(), "{ , a: 1}\n"));
}

test "doubled flow comma is rejected" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    try std.testing.expect(!parses(ar.allocator(), "[ a, , b]\n"));
    try std.testing.expect(!parses(ar.allocator(), "[ a, b, c, , ]\n"));
    try std.testing.expect(!parses(ar.allocator(), "{ a: 1, , b: 2}\n"));
}

test "single trailing flow comma is accepted" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    try std.testing.expect(parses(ar.allocator(), "[ one, two, ]\n"));
    try std.testing.expect(parses(ar.allocator(), "{ a: 1, }\n"));
    try std.testing.expect(parses(ar.allocator(), "[]\n"));
    try std.testing.expect(parses(ar.allocator(), "{}\n"));
}

test "multi-line scalar used as a block implicit key is rejected" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // A quoted key spanning a line break cannot be an implicit block key.
    try std.testing.expect(!parses(a, "\"c\n d\": 1\n"));
    try std.testing.expect(!parses(a, "'c\n d': 1\n"));
    // A single-line quoted key with the same content is fine.
    try std.testing.expect(parses(a, "\"c d\": 1\n"));
    // A quoted key with surrounding spaces before its `:` still parses.
    try std.testing.expect(parses(a, "\"key\" : 1\n"));
}

test "document marker inside a quoted scalar is rejected" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // A `---`/`...` at column 0 ends the document, so a quoted scalar may not
    // span across one.
    try std.testing.expect(!parses(a, "---\n\"\n---\n\"\n"));
    try std.testing.expect(!parses(a, "---\n'\n...\n'\n"));
    try std.testing.expect(!parses(a, "--- \"a\n... x\nb\"\n"));
    // A quoted scalar whose continuation merely starts with dashes (not a full
    // marker at column 0) is fine.
    try std.testing.expect(parses(a, "\"a\n-- b\"\n"));
}

test "inline nested block mapping after a value is rejected" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // A value turned into a nested implicit key on the same line is invalid.
    try std.testing.expect(!parses(a, "a: b: c: d\n"));
    try std.testing.expect(!parses(a, "---\na: 'b': c\n"));
    // The valid counterparts: a nested mapping on its OWN line, an explicit-key
    // value that is an inline mapping (`: moon: white`), a sequence entry with
    // an inline mapping, and a quoted/tagged key are all accepted.
    try std.testing.expect(parses(a, "a:\n  b: c\n"));
    try std.testing.expect(parses(a, "- ? earth: blue\n  : moon: white\n"));
    try std.testing.expect(parses(a, "- a: b\n"));
    try std.testing.expect(parses(a, "!!str a: b\n"));
    try std.testing.expect(parses(a, "\"top\" : v\n"));
}

test "explicit empty-key entry with inline mapping value parses" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // `: moon: white` is a block mapping with an empty (null) implicit key
    // whose value is the inline mapping {moon: white}.  The nested-mapping
    // rejection rule must not fire here: the synthesized empty key does not
    // constitute an "implicit key whose value indicator appeared on this line".
    try std.testing.expect(parses(a, ": moon: white\n"));
    try std.testing.expect(parses(a, "\n: moon: white\n"));
    try std.testing.expect(parses(a, "---\n: moon: white\n"));
    // The rejection rule must still fire for real inline-nested mappings.
    try std.testing.expect(!parses(a, "a: b: c\n"));
    try std.testing.expect(!parses(a, "a: b: c: d\n"));
}

test "bare block indicator before a flow indicator is rejected" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // `-`/`?` glued to a flow indicator cannot begin a plain scalar in flow.
    try std.testing.expect(!parses(a, "[-]\n"));
    try std.testing.expect(!parses(a, "---\n- [-, -]\n"));
    // A `-` that begins a real plain scalar in flow is fine (`-1`, `-x`).
    try std.testing.expect(parses(a, "[-1, -2]\n"));
    try std.testing.expect(parses(a, "[-x]\n"));
}

test "directive after document content is rejected" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // A directive may only begin the stream or follow an explicit `...`.
    try std.testing.expect(!parses(a, "---\nscalar1 # comment\n%YAML 1.2\n---\nscalar2\n"));
    try std.testing.expect(!parses(a, "!foo \"bar\"\n%TAG ! tag:example.com,2000:app/\n---\n!foo \"bar\"\n"));
    // After an explicit `...` the directive binds the next document cleanly.
    try std.testing.expect(parses(a, "scalar1\n...\n%YAML 1.2\n---\nscalar2\n"));
}

test "rejection rules do not loop on empty-key edges" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // A bare `:` after a value indicator (`a: : b`) yields an empty key that
    // never advances the scan; the inline-nested-mapping rule must terminate
    // rather than spin filling the token queue. A tight event cap turns a
    // regressed loop into a fast FAILURE instead of a hang.
    const cap = 64;
    try drainBounded(a, "a: : b\n", cap);
    try drainBounded(a, "a: b: c\n", cap);
    try drainBounded(a, "[-]\n", cap);
    try drainBounded(a, "---\n\"\n---\n", cap);
}

test "comment glued to preceding content is rejected" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try std.testing.expect(!parses(a, "key: \"value\"# invalid comment\n"));
    try std.testing.expect(!parses(a, "[ a, b,#invalid\n]\n"));
    try std.testing.expect(!parses(a, "[ a, b ]#invalid\n"));
}

test "comment separated by white space is accepted" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try std.testing.expect(parses(a, "key: value # comment\n"));
    try std.testing.expect(parses(a, "[ a, b ] # comment\n"));
    try std.testing.expect(parses(a, "# leading comment\nkey: value\n"));
    try std.testing.expect(parses(a, "a: 1\n# full line comment\nb: 2\n"));
}

test "directive not bound to a document is rejected" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // A %YAML directive with no following `---`, or followed by `...`.
    try std.testing.expect(!parses(a, "%YAML 1.2\n"));
    try std.testing.expect(!parses(a, "%YAML 1.2\n...\n"));
    // A repeated %YAML directive before the same document.
    try std.testing.expect(!parses(a, "%YAML 1.2\n%YAML 1.2\n---\n"));
    // A comment glued to the version is unseparated.
    try std.testing.expect(!parses(a, "%YAML 1.1#...\n---\n"));
}

test "well-formed directives are accepted" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try std.testing.expect(parses(a, "%YAML 1.2\n---\ndoc\n"));
    try std.testing.expect(parses(a, "%YAML 1.1  # comment\n---\n"));
    try std.testing.expect(parses(a, "%TAG ! tag:example.com,2000:app/\n---\nx\n"));
    // Unknown directive names (not `%YAML` or `%TAG`) are ignored entirely.
    try std.testing.expect(parses(a, "%YAMLL 1.1\n---\n"));
}

test "extra fields in %YAML directive are rejected" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // Extra parameter after the version field.
    try std.testing.expect(!parses(a, "%YAML 1.2 foo\n---\n"));
    // Two version fields (both rejected).
    try std.testing.expect(!parses(a, "%YAML 1.1 1.2\n---\n"));
}

fn events(a: std.mem.Allocator, src: []const u8, out: []EventKind) !usize {
    var p: Parser = .init(a, src);
    var i: usize = 0;
    while (try p.next()) |e| : (i += 1) out[i] = e.kind;
    return i;
}

/// Collect the `=VAL` scalar values (cooked) of a parse, in order.
fn scalarValues(a: std.mem.Allocator, src: []const u8, out: [][]const u8) !usize {
    var p: Parser = .init(a, src);
    var i: usize = 0;
    while (try p.next()) |e| {
        if (e.kind != .scalar) continue;
        out[i] = try @import("composer.zig").cookScalarText(a, src, e);
        i += 1;
    }
    return i;
}

test "flow mapping value colon may be adjacent to a JSON key" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var buf: [16][]const u8 = undefined;
    // `{"a":b}`: a quoted key permits the value `:` with no separator.
    const n = try scalarValues(a, "{\"a\":b}\n", &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("a", buf[0]);
    try std.testing.expectEqualStrings("b", buf[1]);
    // Across a line break the same adjacency holds.
    const m = try scalarValues(a, "{\"a\"\n:b}\n", &buf);
    try std.testing.expectEqual(@as(usize, 2), m);
    try std.testing.expectEqualStrings("a", buf[0]);
    try std.testing.expectEqualStrings("b", buf[1]);
}

test "flow value colon glued to content after a plain node is a scalar" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var buf: [16][]const u8 = undefined;
    // `{x: :x}`: the first `:` (separated) is the value indicator; the value
    // `:x` is a plain scalar (the `:` glued to `x` is not an indicator).
    const n = try scalarValues(a, "{x: :x}\n", &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("x", buf[0]);
    try std.testing.expectEqualStrings(":x", buf[1]);
}

test "node property on a flow entry decorates the key, not an empty node" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // `{&a k: v}` / `[&a k: v]`: the anchor decorates the single-pair key
    // node `k`, producing exactly one entry (no spurious empty scalar).
    var buf: [24]EventKind = undefined;
    const want = [_]EventKind{
        .stream_start,  .document_start, .sequence_start,
        .mapping_start, .scalar,         .scalar,
        .mapping_end,   .sequence_end,   .document_end,
        .stream_end,
    };
    const n = try events(a, "[&a k: v]\n", &buf);
    try std.testing.expectEqualSlices(EventKind, &want, buf[0..n]);

    // And the anchor lands on the key event.
    var p: Parser = .init(a, "{&a k: v}\n");
    var key_anchor: ?[]const u8 = null;
    var saw = false;
    while (try p.next()) |e| if (e.kind == .scalar and !saw) {
        key_anchor = e.anchor;
        saw = true;
    };
    try std.testing.expectEqualStrings("a", key_anchor.?);
}

test "flow mapping bare quoted key gets adjacent value, not empty pair" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var buf: [24]EventKind = undefined;
    // `{"foo"\n: "bar"}`: key and value on separate lines yield exactly one
    // entry, not a bare key plus a spurious empty-key entry.
    const n = try events(a, "{\"foo\"\n: \"bar\"}\n", &buf);
    try std.testing.expectEqualSlices(EventKind, &.{
        .stream_start, .document_start, .mapping_start,
        .scalar,       .scalar,         .mapping_end,
        .document_end, .stream_end,
    }, buf[0..n]);
}

test "event stream for a block mapping" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    var buf: [16]EventKind = undefined;
    const n = try events(ar.allocator(), "a: 1\nb: 2\n", &buf);
    try std.testing.expectEqualSlices(EventKind, &.{
        .stream_start, .document_start, .mapping_start,
        .scalar,       .scalar,         .scalar,
        .scalar,       .mapping_end,    .document_end,
        .stream_end,
    }, buf[0..n]);
}

test "anchors and aliases surface on events" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    var p: Parser = .init(ar.allocator(), "- &x 1\n- *x\n");
    var saw_anchor = false;
    var saw_alias = false;
    while (try p.next()) |e| {
        if (e.anchor != null) saw_anchor = true;
        if (e.kind == .alias) saw_alias = true;
    }
    try std.testing.expect(saw_anchor and saw_alias);
}

test "flow nested in block" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    var buf: [24]EventKind = undefined;
    const n = try events(ar.allocator(), "k: [1, 2]\n", &buf);
    try std.testing.expectEqualSlices(EventKind, &.{
        .stream_start, .document_start, .mapping_start,
        .scalar,       .sequence_start, .scalar,
        .scalar,       .sequence_end,   .mapping_end,
        .document_end, .stream_end,
    }, buf[0..n]);
}

test "empty document yields empty scalar" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    var buf: [8]EventKind = undefined;
    const n = try events(ar.allocator(), "---\n", &buf);
    try std.testing.expectEqual(EventKind.scalar, buf[2]);
    _ = n;
}

test "multi-document stream" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    var buf: [24]EventKind = undefined;
    const n = try events(ar.allocator(), "a: 1\n---\nb: 2\n", &buf);
    var docs: usize = 0;
    for (buf[0..n]) |k| if (k == .document_start) {
        docs += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), docs);
}

test "scalar event carries raw value and style" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    var p: Parser = .init(ar.allocator(), "s: \"hi\"\n");
    var dq: ?[]const u8 = null;
    while (try p.next()) |e| if (e.kind == .scalar and e.scalar_style == .double) {
        dq = e.value;
    };
    try std.testing.expectEqualStrings("hi", dq.?);
}

test "empty mapping values resolve to empty scalars" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    var buf: [24]EventKind = undefined;
    const n = try events(ar.allocator(), "a:\nb:\n", &buf);
    try std.testing.expectEqualSlices(EventKind, &.{
        .stream_start, .document_start, .mapping_start,
        .scalar,       .scalar,         .scalar,
        .scalar,       .mapping_end,    .document_end,
        .stream_end,
    }, buf[0..n]);
}

test "block scalar threads its header through" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    var p: Parser = .init(ar.allocator(), "k: |-\n  body\n");
    var hdr: ?scanner.BlockHeader = null;
    var style: ?ScalarStyle = null;
    while (try p.next()) |e| if (e.kind == .scalar and e.block_header != null) {
        hdr = e.block_header;
        style = e.scalar_style;
    };
    try std.testing.expectEqual(ScalarStyle.literal, style.?);
    try std.testing.expectEqual(scanner.Chomp.strip, hdr.?.chomp);
}

test "tag attaches to the node it precedes, resolved to its full form" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    var p: Parser = .init(ar.allocator(), "!!str x\n");
    var tag: ?[]const u8 = null;
    while (try p.next()) |e| if (e.kind == .scalar and e.tag != null) {
        tag = e.tag;
    };
    // The event carries the fully-qualified tag (the default `!!` handle
    // expands to the YAML core prefix), not the raw `!!str` shorthand.
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str", tag.?);
}

/// First resolved node tag in `src`, or null if none.
fn firstTag(a: std.mem.Allocator, src: []const u8) !?[]const u8 {
    var p: Parser = .init(a, src);
    while (try p.next()) |e| {
        if ((e.kind == .scalar or e.kind == .sequence_start or e.kind == .mapping_start) and e.tag != null)
            return e.tag;
    }
    return null;
}

test "%TAG named-handle resolution with percent-decode" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // A named `!e!` handle resolves to its prefix; the suffix percent-decodes
    // (`tag%21` -> `tag!`).
    const t = try firstTag(a, "%TAG !e! tag:example.com,2000:app/\n---\n!e!tag%21 baz\n");
    try std.testing.expectEqualStrings("tag:example.com,2000:app/tag!", t.?);
}

test "%TAG overrides the default primary and secondary handles" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // `%TAG !` overrides the primary handle: `!foo` no longer stays local.
    try std.testing.expectEqualStrings(
        "tag:example.com,2000:app/foo",
        (try firstTag(a, "%TAG ! tag:example.com,2000:app/\n---\n!foo x\n")).?,
    );
    // `%TAG !!` overrides the secondary handle, so `!!int` is no longer the
    // core int tag.
    try std.testing.expectEqualStrings(
        "tag:example.com,2000:app/int",
        (try firstTag(a, "%TAG !! tag:example.com,2000:app/\n---\n!!int 1\n")).?,
    );
}

test "default handles and verbatim tags need no directive" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // Primary `!foo` stays a local tag; secondary `!!str` is the core tag;
    // the non-specific `!` is itself; a verbatim `!<uri>` is used as-is.
    try std.testing.expectEqualStrings("!foo", (try firstTag(a, "!foo x\n")).?);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str", (try firstTag(a, "!!str x\n")).?);
    try std.testing.expectEqualStrings("!", (try firstTag(a, "! x\n")).?);
    try std.testing.expectEqualStrings("tag:yaml.org,2002:str", (try firstTag(a, "!<tag:yaml.org,2002:str> x\n")).?);
}

test "%TAG handles are document-scoped" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // A handle declared for the first document does not carry into the second:
    // re-using it there references an undefined handle and is rejected.
    try std.testing.expect(!parses(a, "%TAG !e! tag:example.com,2000:app/\n--- !e!a\nx: 1\n--- !e!b\ny: 2\n"));
    // Declared in BOTH documents, both resolve cleanly.
    try std.testing.expect(parses(a, "%TAG !e! tag:x,2000:\n--- !e!a\nx: 1\n...\n%TAG !e! tag:x,2000:\n--- !e!b\ny: 2\n"));
}

test "malformed %TAG directives are rejected" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // Missing prefix, bad handle (no closing `!`), duplicate handle, and an
    // undeclared named handle are all errors.
    try std.testing.expect(!parses(a, "%TAG !e!\n---\nx\n"));
    try std.testing.expect(!parses(a, "%TAG !e tag:x,2000:\n---\nx\n"));
    try std.testing.expect(!parses(a, "%TAG !e! a\n%TAG !e! b\n---\nx\n"));
    try std.testing.expect(!parses(a, "--- !e!foo\nx\n"));
}

test "deep block nesting is bounded by NestingTooDeep" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // Build deeply-nested flow sequences ("[[[...]]]"): past max_depth the
    // parser must error rather than recurse or run away. Bound the work so a
    // regression cannot spin forever.
    const depth = Parser.max_depth + 16;
    const src = try a.alloc(u8, depth * 2);
    @memset(src[0..depth], '[');
    @memset(src[depth..], ']');
    var p: Parser = .init(a, src);
    const result = while (true) {
        _ = p.next() catch |err| break err;
    } else unreachable;
    try std.testing.expectEqual(Error.NestingTooDeep, result);
}

/// Drive a parser to stream end (or its first error), failing if it pulls
/// more than `cap` events. The cap turns a regressed infinite `next()`
/// loop into a test FAILURE instead of a hang -- a bounded resource check
/// for the flow-context loop fixes below.
fn drainBounded(a: std.mem.Allocator, src: []const u8, cap: usize) !void {
    var p: Parser = .init(a, src);
    var n: usize = 0;
    while (p.next() catch return) |_| {
        n += 1;
        if (n > cap) return error.ParserRunaway;
    }
}

test "unterminated flow collections terminate, not loop" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // An open flow collection that reaches a document/stream boundary must
    // fail (or otherwise terminate) rather than spin synthesizing empty
    // nodes against a token the flow grammar cannot consume. A small event
    // cap makes a regression fail fast instead of hanging the runner.
    const cap = 64;
    try drainBounded(a, "[ a, b\n", cap);
    try drainBounded(a, "{ a: b\n", cap);
    try drainBounded(a, "[\n", cap);
    try drainBounded(a, "---\n[ [ a, b, c ]\n", cap);
    try drainBounded(a, "{\n", cap);
}

test "empty-key single pair in a flow sequence terminates, not loop" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // `[: y]` / `[ : empty ]`: a `:` SEPARATED from following content is a
    // value indicator, so the element is a single-pair mapping with an empty
    // key. The pair-key step must supply the empty key and let the value step
    // consume the `:`, never looping over an unconsumed indicator.
    const cap = 64;
    try drainBounded(a, "[:x]\n", cap);
    try drainBounded(a, "[: y]\n", cap);
    try drainBounded(a, "[ : empty ]\n", cap);

    // `: y` (separated) is a single-pair mapping with an empty key.
    var buf: [16]EventKind = undefined;
    const np = try events(a, "[: y]\n", &buf);
    try std.testing.expectEqualSlices(EventKind, &.{
        .stream_start,  .document_start, .sequence_start,
        .mapping_start, .scalar,         .scalar,
        .mapping_end,   .sequence_end,   .document_end,
        .stream_end,
    }, buf[0..np]);

    // `:x` (glued to content) is an ordinary plain scalar `:x`, the sole
    // element of the sequence -- not a single-pair mapping.
    const ns = try events(a, "[:x]\n", &buf);
    try std.testing.expectEqualSlices(EventKind, &.{
        .stream_start, .document_start, .sequence_start,
        .scalar,       .sequence_end,   .document_end,
        .stream_end,
    }, buf[0..ns]);
}
