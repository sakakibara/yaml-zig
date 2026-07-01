//! Reader-backed, document-at-a-time streaming event reader.
//!
//! YAML's anchors are document-scoped and aliases deep-copy, so the document
//! is the smallest soundly bounded unit of a YAML stream -- there is no
//! token-level chunk-boundary resumption (unlike JSON). This reader pulls
//! bytes from a `std.Io.Reader` into a single-document buffer, frames one
//! complete document at a time using the real `Scanner` as the boundary
//! oracle, then drives the existing `Parser` over that document's bytes and
//! hands out its events one at a time -- re-based to absolute stream offsets.
//!
//! Reuses `scanner.zig`/`parser.zig` UNCHANGED for all parsing: correctness
//! piggybacks on the existing conformance suite. The only scanner cooperation
//! is `Scanner.frameDocument`, the boundary oracle.
//!
//! Memory: steady-state buffer is bounded to ONE document plus one pull chunk,
//! regardless of stream length, because each completed document is dropped
//! from the front of the buffer (`compact`) and `base` advances. A single
//! document larger than RAM still buffers fully -- the same bound libyaml has.
//!
//! Span re-basing: the per-document parser reports spans relative to the
//! document slice; this reader adds `base` to lift them to absolute stream
//! offsets. Offsets are u64, so any stream position is addressable without a
//! cap. Line/col are not stored; a caller derives them on demand from the
//! span and the document bytes via `Span.lineCol`.
//!
//! Borrow contract: an event's payload slices (scalar `value`, `anchor`,
//! `tag`, `alias_name`) borrow the document buffer and the per-document
//! parser's arena. They stay valid until the next boundary-crossing operation,
//! which is either a `next()` call that CROSSES a document boundary or a
//! `materialize()` call (both drop the buffer via `compact()` and reset the
//! arena). Within one document, successive events' slices remain valid; a
//! caller that needs a slice past the next boundary-crossing operation must
//! copy it.

const std = @import("std");

const scanner = @import("scanner.zig");
const parser = @import("parser.zig");
const composer = @import("composer.zig");
const diag_mod = @import("diagnostic.zig");
const value = @import("value.zig");

/// The streaming event type is the parser's event VERBATIM: stream/document
/// framing, collection start/end, scalar, alias, with anchor/tag/style/value.
/// Spans are re-based to absolute stream offsets by this reader.
pub const Event = parser.Event;

/// The kind of a streaming `Event`.
pub const EventKind = parser.EventKind;

/// Byte-offset source location, re-based to absolute stream offsets. u64
/// offsets address any stream position; line/col derive on demand.
pub const Span = value.Span;

/// One collected parse error: message, source span, optional suggestion.
pub const Diagnostic = composer.Diagnostic;

/// Compose/parse options. The EventReader's own event emission (next()) does
/// not apply options -- it emits raw parser events regardless. Options take
/// effect at the value layer: ValueStream.next() and EventReader.materialize()
/// thread them into the Composer, so schema/merge_keys/max_depth/max_alias_nodes
/// are honored identically to a buffered parse. `options.spans` is the
/// exception: the streaming value paths ignore it (spans are populated by
/// buffered parses only; see the field's doc in composer.zig).
pub const ParseOptions = composer.ParseOptions;

/// Errors a streaming parse can surface: the parser's grammar/nesting errors,
/// reader and allocator failures, plus `UnexpectedEndOfInput` for a document
/// truncated mid-construct at reader EOF.
pub const StreamError = error{
    YamlParseError,
    NestingTooDeep,
    /// Alias expansion exceeded the max_alias_nodes budget, bounding
    /// billion-laughs amplification. Set ParseOptions.max_alias_nodes higher
    /// for deeply aliased trusted input.
    AliasBudgetExceeded,
    /// The reader reached EOF while the buffer held an incomplete document
    /// (an unterminated quoted/block scalar, an open collection). The trailing
    /// bytes cannot frame a document.
    UnexpectedEndOfInput,
    /// A single document grew to `ParseOptions.max_document_bytes` without a
    /// terminating boundary. Buffering it whole would risk OOM, so the stream
    /// fails fast. Raise the cap (or set it to 0 to disable) for trusted input
    /// with legitimately huge single documents.
    DocumentTooLarge,
} || std.mem.Allocator.Error || std.Io.Reader.ShortError;

/// Reader-backed, document-at-a-time YAML event reader. Mirrors the SHAPE of
/// json-zig's `EventReader.fromReader`/`next`/`diagnostic`, but frames whole
/// documents rather than resuming token-level across chunk boundaries.
pub const EventReader = struct {
    gpa: std.mem.Allocator,
    options: ParseOptions,
    reader: *std.Io.Reader,

    /// Bytes of the document currently being framed/drained, plus any bytes
    /// pulled ahead that belong to following documents. `doc_buf.items[0]` is
    /// at absolute stream offset `base`.
    doc_buf: std.ArrayList(u8) = .empty,
    /// Absolute stream offset of `doc_buf.items[0]`. Added to every event span
    /// (u64 addition, no cap) so spans are absolute across the whole stream.
    base: u64 = 0,
    /// Reader at EOF: a short read returned zero bytes. Once set, the remaining
    /// buffer is the final document(s); no more pulls are attempted.
    ended: bool = false,

    /// Per-document parser, constructed lazily when a document is framed and
    /// torn down at the document boundary. Null between documents.
    doc: ?Doc = null,

    /// Whether the leading `stream_start` event has been emitted.
    stream_started: bool = false,
    /// Whether the closing `stream_end` event has been emitted; `next()`
    /// returns null after.
    stream_ended: bool = false,
    /// Latched once `next()` has returned an error. Errors are terminal at
    /// the event level: every subsequent `next()` returns null. There is no
    /// event-level recovery; per-document recovery lives in ValueStream.
    failed: bool = false,

    /// Whether the reader is positioned EXACTLY at a `document_start` event:
    /// set when `next()` returns `document_start`, cleared by the following
    /// `next()`. `materialize()` is valid only while this holds.
    at_document_start: bool = false,

    diag: ?Diagnostic = null,
    /// gpa-owned backing text for a compose-path diagnostic (see
    /// setComposeDiag); event-path diagnostics borrow the per-doc arena
    /// which lives until deinit and need no copy.
    owned_diag_msg: ?[]u8 = null,
    owned_diag_sug: ?[]const u8 = null,

    /// A framed document: its byte length within `doc_buf` (from offset 0),
    /// the parser driving it, and a per-document arena owning the parser's
    /// allocations (resolved tags, state stack, diagnostics). The arena is
    /// freed when the document boundary is crossed, bounding memory to one
    /// document. On the error path the document is NOT closed, so its arena
    /// (and any captured diagnostic) survives until `deinit`.
    const Doc = struct {
        len: usize,
        arena: std.heap.ArenaAllocator,
        p: parser.Parser,
        sink: diag_mod.Sink,
        errors: std.ArrayList(Diagnostic) = .empty,
    };

    /// Chunk size pulled from the reader per `pull()`. Mirrors json-zig's 4 KiB.
    const chunk = 4096;

    pub fn fromReader(gpa: std.mem.Allocator, reader: *std.Io.Reader, options: ParseOptions) EventReader {
        return .{ .gpa = gpa, .options = options, .reader = reader };
    }

    /// Return the current allocated capacity (in bytes) of the internal
    /// document buffer. Intended for benchmarks and tests that verify the
    /// bounded-memory property: regardless of how many documents a stream
    /// contains, this capacity stays proportional to the LARGEST single
    /// document seen, not to the total stream length.
    pub fn bufCapacity(self: *const EventReader) usize {
        return self.doc_buf.capacity;
    }

    pub fn deinit(self: *EventReader) void {
        if (self.doc) |*d| {
            d.p.deinit();
            d.arena.deinit();
        }
        self.doc_buf.deinit(self.gpa);
        self.freeComposeDiag();
    }

    pub fn diagnostic(self: *const EventReader) ?Diagnostic {
        return self.diag;
    }

    /// Store a compose-path diagnostic beyond the per-item arena's lifetime:
    /// text is duped into reader-owned gpa memory (freed on replace or
    /// deinit) and the span is re-based to absolute stream offsets.
    fn setComposeDiag(self: *EventReader, d: Diagnostic, doc_base: u64) void {
        const msg = self.gpa.dupe(u8, d.message) catch return;
        const sug: ?[]const u8 = if (d.suggestion) |sg|
            self.gpa.dupe(u8, sg) catch null
        else
            null;
        self.freeComposeDiag();
        self.owned_diag_msg = msg;
        self.owned_diag_sug = sug;
        self.diag = .{
            .message = msg,
            .suggestion = sug,
            .span = .{ .start = doc_base + d.span.start, .end = doc_base + d.span.end },
        };
    }

    fn freeComposeDiag(self: *EventReader) void {
        if (self.owned_diag_msg) |m| self.gpa.free(m);
        if (self.owned_diag_sug) |sg| self.gpa.free(sg);
        self.owned_diag_msg = null;
        self.owned_diag_sug = null;
    }

    /// Read one chunk from the backing reader into `doc_buf`. Sets `ended` at
    /// reader EOF (a zero-length short read).
    fn pull(self: *EventReader) StreamError!void {
        var tmp: [chunk]u8 = undefined;
        // readSliceShort returns fewer than buffer.len bytes (including 0) iff
        // the stream reached its end.
        const n = try self.reader.readSliceShort(&tmp);
        if (n == 0) {
            self.ended = true;
            return;
        }
        if (n < tmp.len) self.ended = true;
        try self.doc_buf.appendSlice(self.gpa, tmp[0..n]);
    }

    /// Drop the framed document's bytes from the front of `doc_buf`, advancing
    /// `base`. Bytes pulled ahead (belonging to following documents) slide to
    /// the front. Bounds steady-state memory to one document plus a pull chunk.
    fn compact(self: *EventReader, consumed: usize) void {
        if (consumed == 0) return;
        const keep = self.doc_buf.items.len - consumed;
        std.mem.copyForwards(u8, self.doc_buf.items[0..keep], self.doc_buf.items[consumed..]);
        self.doc_buf.shrinkRetainingCapacity(keep);
        self.base += consumed;
    }

    /// Pull bytes until `doc_buf` holds a complete first document (or the
    /// reader is at EOF). Returns the framed document's byte length, or null
    /// when the buffer is empty at EOF (no further document). The framing
    /// oracle is the real `Scanner` (`Scanner.frameDocument`); see its doc.
    ///
    /// `frameDocument` re-scans `doc_buf` from byte 0 each call, so re-scanning
    /// after every fixed-size pull would be O(doc_len^2) for one large boundary-
    /// free document. Instead, the buffer is grown GEOMETRICALLY between scans
    /// (roughly doubling), so a document of N bytes is scanned at sizes that sum
    /// to O(N): framing one large document is linear. `frameDocument` is called
    /// on the full buffer exactly as before, so the framing RESULT (the first
    /// boundary offset) is identical regardless of pull granularity.
    fn frame(self: *EventReader) StreamError!?usize {
        while (true) {
            switch (scanner.Scanner.frameDocument(self.doc_buf.items)) {
                .complete => |consumed| {
                    // A leading boundary with no preceding content (a `...` or a
                    // second `---` at offset 0) frames a zero-or-empty document;
                    // hand the boundary bytes to the parser so it emits the
                    // empty document the buffered path would.
                    return consumed;
                },
                .need_more => {
                    // A first document that reaches the cap with no boundary yet
                    // cannot be soundly buffered: fail fast rather than OOM. A
                    // small document always frames as `.complete`, so reaching
                    // the cap on `.need_more` means the first document itself is
                    // oversized.
                    const cap = self.options.max_document_bytes;
                    if (cap != 0 and self.doc_buf.items.len >= cap)
                        return error.DocumentTooLarge;

                    if (self.ended) {
                        // EOF: the remaining buffer is the final document. Empty
                        // (only whitespace already consumed / nothing) -> no doc.
                        if (self.doc_buf.items.len == 0) return null;
                        return self.doc_buf.items.len;
                    }

                    // Grow geometrically before the next scan; clamp to the cap
                    // so an oversized document is detected without overshooting.
                    var target = self.doc_buf.items.len * 2 + chunk;
                    if (cap != 0 and target > cap) target = cap;
                    while (self.doc_buf.items.len < target and !self.ended) {
                        try self.pull();
                    }
                },
            }
        }
    }

    /// Advance to the next event. Returns null once the closing `stream_end`
    /// event has been returned.
    ///
    /// Emits exactly one `stream_start` at the very beginning and one
    /// `stream_end` at true end-of-stream, framing each document in between via
    /// the per-document parser (whose own stream_start/stream_end are dropped).
    ///
    /// Errors are terminal (fail-fast): once `next()` has returned an error,
    /// every subsequent call returns null. `diagnostic()` still reports the
    /// captured failure. For per-document error recovery use ValueStream.
    pub fn next(self: *EventReader) StreamError!?Event {
        if (self.failed) return null;
        return self.advance() catch |e| {
            self.failed = true;
            return e;
        };
    }

    fn advance(self: *EventReader) StreamError!?Event {
        if (self.stream_ended) return null;

        // Any advance leaves the document_start position; re-set below only if
        // this call returns a fresh document_start. materialize() reads this.
        self.at_document_start = false;

        if (!self.stream_started) {
            self.stream_started = true;
            return Event{ .kind = .stream_start, .span = self.zeroSpan() };
        }

        while (true) {
            // Drain the in-flight document if one is open.
            if (self.doc) |*d| {
                const ev = d.p.next() catch |e| {
                    // Capture the parser's diagnostic (re-based to absolute
                    // stream offsets) for diagnostic(). The doc arena is not
                    // freed on this path, so the message stays valid.
                    if (d.errors.items.len > 0) {
                        var diag = d.errors.items[d.errors.items.len - 1];
                        diag.span.start = self.base + diag.span.start;
                        diag.span.end = self.base + diag.span.end;
                        self.diag = diag;
                    }
                    return mapParserError(e);
                };
                if (ev) |e| {
                    switch (e.kind) {
                        // The per-document parser's own stream framing is
                        // internal; the streaming reader supplies the single
                        // outer stream_start/stream_end. Drop these and loop.
                        .stream_start => continue,
                        .stream_end => {
                            // Document drained: drop its bytes, advance base,
                            // tear down the parser+arena, then frame the next.
                            self.closeDoc();
                            continue;
                        },
                        else => {
                            // Mark the document_start position so materialize()
                            // can validate it composes only the just-opened doc.
                            if (e.kind == .document_start) self.at_document_start = true;
                            return self.rebase(e);
                        },
                    }
                }
                // Parser returned null without a stream_end (it always emits
                // stream_end first, so this is unreachable in practice).
                self.closeDoc();
                continue;
            }

            // No open document: frame the next one.
            const len = try self.frame() orelse {
                self.stream_ended = true;
                return Event{ .kind = .stream_end, .span = self.zeroSpan() };
            };
            try self.openDoc(len);
        }
    }

    /// Construct the per-document parser over `doc_buf.items[0..len]`, wiring a
    /// diagnostic sink so `diagnostic()` reports a grammar error's message and
    /// (re-based) span. The sink and its error list live inside the stored
    /// `Doc`, whose address is stable for the parser's `*Sink` pointer.
    fn openDoc(self: *EventReader, len: usize) StreamError!void {
        // Store the arena in its final location FIRST, then build the parser and
        // sink from THAT arena's allocator. An ArenaAllocator's interface
        // captures a pointer to the arena, so constructing the parser from a
        // local arena and then moving it into the struct would dangle that
        // pointer; build after the move.
        self.doc = .{
            .len = len,
            .arena = std.heap.ArenaAllocator.init(self.gpa),
            .p = undefined,
            .sink = undefined,
        };
        const d = &self.doc.?;
        const slice = self.doc_buf.items[0..len];
        d.p = parser.Parser.init(d.arena.allocator(), slice);
        d.sink = diag_mod.Sink.init(d.arena.allocator(), &d.errors);
        d.p.setSink(&d.sink);
    }

    /// Tear down the in-flight document: compact its bytes out of `doc_buf`,
    /// advance `base`, free the parser and its arena.
    fn closeDoc(self: *EventReader) void {
        if (self.doc) |*d| {
            const len = d.len;
            d.p.deinit();
            d.arena.deinit();
            self.doc = null;
            self.compact(len);
        }
    }

    /// Re-base a per-document event's span to absolute stream offsets
    /// (u64, no cap). `line`/`col` are document-local and carry through.
    fn rebase(self: *const EventReader, ev: Event) Event {
        var out = ev;
        out.span.start = self.base + ev.span.start;
        out.span.end = self.base + ev.span.end;
        return out;
    }

    /// A zero-width span at the current absolute buffer front, for synthesized
    /// stream_start/stream_end events.
    fn zeroSpan(self: *const EventReader) Span {
        return .{ .start = self.base, .end = self.base };
    }

    /// Compose the current document into arena and return it as a Value.
    ///
    /// Valid position: materialize() is valid ONLY immediately after next()
    /// returned a document_start event, before any further next() advanced into
    /// the document. At that position it composes the ENTIRE current document
    /// from its framed bytes using the Composer and returns the document root
    /// Value. Called at any other position (no open document, or after next()
    /// advanced past the document_start), it returns error.YamlParseError.
    ///
    /// This single-position contract exists because the Composer drives a full
    /// Parser over a complete document slice; there is no entry point for
    /// composing from mid-document events.
    ///
    /// After materialize() returns, the reader's in-flight document is closed
    /// and compact()ed so subsequent next() calls advance to the next document.
    /// materialize() is therefore a boundary-crossing operation: any event
    /// payload slices borrowed from the just-composed document are invalidated.
    ///
    /// On a compose error the diagnostic is captured (re-based to absolute
    /// stream offsets) into diag, so diagnostic() reports it afterwards.
    ///
    /// `options.spans` is ignored on this path (spans are populated by
    /// buffered parses only): the entries would live in the per-document
    /// arena and dangle in the caller's persistent map once it is reset.
    pub fn materialize(self: *EventReader, arena: std.mem.Allocator) StreamError!value.Value {
        if (!self.at_document_start) return error.YamlParseError;
        const d = self.doc orelse return error.YamlParseError;
        self.at_document_start = false;

        // Dupe the document bytes into the caller's arena before closeDoc()
        // compacts them out of doc_buf. Zero-copy plain scalars will point
        // into this arena-owned copy and remain valid after compact().
        const doc_bytes = try arena.dupe(u8, self.doc_buf.items[0..d.len]);

        // Capture the stream base before closeDoc() advances it: spans and the
        // diagnostic recorded by composeDocBytes are document-local and must be
        // re-based by this document's absolute start offset.
        const doc_base = self.base;

        // Close the in-flight per-document parser and compact its bytes.
        self.closeDoc();

        // Compose the framed bytes via the Composer (anchors, aliases, merge
        // keys, alias-budget enforcement). options is threaded so schema/
        // merge_keys/budgets are honored identically to a buffered parse;
        // options.spans is ignored (see composeDocBytes).
        var last_diag: ?Diagnostic = null;
        const v = composeDocBytes(arena, doc_bytes, self.options, &last_diag) catch |e| {
            // Surface the diagnostic, re-based to absolute stream offsets and
            // copied into reader-owned memory, so diagnostic() works after a
            // materialize failure (mirrors next()).
            if (last_diag) |ld| self.setComposeDiag(ld, doc_base);
            return e;
        };

        // The reader is positioned at a framed document_start, so the bytes
        // always carry a document; a null compose (whitespace-only) surfaces as
        // the null Value here.
        return v orelse .null;
    }
};

/// Compose a single document from its framed bytes into a Value tree.
/// Runs the Composer over `doc_bytes` using `options` (schema, merge_keys,
/// max_depth, max_alias_nodes). Returns the single Value, null when the bytes
/// carry NO document (whitespace/comments only, no document_start), or an
/// error. The null return is distinct from a document whose value is the YAML
/// null scalar, which composes to a `.null` Value.
/// `AliasBudgetExceeded` is threaded through from the Composer.
///
/// `options.spans` is ignored here: span entries and their path keys would be
/// allocated from the per-item arena the caller resets between documents, so
/// recording them into the caller's persistent map would dangle. The same
/// holds for `options.errors`: the caller's persistent list must not be grown
/// from the per-item arena, so composing uses a LOCAL sink (the sink's
/// presence still opts into recovery) and the last diagnostic is handed back
/// through `last_diag_out` for the caller to copy into reader-owned storage
/// before the arena can be reset. Both sinks are populated by buffered
/// parses only.
fn composeDocBytes(arena: std.mem.Allocator, doc_bytes: []const u8, options: ParseOptions, last_diag_out: ?*?Diagnostic) StreamError!?value.Value {
    var opts = options;
    opts.spans = null;

    var local_errs: std.ArrayList(Diagnostic) = .empty;
    if (options.errors != null) opts.errors = &local_errs;

    const docs = composer.parseStream(arena, doc_bytes, opts) catch |e| {
        if (last_diag_out) |out| {
            if (local_errs.items.len > 0) out.* = local_errs.items[local_errs.items.len - 1];
        }
        return mapComposerError(e);
    };

    // A framed document may produce 0 Values (whitespace/comments-only bytes
    // with no document_start, e.g. trailing whitespace at EOF) or exactly 1.
    // More than 1 is not possible because the framer provides exactly one
    // document's bytes. 0 means "no document present", not "null document".
    if (docs.len == 0) return null;
    return docs[0];
}

/// Map a composer error into the streaming error set.
fn mapComposerError(e: composer.Error) StreamError {
    return switch (e) {
        error.YamlParseError => error.YamlParseError,
        error.NestingTooDeep => error.NestingTooDeep,
        error.AliasBudgetExceeded => error.AliasBudgetExceeded,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Reader-backed, document-at-a-time YAML value stream. Composes one Value
/// per document from the reader, reusing the EventReader's document framing
/// and the existing Composer for event->Value translation (anchors, aliases,
/// merge keys, alias-budget enforcement).
///
/// Usage:
///   var vs = ValueStream.fromReader(gpa, &reader, .{});
///   defer vs.deinit();
///   var item_arena = std.heap.ArenaAllocator.init(gpa);
///   defer item_arena.deinit();
///   while (try vs.next(item_arena.allocator())) |v| {
///       // use v ...
///       _ = item_arena.reset(.retain_capacity); // free previous doc
///   }
///
/// The caller resets item_arena between calls to bound memory to a single
/// document's Value tree. ParseOptions (schema/merge_keys/max_depth/
/// max_alias_nodes) are applied per document by the Composer.
pub const ValueStream = struct {
    /// Document-framing engine. Pulls bytes and frames one document at a time.
    inner: EventReader,
    done: bool = false,

    pub fn fromReader(gpa: std.mem.Allocator, reader: *std.Io.Reader, options: ParseOptions) ValueStream {
        return .{ .inner = EventReader.fromReader(gpa, reader, options) };
    }

    pub fn deinit(self: *ValueStream) void {
        self.inner.deinit();
    }

    /// Compose the next document into item_arena and return it, or return null
    /// at end of stream. The caller should reset item_arena between calls to
    /// bound memory to one document at a time.
    ///
    /// The returned Value's string slices are owned by item_arena (the source
    /// bytes are duped into item_arena before composing, so zero-copy plain
    /// scalars remain valid after the internal document buffer is advanced).
    ///
    /// `options.spans` is ignored on this path (spans are populated by
    /// buffered parses only): the entries would live in item_arena and dangle
    /// in the caller's persistent map once item_arena is reset.
    ///
    /// Error policy matches `parseStream`:
    ///   - `options.errors == null`: a compose error terminates the stream.
    ///     The error is surfaced immediately and subsequent next() calls return
    ///     null. The failed document is NOT silently skipped.
    ///   - `options.errors != null`: a compose error for one document is
    ///     surfaced on this call (the diagnostic is appended to errors), but the
    ///     stream is NOT terminated. The bad document is advanced past, and the
    ///     caller may call next() again to receive the following document. This
    ///     mirrors parseStream's per-document recovery: errors are collected,
    ///     good documents before and after a bad one are accessible, and the
    ///     caller can detect that any error occurred by checking errors.items.
    pub fn next(self: *ValueStream, item_arena: std.mem.Allocator) StreamError!?value.Value {
        if (self.done) return null;

        // A content-less frame (a bare `...`/a leading or doubled `---` that
        // carries no document_start) composes to no Value but is NOT end of
        // stream: skip it and frame the next document. Only `frame()` itself
        // returning null (buffer empty at reader EOF) terminates the stream.
        // EventReader.next() loops the same way; mirroring it here keeps the
        // two reader views in lock-step over identical input.
        while (true) {
            const len = try self.inner.frame() orelse {
                self.done = true;
                return null;
            };

            // Dupe the framed bytes into item_arena before composing. The
            // Composer's zero-copy plain scalars will point into this owned
            // slice, so they remain valid after compact() recycles doc_buf.
            const doc_bytes = try item_arena.dupe(u8, self.inner.doc_buf.items[0..len]);

            // Capture the base before compose so spans/diag can be re-based by
            // this document's absolute start offset.
            const doc_base = self.inner.base;

            // Compose BEFORE compacting: on error the document bytes must not be
            // discarded silently.
            var last_diag: ?Diagnostic = null;
            const v = composeDocBytes(item_arena, doc_bytes, self.inner.options, &last_diag) catch |e| {
                // Capture the most recent diagnostic (re-based to absolute
                // stream offsets, copied into reader-owned memory) so
                // diagnostic() reports it after this call.
                if (last_diag) |ld| self.inner.setComposeDiag(ld, doc_base);
                // When errors is set: recover -- advance past the bad document
                // and let the caller retry. When errors is null: terminate.
                if (self.inner.options.errors != null) {
                    self.inner.compact(len);
                } else {
                    self.done = true;
                }
                return e;
            };

            // Compose succeeded: drop the document bytes from the front of the
            // buffer (advance base). Spans were already re-based by composeDocBytes.
            self.inner.compact(len);

            // A frame that carried a real document yields its Value. A content-
            // less frame (composeDocBytes == null) is not end of stream while
            // bytes remain: loop to frame the following document.
            if (v) |val| return val;
        }
    }
};

/// Map a parser error into the streaming error set. The parser surfaces
/// `YamlParseError`/`NestingTooDeep`/allocator errors; a document truncated
/// mid-construct at EOF is parsed over its final (incomplete) bytes and the
/// parser reports `YamlParseError`, which the reader leaves as-is. The
/// `UnexpectedEndOfInput` member of `StreamError` is reserved for callers that
/// want to distinguish EOF truncation; the parser does not raise it.
fn mapParserError(e: parser.Error) StreamError {
    return switch (e) {
        error.YamlParseError => error.YamlParseError,
        error.NestingTooDeep => error.NestingTooDeep,
        error.OutOfMemory => error.OutOfMemory,
    };
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

/// Drain every event from a reader-backed EventReader over `src`, delivered
/// whole via a fixed reader, into `out` (tags+payload snapshots). The reader
/// owns the events' borrowed slices only until the next boundary-crossing
/// next(), so the snapshot copies payloads into `a`.
const EvSnapshot = struct {
    kind: EventKind,
    value: []const u8,
    anchor: ?[]const u8,
    tag: ?[]const u8,
    alias_name: []const u8,
    flow: bool,
    style: scanner.ScalarStyle,
    /// Whether this is an explicit document marker (`---`/`...`).
    explicit: bool,
    /// Absolute stream byte offset where this event begins.
    span_start: u64,
    /// Absolute stream byte offset where this event ends.
    span_end: u64,
};

fn snapshot(a: std.mem.Allocator, ev: Event) !EvSnapshot {
    return .{
        .kind = ev.kind,
        .value = try a.dupe(u8, ev.value),
        .anchor = if (ev.anchor) |x| try a.dupe(u8, x) else null,
        .tag = if (ev.tag) |x| try a.dupe(u8, x) else null,
        .alias_name = try a.dupe(u8, ev.alias_name),
        .flow = ev.flow,
        .style = ev.scalar_style,
        .explicit = ev.explicit,
        .span_start = ev.span.start,
        .span_end = ev.span.end,
    };
}

/// Drain a streaming EventReader over `src` delivered whole, snapshotting
/// every event into `a`.
fn drainStreamWhole(a: std.mem.Allocator, src: []const u8) ![]EvSnapshot {
    var r: std.Io.Reader = .fixed(src);
    var er = EventReader.fromReader(a, &r, .{});
    defer er.deinit();
    var out: std.ArrayList(EvSnapshot) = .empty;
    while (try er.next()) |ev| try out.append(a, try snapshot(a, ev));
    return out.toOwnedSlice(a);
}

/// A std.Io.Reader that releases `src` in fixed-size slices, to exercise
/// chunk-boundary framing. `step` bytes per fill; `step == 1` is the 1-byte
/// stress case.
const ChunkedReader = struct {
    src: []const u8,
    pos: usize = 0,
    step: usize,
    reader: std.Io.Reader,

    fn init(src: []const u8, step: usize, buffer: []u8) ChunkedReader {
        return .{
            .src = src,
            .step = step,
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
        };
    }

    fn stream(io_r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *ChunkedReader = @fieldParentPtr("reader", io_r);
        if (self.pos >= self.src.len) return error.EndOfStream;
        const want = @min(self.step, self.src.len - self.pos);
        const give = @min(want, @intFromEnum(limit));
        const n = try w.write(self.src[self.pos..][0..give]);
        self.pos += n;
        return n;
    }
};

/// Drain a streaming EventReader over `src` delivered `step` bytes at a time.
fn drainStreamChunked(a: std.mem.Allocator, src: []const u8, step: usize) ![]EvSnapshot {
    var rbuf: [64]u8 = undefined;
    var cr = ChunkedReader.init(src, step, &rbuf);
    var er = EventReader.fromReader(a, &cr.reader, .{});
    defer er.deinit();
    var out: std.ArrayList(EvSnapshot) = .empty;
    while (try er.next()) |ev| try out.append(a, try snapshot(a, ev));
    return out.toOwnedSlice(a);
}

/// Drain the buffered Parser over `src` into the same snapshot shape, the
/// cross-check oracle. The buffered parser emits its own single
/// stream_start/stream_end, exactly what the streaming reader synthesizes, so
/// the sequences are directly comparable.
fn drainBuffered(a: std.mem.Allocator, src: []const u8) ![]EvSnapshot {
    var p = parser.Parser.init(a, src);
    defer p.deinit();
    var out: std.ArrayList(EvSnapshot) = .empty;
    while (try p.next()) |ev| try out.append(a, try snapshot(a, ev));
    return out.toOwnedSlice(a);
}

fn expectSnapshotsEqual(want: []const EvSnapshot, got: []const EvSnapshot) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try testing.expectEqual(w.kind, g.kind);
        try testing.expectEqualStrings(w.value, g.value);
        try testing.expectEqual(w.flow, g.flow);
        try testing.expectEqual(w.style, g.style);
        try testing.expectEqualStrings(w.alias_name, g.alias_name);
        if (w.anchor) |wa| try testing.expectEqualStrings(wa, g.anchor.?) else try testing.expect(g.anchor == null);
        if (w.tag) |wt| try testing.expectEqualStrings(wt, g.tag.?) else try testing.expect(g.tag == null);
        try testing.expectEqual(w.explicit, g.explicit);
        try testing.expectEqual(w.span_start, g.span_start);
        try testing.expectEqual(w.span_end, g.span_end);
    }
}

// --- Gate A: empty / whitespace-only input --------------------------------

test "empty reader yields stream_start then stream_end then null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "", "   ", "\n\n", "  \t\n  \n" }) |src| {
        const evs = try drainStreamWhole(a, src);
        try testing.expectEqual(@as(usize, 2), evs.len);
        try testing.expectEqual(EventKind.stream_start, evs[0].kind);
        try testing.expectEqual(EventKind.stream_end, evs[1].kind);
    }
}

// --- Gate B: cross-check vs the buffered parser ---------------------------

const cross_check_cases = [_][]const u8{
    "scalar\n",
    "42\n",
    "a: 1\nb: 2\n",
    "- one\n- two\n- three\n",
    "key:\n  nested: value\n  list:\n    - a\n    - b\n",
    "---\ndoc1\n---\ndoc2\n",
    "---\na: 1\n---\nb: 2\n---\nc: 3\n",
    "&anchor value\n",
    "first: &a hello\nsecond: *a\n",
    "!!str 123\n",
    "tagged: !!int 42\n",
    "block: |\n  line one\n  line two\n",
    "folded: >\n  folded text\n  more text\n",
    "flow_seq: [1, 2, 3]\n",
    "flow_map: {a: 1, b: 2}\n",
    "mixed:\n  - {x: 1}\n  - [a, b]\n",
    "quoted: \"with: colon\"\n",
    "single: 'it''s'\n",
    "doc1: a\n...\ndoc2: b\n",
    "? explicit\n: key\n",
    "nested:\n  deep:\n    deeper:\n      value: x\n",
    "list:\n- &x 1\n- *x\n",
    "empty_doc:\n---\n---\nafter: empties\n",
    "%YAML 1.2\n---\ndirected: doc\n",
    "%TAG !e! tag:example.com,2000:\n---\n!e!thing value\n",
    "a: 1\n...\n%YAML 1.2\n---\nb: 2\n",
    "plain scalar\nthat folds\nacross lines\n",
    "literal: |\n  keeps\n  ---\n  not a marker\n",
    "in_quote: \"text --- still in quote\"\n",
};

test "streaming events match buffered parser over the same bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (cross_check_cases) |src| {
        const want = try drainBuffered(a, src);
        const got = try drainStreamWhole(a, src);
        expectSnapshotsEqual(want, got) catch |e| {
            std.debug.print("cross-check mismatch on: {s}\n", .{src});
            return e;
        };
    }
}

// --- Gate C: chunk-boundary framing equivalence ---------------------------

const chunk_cases = [_][]const u8{
    "---\na: 1\n---\nb: 2\n---\nc: 3\n",
    "block: |\n  line one\n  line two\n  line three\n---\nnext: doc\n",
    "folded: >\n  a folded\n  scalar here\n---\nx: y\n",
    "s: \"a string\nspanning lines\"\n---\nt: u\n",
    "single: 'multi\nline single'\n---\nv: w\n",
    "doc1\n---\ndoc2\n---\ndoc3\n...\ndoc4\n",
    "- a\n- b\n- c\n---\n- d\n- e\n",
    "first: &a hello\nsecond: *a\n---\nthird: &b world\nfourth: *b\n",
    "deep:\n  map:\n    here: 1\n---\nother:\n  - 1\n  - 2\n",
    // `---`/`...` INSIDE a block scalar are content, not boundaries: the
    // scanner-as-oracle must not frame on them even when they straddle a
    // chunk split. The trailing real `---` IS a boundary.
    "lit: |\n  body line\n  --- not a marker\n  ... also not\n  end\n---\nreal: doc\n",
    // A `...` end-marker then a fresh implicit document.
    "a: 1\n...\nb: 2\n...\nc: 3\n",
    // Directives split across a chunk boundary, then their document.
    "%YAML 1.2\n---\nx: 1\n...\n%TAG ! !local-\n---\ny: 2\n",
};

test "chunk-boundary framing: identical at every chunk size including 1 byte" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (chunk_cases) |src| {
        const whole = try drainStreamWhole(a, src);
        // 1-byte chunks (the load-bearing case) plus several other sizes that
        // land splits inside scalars / on `---` markers at varying offsets.
        for ([_]usize{ 1, 2, 3, 5, 7, 13, 16, 17, 32 }) |step| {
            const chunked = try drainStreamChunked(a, src, step);
            expectSnapshotsEqual(whole, chunked) catch |e| {
                std.debug.print("chunk mismatch (step={d}) on: {s}\n", .{ step, src });
                return e;
            };
        }
    }
}

/// A reader that releases `src` split at exactly one offset: `[0..at]` first,
/// then the rest. Exercises framing when a chunk boundary lands on a specific
/// byte (the streaming analog of json's "identical at every split point").
const SplitAtReader = struct {
    src: []const u8,
    at: usize,
    pos: usize = 0,
    reader: std.Io.Reader,

    fn init(src: []const u8, at: usize, buffer: []u8) SplitAtReader {
        return .{
            .src = src,
            .at = at,
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
        };
    }

    fn stream(io_r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *SplitAtReader = @fieldParentPtr("reader", io_r);
        if (self.pos >= self.src.len) return error.EndOfStream;
        const end = if (self.pos < self.at) self.at else self.src.len;
        const give = @min(@intFromEnum(limit), end - self.pos);
        const n = try w.write(self.src[self.pos..][0..give]);
        self.pos += n;
        return n;
    }
};

test "framing identical at every single split offset" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (chunk_cases) |src| {
        const whole = try drainStreamWhole(a, src);
        var at: usize = 0;
        while (at <= src.len) : (at += 1) {
            var rbuf: [64]u8 = undefined;
            var sr = SplitAtReader.init(src, at, &rbuf);
            var er = EventReader.fromReader(a, &sr.reader, .{});
            defer er.deinit();
            var got: std.ArrayList(EvSnapshot) = .empty;
            while (try er.next()) |ev| try got.append(a, try snapshot(a, ev));
            expectSnapshotsEqual(whole, got.items) catch |e| {
                std.debug.print("split-at mismatch (at={d}) on: {s}\n", .{ at, src });
                return e;
            };
        }
    }
}

test "chunk-boundary equivalence matches buffered parser too" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (chunk_cases) |src| {
        const want = try drainBuffered(a, src);
        const got = try drainStreamChunked(a, src, 1);
        expectSnapshotsEqual(want, got) catch |e| {
            std.debug.print("1-byte vs buffered mismatch on: {s}\n", .{src});
            return e;
        };
    }
}

// --- Gate D: 3-document framing + base advancing --------------------------

test "three-document stream frames document_start/end and advances base" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "---\nfirst: 1\n---\nsecond: 2\n---\nthird: 3\n";
    var r: std.Io.Reader = .fixed(src);
    var er = EventReader.fromReader(a, &r, .{});
    defer er.deinit();

    var doc_starts: usize = 0;
    var doc_ends: usize = 0;
    var last_doc_start_off: u64 = 0;
    var first = true;
    while (try er.next()) |ev| {
        switch (ev.kind) {
            .document_start => {
                doc_starts += 1;
                // Each document_start's absolute offset is strictly greater
                // than the previous one: base is advancing across the stream.
                if (!first) try testing.expect(ev.span.start > last_doc_start_off);
                last_doc_start_off = ev.span.start;
                first = false;
            },
            .document_end => doc_ends += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 3), doc_starts);
    try testing.expectEqual(@as(usize, 3), doc_ends);
}

test "absolute spans match the byte offsets in the source" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Second document's scalar "world" sits at a known absolute offset; the
    // re-based span must point at it in the original stream bytes.
    const src = "first: hello\n---\nsecond: world\n";
    var r: std.Io.Reader = .fixed(src);
    var er = EventReader.fromReader(a, &r, .{});
    defer er.deinit();
    while (try er.next()) |ev| {
        if (ev.kind == .scalar and std.mem.eql(u8, ev.value, "world")) {
            try testing.expectEqualStrings("world", src[ev.span.start..ev.span.end]);
            return;
        }
    }
    return error.ScalarNotFound;
}

test "borrow contract: event payload slices stay valid within one document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Two scalars in ONE document. The first scalar's value slice must still
    // be readable after pulling the second event (no boundary crossed between
    // them), matching the documented within-document stability.
    const src = "alpha: bravo\n";
    var r: std.Io.Reader = .fixed(src);
    var er = EventReader.fromReader(a, &r, .{});
    defer er.deinit();
    var first_value: ?[]const u8 = null;
    while (try er.next()) |ev| {
        if (ev.kind == .scalar and first_value == null) {
            first_value = ev.value; // borrows doc_buf
            try testing.expectEqualStrings("alpha", first_value.?);
        } else if (ev.kind == .scalar) {
            // A later event in the SAME document: the earlier borrowed slice is
            // still valid (the buffer has not been compacted/dropped).
            try testing.expectEqualStrings("alpha", first_value.?);
            try testing.expectEqualStrings("bravo", ev.value);
            return;
        }
    }
    return error.ScalarsNotFound;
}

test "diagnostic surfaces on a truncated document at EOF" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // An unterminated double-quoted scalar at EOF: the parser reports it once
    // the reader is exhausted (framing handed it the final bytes).
    const src = "key: \"unterminated\n";
    var r: std.Io.Reader = .fixed(src);
    var er = EventReader.fromReader(a, &r, .{});
    defer er.deinit();
    const Drain = struct {
        fn run(reader: *EventReader) StreamError!void {
            while (try reader.next()) |ev| {
                if (ev.kind == .stream_end) return;
            }
        }
    };
    try testing.expectError(error.YamlParseError, Drain.run(&er));
    // diagnostic() reports the captured parser error.
    try testing.expect(er.diagnostic() != null);
}

test "EventReader: errors are terminal, next() after an error returns null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A bad first document followed by a well-formed second one. The event
    // reader is fail-fast: after next() returns the parse error, subsequent
    // calls return null -- the following document is NOT surfaced.
    const src = "key: \"unterminated\n---\ngood: 1\n";
    var r: std.Io.Reader = .fixed(src);
    var er = EventReader.fromReader(a, &r, .{});
    defer er.deinit();

    var got_err = false;
    while (true) {
        const ev = er.next() catch {
            got_err = true;
            break;
        };
        if (ev == null) break;
    }
    try testing.expect(got_err);

    // Terminal: repeated calls keep returning null, never events or errors.
    try testing.expect((try er.next()) == null);
    try testing.expect((try er.next()) == null);
    // The captured diagnostic survives the latch.
    try testing.expect(er.diagnostic() != null);
}

// --- Gate E: ValueStream and materialize ----------------------------------

test "ValueStream: single scalar document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "hello\n";
    var r: std.Io.Reader = .fixed(src);
    var vs = ValueStream.fromReader(a, &r, .{});
    defer vs.deinit();

    var item_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer item_arena.deinit();

    const v = (try vs.next(item_arena.allocator())) orelse return error.ExpectedValue;
    try testing.expect(v == .string);
    try testing.expectEqualStrings("hello", v.string);
    try testing.expectEqual(@as(?value.Value, null), try vs.next(item_arena.allocator()));
}

test "ValueStream: multi-document stream yields one Value per document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "---\nfoo: 1\n---\nbar: 2\n---\n- x\n- y\n";
    var r: std.Io.Reader = .fixed(src);
    var vs = ValueStream.fromReader(a, &r, .{});
    defer vs.deinit();

    var item_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer item_arena.deinit();

    // doc 1: {foo: 1}
    const v1 = (try vs.next(item_arena.allocator())) orelse return error.ExpectedDoc1;
    try testing.expectEqual(@as(i128, 1), v1.get("foo").?.int);
    _ = item_arena.reset(.retain_capacity);

    // doc 2: {bar: 2}
    const v2 = (try vs.next(item_arena.allocator())) orelse return error.ExpectedDoc2;
    try testing.expectEqual(@as(i128, 2), v2.get("bar").?.int);
    _ = item_arena.reset(.retain_capacity);

    // doc 3: [x, y]
    const v3 = (try vs.next(item_arena.allocator())) orelse return error.ExpectedDoc3;
    try testing.expect(v3 == .seq);
    try testing.expectEqual(@as(usize, 2), v3.seq.len);
    _ = item_arena.reset(.retain_capacity);

    // exhausted
    try testing.expectEqual(@as(?value.Value, null), try vs.next(item_arena.allocator()));
}

test "ValueStream: cross-check against buffered parseStream for each document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cases = [_][]const u8{
        "scalar\n",
        "a: 1\nb: 2\n",
        "- one\n- two\n- three\n",
        "---\ndoc1\n---\ndoc2\n",
        "---\na: 1\n---\nb: 2\n---\nc: 3\n",
        "first: &anc hello\nsecond: *anc\n",
        "<<: &base\n  x: 1\n  y: 2\n<<: *base\nz: 3\n",
        "block: |\n  line one\n  line two\n",
        "folded: >\n  folded text\n  more text\n",
        "flow_seq: [1, 2, 3]\n",
        "flow_map: {a: 1, b: 2}\n",
        "list:\n- &x 1\n- *x\n",
        "tagged: !!int 42\n",
    };

    for (cases) |src| {
        // Buffered: collect all documents as the oracle.
        const buffered = try composer.parseStream(a, src, .{});

        // Streaming: collect all documents.
        var r: std.Io.Reader = .fixed(src);
        var vs = ValueStream.fromReader(a, &r, .{});
        defer vs.deinit();
        var streamed: std.ArrayList(value.Value) = .empty;
        while (try vs.next(a)) |v| try streamed.append(a, v);

        try testing.expectEqual(buffered.len, streamed.items.len);
        for (buffered, streamed.items) |bv, sv| {
            testing.expect(bv.eql(sv)) catch |e| {
                std.debug.print("cross-check mismatch on: {s}\n", .{src});
                return e;
            };
        }
    }
}

test "ValueStream: per-item arena reset between documents bounds memory" {
    var gpa_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer gpa_arena.deinit();
    const gpa = gpa_arena.allocator();

    // 5 documents; reset the item_arena between each call.
    const src = "a: 1\n---\nb: 2\n---\nc: 3\n---\nd: 4\n---\ne: 5\n";
    var r: std.Io.Reader = .fixed(src);
    var vs = ValueStream.fromReader(gpa, &r, .{});
    defer vs.deinit();

    var item_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer item_arena.deinit();

    var count: usize = 0;
    while (try vs.next(item_arena.allocator())) |_| {
        count += 1;
        _ = item_arena.reset(.retain_capacity);
    }
    try testing.expectEqual(@as(usize, 5), count);
}

test "ValueStream: anchor resolved within document, alias across document boundary is undefined-anchor error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Within a document: resolves fine.
    {
        const src = "first: &a hello\nsecond: *a\n";
        var r: std.Io.Reader = .fixed(src);
        var vs = ValueStream.fromReader(a, &r, .{});
        defer vs.deinit();
        const v = (try vs.next(a)) orelse return error.ExpectedValue;
        try testing.expectEqualStrings("hello", v.get("second").?.string);
    }

    // Alias in doc2 referencing anchor from doc1: error (document-scoped anchor table).
    {
        const src = "---\n&a hello\n---\n*a\n";
        var r: std.Io.Reader = .fixed(src);
        var vs = ValueStream.fromReader(a, &r, .{});
        defer vs.deinit();
        _ = try vs.next(a); // doc1 ok
        try testing.expectError(error.YamlParseError, vs.next(a));
    }
}

test "ValueStream: max_alias_nodes budget honored (billion-laughs protection)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A bomb that expands exponentially via aliases.
    const bomb =
        \\- &a [1, 2, 3, 4, 5, 6, 7, 8, 9]
        \\- &b [*a, *a, *a, *a, *a, *a, *a, *a, *a]
        \\- &c [*b, *b, *b, *b, *b, *b, *b, *b, *b]
        \\- &d [*c, *c, *c, *c, *c, *c, *c, *c, *c]
        \\- [*d, *d, *d, *d, *d, *d, *d, *d, *d]
    ;

    // With very low budget: must error.
    var r: std.Io.Reader = .fixed(bomb);
    var vs = ValueStream.fromReader(a, &r, .{ .max_alias_nodes = 100 });
    defer vs.deinit();
    try testing.expectError(error.AliasBudgetExceeded, vs.next(a));
}

test "ValueStream: chunk-boundary yields identical Values (1-byte chunks)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "---\nfoo: bar\n---\nbaz: qux\n";

    // Whole.
    var r_whole: std.Io.Reader = .fixed(src);
    var vs_whole = ValueStream.fromReader(a, &r_whole, .{});
    defer vs_whole.deinit();
    var whole_vals: std.ArrayList(value.Value) = .empty;
    while (try vs_whole.next(a)) |v| try whole_vals.append(a, v);

    // 1-byte chunks.
    var rbuf: [64]u8 = undefined;
    var cr = ChunkedReader.init(src, 1, &rbuf);
    var vs_chunked = ValueStream.fromReader(a, &cr.reader, .{});
    defer vs_chunked.deinit();
    var chunk_vals: std.ArrayList(value.Value) = .empty;
    while (try vs_chunked.next(a)) |v| try chunk_vals.append(a, v);

    try testing.expectEqual(whole_vals.items.len, chunk_vals.items.len);
    for (whole_vals.items, chunk_vals.items) |wv, cv| {
        try testing.expect(wv.eql(cv));
    }
}

test "EventReader.materialize: at document-start position composes current document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Position the reader at a document_start event, then materialize.
    const src = "a: 1\nb: 2\n";
    var r: std.Io.Reader = .fixed(src);
    var er = EventReader.fromReader(a, &r, .{});
    defer er.deinit();

    // Advance to the document_start event.
    while (try er.next()) |ev| {
        if (ev.kind == .document_start) break;
    }

    var item_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer item_arena.deinit();
    const v = try er.materialize(item_arena.allocator());
    try testing.expectEqual(@as(i128, 1), v.get("a").?.int);
    try testing.expectEqual(@as(i128, 2), v.get("b").?.int);
}

test "EventReader.materialize: agrees with buffered parse for mapping/sequence/alias/merge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cases = [_][]const u8{
        "scalar_val\n",
        "a: 1\nb: 2\n",
        "- one\n- two\n",
        "first: &anc hello\nsecond: *anc\n",
    };

    for (cases) |src| {
        const want = try composer.parse(a, src, .{});

        var r: std.Io.Reader = .fixed(src);
        var er = EventReader.fromReader(a, &r, .{});
        defer er.deinit();
        while (try er.next()) |ev| {
            if (ev.kind == .document_start) break;
        }
        var item_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer item_arena.deinit();
        const got = try er.materialize(item_arena.allocator());

        testing.expect(want.eql(got)) catch |e| {
            std.debug.print("materialize mismatch on: {s}\n", .{src});
            return e;
        };
    }
}

test "EventReader.materialize: options.max_alias_nodes is honored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "first: &anc [1, 2, 3]\nsecond: *anc\nthird: *anc\n";

    var r: std.Io.Reader = .fixed(src);
    // budget of 1: the first alias copy exhausts the budget immediately.
    var er = EventReader.fromReader(a, &r, .{ .max_alias_nodes = 1 });
    defer er.deinit();
    while (try er.next()) |ev| {
        if (ev.kind == .document_start) break;
    }
    var item_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer item_arena.deinit();
    try testing.expectError(error.AliasBudgetExceeded, er.materialize(item_arena.allocator()));
}

test "cross-check snapshot: explicit flag and absolute span tracked" {
    // A stream with an explicit document marker: the document_start event's
    // explicit flag must be true and its span must point at the `---` bytes.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "---\nvalue: 42\n";
    var r: std.Io.Reader = .fixed(src);
    var er = EventReader.fromReader(a, &r, .{});
    defer er.deinit();

    var found_doc_start = false;
    while (try er.next()) |ev| {
        if (ev.kind == .document_start) {
            found_doc_start = true;
            // The explicit flag must be true (the `---` marker is present).
            try testing.expect(ev.explicit);
            // The span must point at the `---` bytes in `src`.
            try testing.expect(ev.span.start < ev.span.end);
        }
    }
    try testing.expect(found_doc_start);
}

test "EventReader.materialize: rejected after advancing past document_start" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // materialize() is valid ONLY immediately after document_start. Advancing
    // one event further (into the mapping) must make it error.YamlParseError.
    const src = "a: 1\nb: 2\n";
    var r: std.Io.Reader = .fixed(src);
    var er = EventReader.fromReader(a, &r, .{});
    defer er.deinit();

    // Advance to document_start, then one event past it.
    while (try er.next()) |ev| {
        if (ev.kind == .document_start) break;
    }
    _ = try er.next(); // advance into the document (mapping_start)

    var item_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer item_arena.deinit();
    try testing.expectError(error.YamlParseError, er.materialize(item_arena.allocator()));
}

test "EventReader.materialize: rejected before any document_start" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // No next() yet (not even stream_start consumed): no open document.
    const src = "a: 1\n";
    var r: std.Io.Reader = .fixed(src);
    var er = EventReader.fromReader(a, &r, .{});
    defer er.deinit();

    var item_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer item_arena.deinit();
    try testing.expectError(error.YamlParseError, er.materialize(item_arena.allocator()));

    // After only stream_start, still not at a document_start.
    _ = try er.next(); // stream_start
    try testing.expectError(error.YamlParseError, er.materialize(item_arena.allocator()));
}

test "EventReader.materialize: captures diagnostic on compose error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A document with an undefined alias: composes to error. With an errors
    // sink set, materialize() must capture+rebase the diagnostic so
    // diagnostic() reports it afterward (mirrors next()).
    const src = "---\nkey: *missing\n";
    var errs: std.ArrayList(Diagnostic) = .empty;
    var r: std.Io.Reader = .fixed(src);
    var er = EventReader.fromReader(a, &r, .{ .errors = &errs });
    defer er.deinit();
    while (try er.next()) |ev| {
        if (ev.kind == .document_start) break;
    }
    var item_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer item_arena.deinit();
    try testing.expectError(error.YamlParseError, er.materialize(item_arena.allocator()));
    try testing.expect(er.diagnostic() != null);
}

test "ValueStream/materialize: options.spans is ignored, map stays empty" {
    // Streaming value paths must NOT populate spans: entries and path keys
    // would be allocated from the per-item arena, which the documented
    // `item_arena.reset(.retain_capacity)` pattern frees, dangling the
    // caller's persistent map. The map must stay untouched (and thus own
    // nothing item_arena-backed) across resets.
    const src = "first: hello\n---\nsecond: world\n";

    var spans: value.Spans = .empty;
    defer spans.deinit(testing.allocator);

    // ValueStream path, with the documented per-item reset between docs.
    {
        var r: std.Io.Reader = .fixed(src);
        var vs = ValueStream.fromReader(testing.allocator, &r, .{ .spans = &spans });
        defer vs.deinit();

        var item_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer item_arena.deinit();

        var docs: usize = 0;
        while (try vs.next(item_arena.allocator())) |_| {
            docs += 1;
            _ = item_arena.reset(.retain_capacity);
        }
        try testing.expectEqual(@as(usize, 2), docs);
        try testing.expectEqual(@as(u32, 0), spans.count());
    }

    // materialize path.
    {
        var r: std.Io.Reader = .fixed(src);
        var er = EventReader.fromReader(testing.allocator, &r, .{ .spans = &spans });
        defer er.deinit();

        var item_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer item_arena.deinit();

        while (try er.next()) |ev| {
            if (ev.kind != .document_start) continue;
            _ = try er.materialize(item_arena.allocator());
            _ = item_arena.reset(.retain_capacity);
        }
        try testing.expectEqual(@as(u32, 0), spans.count());
    }
}

test "ValueStream: bad middle document is terminal when errors is null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // doc 1 good, doc 2 has an undefined alias (compose error), doc 3 good.
    // Without an errors sink, the error must be terminal: the following good
    // document must NOT be silently yielded on a retry.
    const src = "---\ngood1: 1\n---\nbad: *missing\n---\ngood3: 3\n";
    var r: std.Io.Reader = .fixed(src);
    var vs = ValueStream.fromReader(a, &r, .{});
    defer vs.deinit();

    var item_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer item_arena.deinit();

    // doc 1 ok
    const v1 = (try vs.next(item_arena.allocator())) orelse return error.ExpectedDoc1;
    try testing.expectEqual(@as(i128, 1), v1.get("good1").?.int);
    _ = item_arena.reset(.retain_capacity);

    // doc 2 errors
    try testing.expectError(error.YamlParseError, vs.next(item_arena.allocator()));

    // Retry must NOT advance to doc 3: the stream is terminal after the error.
    try testing.expectEqual(@as(?value.Value, null), try vs.next(item_arena.allocator()));
}

test "ValueStream: bad middle document recovers when errors sink is set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // doc 1 good, doc 2 has an undefined alias (compose error), doc 3 good.
    // With an errors sink, the stream recovers per-document -- matching
    // parseStream's behavior: good docs before and after the bad one are
    // accessible, and the error is surfaced on the bad doc's next() call.
    const src = "---\ngood1: 1\n---\nbad: *missing\n---\ngood3: 3\n";
    var errs: std.ArrayList(Diagnostic) = .empty;
    var r: std.Io.Reader = .fixed(src);
    var vs = ValueStream.fromReader(a, &r, .{ .errors = &errs });
    defer vs.deinit();

    var item_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer item_arena.deinit();

    // doc 1 ok
    const v1 = (try vs.next(item_arena.allocator())) orelse return error.ExpectedDoc1;
    try testing.expectEqual(@as(i128, 1), v1.get("good1").?.int);
    _ = item_arena.reset(.retain_capacity);

    // doc 2 errors -- the error is surfaced but the stream is NOT terminated.
    try testing.expectError(error.YamlParseError, vs.next(item_arena.allocator()));
    // The caller's persistent sink is never grown from the per-item arena;
    // the diagnostic surfaces through reader-owned memory instead, so it
    // stays valid across the documented reset.
    try testing.expectEqual(@as(usize, 0), errs.items.len);
    const d = vs.inner.diagnostic() orelse return error.ExpectedDiagnostic;
    _ = item_arena.reset(.retain_capacity);
    try testing.expect(std.mem.indexOf(u8, d.message, "anchor") != null or d.message.len > 0);

    // doc 3 is accessible -- the stream recovered past the bad document.
    const v3 = (try vs.next(item_arena.allocator())) orelse return error.ExpectedDoc3;
    try testing.expectEqual(@as(i128, 3), v3.get("good3").?.int);

    // Stream exhausted.
    try testing.expectEqual(@as(?value.Value, null), try vs.next(item_arena.allocator()));
}

test "ValueStream: trailing whitespace yields exactly one document then null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The trailing whitespace-only line is NOT a second (null) document: it
    // carries no document_start, so it is end of stream.
    const src = "key: val\n   \n";
    var r: std.Io.Reader = .fixed(src);
    var vs = ValueStream.fromReader(a, &r, .{});
    defer vs.deinit();

    var count: usize = 0;
    while (try vs.next(a)) |v| {
        try testing.expectEqualStrings("val", v.get("key").?.string);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "ValueStream: advances past content-less doc-end frames (count matches buffered)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A bare `...` (leading, doubled, or between documents) frames a content-
    // less document_end that composes to no Value. ValueStream must skip it and
    // continue, not terminate the stream and drop following documents. The
    // buffered composer and EventReader are the oracles for the true count.
    const cases = [_][]const u8{
        "...\na: 1\n",
        "a: 1\n...\n...\nb: 2\n",
        "---\na: 1\n...\n...\n---\nb: 2\n",
        "...\n...\nonly: doc\n",
        "x: 1\n...\n",
    };

    for (cases) |src| {
        const buffered = try composer.parseStream(a, src, .{});

        var r: std.Io.Reader = .fixed(src);
        var vs = ValueStream.fromReader(a, &r, .{});
        defer vs.deinit();
        var streamed: usize = 0;
        while (try vs.next(a)) |_| streamed += 1;

        const evs = try drainStreamWhole(a, src);
        var er_docs: usize = 0;
        for (evs) |ev| {
            if (ev.kind == .document_start) er_docs += 1;
        }

        testing.expectEqual(buffered.len, streamed) catch |e| {
            std.debug.print(
                "ValueStream count mismatch on {s}: buffered={d} stream={d}\n",
                .{ src, buffered.len, streamed },
            );
            return e;
        };
        try testing.expectEqual(buffered.len, er_docs);
    }
}

test "ValueStream: `...` end-marker line tail agrees with buffered parseStream" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A `...` end-marker frames a boundary only when its line tail is blank or a
    // comment. Streaming must reach the SAME verdict as the buffered oracle for
    // every case: same error-vs-success, and on success same doc count and
    // per-doc value. The stray-content cases are the regression: the streaming
    // framer used to split at `...` and silently swallow the trailing content.
    const cases = [_][]const u8{
        // Stray content after `...`: invalid, must not silently split.
        "---\nfoo: bar\n... x\n---\nbaz: qux\n",
        "foo: bar\n... x\n",
        // Comment or blank tail after `...`: a clean boundary (2 docs).
        "---\nfoo: bar\n... #c\n---\nbaz: qux\n",
        "---\nfoo: bar\n...\n---\nbaz: qux\n",
        "x: 1\n...\t\n",
        "x: 1\n...  \n",
        // `---` admits a node/comment on its own line; do not regress.
        "--- foo\n",
        "--- #c\nfoo: bar\n",
        // A `#` glued to `...` (no separating space) is an unseparated-comment
        // error, not a boundary; both paths must reject it identically.
        "---\nfoo: bar\n...#c\n---\nbaz: qux\n",
        // CRLF and EOF-without-trailing-newline variants of stray content.
        "---\r\nfoo: bar\r\n... x\r\n---\r\nbaz: qux\r\n",
        "---\nfoo: bar\n... x",
        // Bare `...` at EOF with no trailing newline: a clean final boundary.
        "x: 1\n...",
        // Comment tail after a trailing `...` at true EOF: still a clean final
        // boundary that must terminate (not spin on need_more), with/without a
        // closing newline.
        "x: 1\n... #c\n",
        "x: 1\n... #c",
        // A fourth dot makes `....` not a marker at all.
        "x: 1\n....\n",
    };

    for (cases) |src| {
        const buffered: ?[]value.Value = composer.parseStream(a, src, .{}) catch |e| blk: {
            try testing.expectEqual(error.YamlParseError, e);
            break :blk null;
        };

        var r: std.Io.Reader = .fixed(src);
        var vs = ValueStream.fromReader(a, &r, .{});
        defer vs.deinit();
        var streamed: std.ArrayList(value.Value) = .empty;
        var stream_err = false;
        while (true) {
            const item = vs.next(a) catch {
                stream_err = true;
                break;
            };
            const v = item orelse break;
            try streamed.append(a, v);
        }

        if (buffered) |docs| {
            testing.expect(!stream_err) catch |e| {
                std.debug.print("streaming errored but buffered ok on: {s}\n", .{src});
                return e;
            };
            testing.expectEqual(docs.len, streamed.items.len) catch |e| {
                std.debug.print("doc-count mismatch on {s}: buffered={d} stream={d}\n", .{ src, docs.len, streamed.items.len });
                return e;
            };
            for (docs, streamed.items) |bv, sv| {
                testing.expect(bv.eql(sv)) catch |e| {
                    std.debug.print("value mismatch on: {s}\n", .{src});
                    return e;
                };
            }
        } else {
            testing.expect(stream_err) catch |e| {
                std.debug.print("buffered errored but streaming succeeded on: {s}\n", .{src});
                return e;
            };
        }
    }
}

test "ValueStream: `...` tail straddling a pull boundary agrees with buffered" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A `...` marker whose line tail lands on the far side of a 4096-byte pull
    // boundary must still reach the SAME verdict as the buffered oracle. The
    // regression: the framer committed the `...` boundary at the raw buffer end
    // (a mid-pull stream_end, not true EOF) before the stray tail was pulled,
    // so `... x` split into phantom documents and swallowed the parse error.
    // The pad width slides the `... <tail>` across the first pull boundary;
    // 4084/4085 straddle it for this prefix, so the sweep must span them.
    var pad: usize = 4080;
    while (pad <= 4100) : (pad += 1) {
        const body = try a.alloc(u8, pad);
        @memset(body, 'a');

        // Stray same-line content after `...`: invalid in both paths.
        const stray = try std.fmt.allocPrint(a, "---\nk: {s}\n... x\n---\nsecond: 1\n", .{body});
        try expectStreamMatchesBuffered(a, stray);

        // Comment tail after `...`: a clean boundary; both frame two documents.
        const comment = try std.fmt.allocPrint(a, "---\nk: {s}\n... #c\n---\nsecond: 1\n", .{body});
        try expectStreamMatchesBuffered(a, comment);

        // Bare `...`: a clean boundary; both frame two documents.
        const bare = try std.fmt.allocPrint(a, "---\nk: {s}\n...\n---\nsecond: 1\n", .{body});
        try expectStreamMatchesBuffered(a, bare);
    }
}

/// Assert reader-backed `ValueStream` and buffered `parseStream` agree on
/// outcome (error vs success) and, on success, on document count and per-doc
/// deep-equal value. A stray-content input must ERROR on BOTH; a clean-tail
/// input must SUCCEED on both with identical documents.
fn expectStreamMatchesBuffered(a: std.mem.Allocator, src: []const u8) !void {
    const buffered: ?[]value.Value = composer.parseStream(a, src, .{}) catch |e| blk: {
        try testing.expectEqual(error.YamlParseError, e);
        break :blk null;
    };

    var r: std.Io.Reader = .fixed(src);
    var vs = ValueStream.fromReader(a, &r, .{});
    defer vs.deinit();
    var streamed: std.ArrayList(value.Value) = .empty;
    var stream_err = false;
    // Hard cap: a framing regression that spins would otherwise hang; the
    // inputs here yield at most two documents, so any run past the cap is a bug.
    var guard: usize = 0;
    while (guard < 64) : (guard += 1) {
        const item = vs.next(a) catch {
            stream_err = true;
            break;
        };
        const v = item orelse break;
        try streamed.append(a, v);
    }
    try testing.expect(guard < 64);

    if (buffered) |docs| {
        testing.expect(!stream_err) catch |e| {
            std.debug.print("streaming errored but buffered ok on len={d}\n", .{src.len});
            return e;
        };
        testing.expectEqual(docs.len, streamed.items.len) catch |e| {
            std.debug.print("doc-count mismatch len={d}: buffered={d} stream={d}\n", .{ src.len, docs.len, streamed.items.len });
            return e;
        };
        for (docs, streamed.items) |bv, sv| {
            try testing.expect(bv.eql(sv));
        }
    } else {
        testing.expect(stream_err) catch |e| {
            std.debug.print("buffered errored but streaming succeeded on len={d}\n", .{src.len});
            return e;
        };
    }
}

test "ValueStream: oversized boundary-free document fails fast with DocumentTooLarge" {
    var gpa_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer gpa_arena.deinit();
    const gpa = gpa_arena.allocator();

    // One long plain scalar with no `---`/`...` boundary, larger than a small
    // configured cap. The stream must reject it via the cap rather than buffer
    // it whole. The cap bounds memory to ~cap bytes, not the full input.
    const big = try gpa.alloc(u8, 64 * 1024);
    @memset(big, 'a');

    var r: std.Io.Reader = .fixed(big);
    var vs = ValueStream.fromReader(gpa, &r, .{ .max_document_bytes = 4096 });
    defer vs.deinit();

    var item_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer item_arena.deinit();
    try testing.expectError(error.DocumentTooLarge, vs.next(item_arena.allocator()));
}
