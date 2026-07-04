//! Composer: event stream -> typed `Value` tree.
//!
//! Drives `Parser.next()` and builds one `Value` per document, doing the
//! two jobs the event layer leaves open: scalar COOKING (unescaping
//! double-quoted text, collapsing single-quoted `''`, folding/chomping
//! block scalars) and schema RESOLUTION (mapping a plain scalar's text to
//! null/bool/int/float/string via the selected `Schema`).
//!
//! Structure is built with an explicit value stack rather than recursion:
//! the event stream is already flat, so each collection-start pushes a
//! frame that accumulates children until its matching end. `max_depth`
//! bounds the stack.
//!
//! Anchors, aliases, and merge keys: a `&name` anchor records its node in
//! a per-document table once the node is FULLY composed; a `*name` alias
//! resolves to a deep copy of that node (value semantics, no shared
//! pointers). Recording only completed nodes makes a self-referential
//! alias (`&x { b: *x }`) resolve against an absent anchor, rejecting
//! cycles. Each copied node spends one unit of `max_alias_nodes`, bounding
//! billion-laughs amplification. A `<<` merge key (when `merge_keys` is on)
//! pulls keys from its mapping value, or each mapping in its sequence
//! value, that the host mapping does not already define; local keys win,
//! and among sources earlier wins.
//!
//! Tags: a node's explicit tag forces or asserts its type. `!!str` keeps
//! a scalar a string (no schema resolution); `!!int`/`!!float`/`!!bool`/
//! `!!null` resolve via the schema predicate and error on mismatch;
//! `!!seq`/`!!map` assert the collection kind and error on mismatch;
//! scalar-type tags (`!!str`/`!!int`/etc.) on a collection are an error.
//! Unknown/local tags (`!foo`, `!<uri>`) on either a scalar or a
//! collection are kept/ignored without error.
//!
//! Memory: everything lands in the caller's arena. A plain scalar that
//! schema-resolves to a string is zero-copy: the returned `.string` slice
//! points directly into the source buffer (ev.value is already a source
//! slice). A cooked scalar (quoted or block) is arena-allocated. Non-string
//! resolutions (int/bool/null/float) own no heap storage.

const std = @import("std");

const value = @import("value.zig");
const schema = @import("schema.zig");
const scanner = @import("scanner.zig");
const parser = @import("parser.zig");
const diagnostic = @import("diagnostic.zig");

const Value = value.Value;
const Entry = value.Entry;
const Spans = value.Spans;
const Span = value.Span;
const Schema = schema.Schema;
const ScalarStyle = scanner.ScalarStyle;
const Chomp = scanner.Chomp;
const BlockHeader = scanner.BlockHeader;
const Event = parser.Event;
const Parser = parser.Parser;
const Sink = diagnostic.Sink;

/// One collected parse error: message, source span, and an optional
/// "did you mean" suggestion. See `diagnostic.zig`.
pub const Diagnostic = diagnostic.Diagnostic;

pub const ParseOptions = struct {
    /// When non-null, the composer appends each error and continues via
    /// recovery (parsing resumes at the next document marker), so a single
    /// pass reports every recoverable error in the stream. Returns
    /// `error.YamlParseError` at the end if any errors were collected; the
    /// partially-built tree is discarded, only the diagnostics survive.
    /// When null, the parser bails on the first error with no diagnostic
    /// captured and zero allocation overhead.
    ///
    /// Ownership: the appended entries, their messages/suggestions, AND the
    /// list's backing buffer are all allocated from the parse arena. Deinit
    /// the list with that arena's allocator, or simply drop it when the
    /// arena frees; deinit-ing with any other allocator is invalid, and the
    /// diagnostics dangle once the parse arena is freed.
    /// Streaming value paths (`ValueStream.next`, `EventReader.materialize`)
    /// never grow this list -- entries would be backed by the per-item arena
    /// the caller resets between documents. There, setting a sink still opts
    /// into per-document recovery, and the most recent diagnostic is exposed
    /// via the reader's `diagnostic()` in reader-owned memory.
    errors: ?*std.ArrayList(Diagnostic) = null,
    /// When non-null, populated with one Span per emitted Value, keyed by
    /// dotted path. The root value's path is the empty string `""`;
    /// sequence elements use `[N]` index segments; a mapping value's
    /// segment is its KEY. Only string-keyed mapping entries are
    /// addressable, so entries with a non-scalar-string key record no
    /// span for their value (consistent with `Value.get`). An aliased
    /// value records the span of the alias USE SITE (the `*name` event),
    /// since that is where the value textually appears. Path keys are
    /// arena-allocated and live as long as the value tree. When null,
    /// no path is maintained and there is zero allocation overhead.
    ///
    /// The map stores u64 byte offsets, so any in-memory input is addressable
    /// without a size cap.
    ///
    /// Populated by buffered parses only: the streaming value paths
    /// (`ValueStream.next`, `EventReader.materialize`) ignore this option,
    /// because their entries would be allocated from the per-item arena the
    /// caller resets between documents and would dangle in this map.
    spans: ?*Spans = null,
    /// Decode-layer option consumed by `parseInto`/`decode`: when true, a
    /// mapping key with no corresponding target field is skipped instead of
    /// raising `error.UnknownField`. The `Value`-tree parse itself does not
    /// consult it.
    ignore_unknown_fields: bool = false,
    schema: Schema = .core,
    /// When true (the default), a plain untagged `<<` mapping key triggers
    /// merge semantics: its mapping or sequence-of-mappings value is merged
    /// into the enclosing map, with locally defined keys winning over merged
    /// ones. When false, `<<` is treated as an ordinary string key.
    merge_keys: bool = true,
    max_depth: usize = 128,
    /// Maximum number of Value nodes that may be produced by alias expansion
    /// across the entire parse. Each node deep-copied while resolving an alias
    /// spends one unit; exhaustion returns error.AliasBudgetExceeded. At roughly
    /// 50-100 bytes of arena cost per node, 1,000,000 caps expansion at
    /// roughly 50-100 MB for untrusted input. Raise for trusted, deeply aliased
    /// inputs; lower (e.g. 100,000) for fuzz harnesses.
    max_alias_nodes: usize = 1_000_000,
    /// Maximum byte length a single document may occupy in a reader-backed
    /// stream (`EventReader`/`ValueStream`). A document is buffered whole before
    /// it is parsed, so an unbounded single document (e.g. one giant scalar with
    /// no `---`/`...` boundary) would buffer until memory is exhausted. When the
    /// buffered first document reaches this cap with no boundary in sight, the
    /// stream fails fast with `error.DocumentTooLarge` instead of growing the
    /// buffer further. `0` disables the cap (unbounded). The default 256 MiB is
    /// generous for configuration/data documents while still bounding a hostile
    /// boundary-free input. The in-memory `parse`/`parseStream` paths ignore this
    /// field -- their input is already fully resident.
    max_document_bytes: usize = 256 * 1024 * 1024,
};

pub const Error = error{
    YamlParseError,
    NestingTooDeep,
    AliasBudgetExceeded,
} || std.mem.Allocator.Error;

/// Compose exactly one document. Zero or more than one document is an
/// error; for a possibly-empty or multi-document stream use `parseStream`.
///
/// Any in-memory input is addressable: the spans map and the value tree carry
/// u64 byte offsets, so there is no input-size cap.
pub fn parse(arena: std.mem.Allocator, src: []const u8, options: ParseOptions) Error!Value {
    const docs = try parseStream(arena, src, options);
    if (docs.len != 1) {
        var sink = Sink.init(arena, options.errors);
        return sink.failFmt(
            .{ .start = 0, .end = 0 },
            "expected exactly one document, found {d}",
            .{docs.len},
        );
    }
    return docs[0];
}

/// Compose every document in the stream into a `Value` (zero or more).
pub fn parseStream(arena: std.mem.Allocator, src: []const u8, options: ParseOptions) Error![]Value {
    var c: Composer = .{
        .arena = arena,
        .options = options,
        .p = Parser.init(arena, src),
        .sink = Sink.init(arena, options.errors),
        .alias_budget = options.max_alias_nodes,
    };
    defer c.p.deinit();
    if (options.errors != null) c.p.setSink(&c.sink);
    return c.run();
}

/// An entry inside a mapping frame, carrying whether it was introduced by
/// a plain untagged `<<` key so applyMergeKeys can act on it without
/// re-inspecting string content that has already lost style information.
const MappingEntry = struct {
    entry: Entry,
    is_merge: bool,
};

/// A pending collection on the build stack: a sequence accumulates child
/// values; a mapping accumulates entries, holding a key between the key
/// node and its value node.
const Frame = struct {
    kind: enum { seq, map },
    seq: std.ArrayList(Value) = .empty,
    map: std.ArrayList(MappingEntry) = .empty,
    /// For a mapping: the key composed but awaiting its value, if any.
    pending_key: ?Value = null,
    /// Whether the pending key was a plain untagged `<<` scalar. Only
    /// meaningful when pending_key is non-null and the parent is a mapping.
    pending_key_is_merge: bool = false,
    /// Anchor name on the collection-start event, recorded into the anchor
    /// table only once the collection is fully composed (on its end event).
    anchor: ?[]const u8 = null,
    /// Path length to restore when this collection's frame is popped (the
    /// length before this collection's own segment was appended). Only
    /// maintained when `options.spans` is set.
    path_restore: usize = 0,
};

pub const Composer = struct {
    arena: std.mem.Allocator,
    options: ParseOptions,
    p: Parser,
    sink: Sink,
    stack: std.ArrayList(Frame) = .empty,
    /// Dotted path of the node currently being composed (e.g.
    /// "server.port"; empty at the root). Built from mapping-key and
    /// `[N]` index segments. Only maintained when `options.spans` is set.
    current_path: std.ArrayList(u8) = .empty,
    /// Span of the most recently seen event. Composer-level errors that
    /// have no token of their own (e.g. tag mismatch, alias) point here.
    last_span: Span = .{ .start = 0, .end = 0 },
    /// Anchor name -> fully-composed node. Per-document scoped: cleared at
    /// each document boundary. An anchor is recorded only after its subtree
    /// is fully composed, so an alias to an anchor still under construction
    /// finds nothing (cycle rejection).
    anchors: std.StringHashMapUnmanaged(Value) = .empty,
    /// Remaining alias-expansion budget. Each node deep-copied while
    /// resolving an alias spends one unit; exhaustion bounds amplification
    /// (billion-laughs). Counts across the whole parse, not per document.
    alias_budget: usize = 0,

    /// Composer-level error funnel. Routes through the shared sink so the
    /// parser, scanner, and composer all account into one `error_count`.
    fn fail(self: *Composer, span: Span, msg: []const u8) Error {
        return self.sink.fail(span, msg);
    }

    /// Funnel an error at the most recently seen event's span.
    fn failHere(self: *Composer, msg: []const u8) Error {
        return self.sink.fail(self.last_span, msg);
    }

    /// Run the stream with per-document recovery. The granularity is one
    /// document: a recoverable error anywhere in a document records its
    /// diagnostic, discards the partial tree, skips to the next document
    /// boundary (`---`/`...`/stream end), and resumes on the following
    /// document. Errors == null bails on the first error (the funnel
    /// returns the bare error and recovery is gated off).
    fn run(self: *Composer) Error![]Value {
        var docs: std.ArrayList(Value) = .empty;
        // The event stream wraps content in stream_start ... stream_end and
        // each document in document_start ... document_end. A document holds
        // exactly one root node, possibly empty.
        while (true) {
            const ev = (self.p.next() catch |err| {
                try self.recover(err);
                continue;
            }) orelse break;
            switch (ev.kind) {
                .stream_start, .stream_end => {},
                .document_start => {
                    self.last_span = ev.span;
                    const doc = self.composeDocument() catch |err| {
                        try self.recover(err);
                        continue;
                    };
                    try docs.append(self.arena, doc);
                },
                .document_end => return self.fail(ev.span, "unexpected document end marker"),
                else => return self.fail(ev.span, "node outside a document"),
            }
        }
        // Recovered errors were each recorded at their origin; the stream
        // is reported as failed if any were collected this parse.
        if (self.sink.error_count > 0) return error.YamlParseError;
        return docs.items;
    }

    /// Recovery gate. Propagates the error unchanged when there is no
    /// error sink, the cap is reached, or the error is not recoverable
    /// (`NestingTooDeep`/`AliasBudgetExceeded`/allocation failure). When
    /// recoverable, resets the build stack and skips the parser to the
    /// next document boundary so `run` can resume.
    fn recover(self: *Composer, err: Error) Error!void {
        if (err != error.YamlParseError) return err;
        if (!self.sink.recoverable()) return err;
        self.stack.clearRetainingCapacity();
        self.p.recoverToDocumentBoundary();
    }

    /// Compose the single root node of the document just opened, consuming
    /// up to and including its `document_end`.
    fn composeDocument(self: *Composer) Error!Value {
        self.stack.clearRetainingCapacity();
        // Anchors are document-scoped: a new document starts with no anchors.
        self.anchors.clearRetainingCapacity();
        var root: ?Value = null;
        while (try self.p.next()) |ev| {
            self.last_span = ev.span;
            switch (ev.kind) {
                .document_end => {
                    if (self.stack.items.len != 0) return self.fail(ev.span, "unexpected document end mid-collection");
                    return root orelse .null;
                },
                else => {
                    const v = (try self.handleNode(ev)) orelse continue;
                    if (self.stack.items.len == 0) {
                        // Document-root node completed.
                        if (root != null) return self.fail(ev.span, "multiple root nodes in document");
                        root = v;
                    } else {
                        try self.attach(v);
                    }
                },
            }
        }
        return self.failHere("unexpected end of input mid-document");
    }

    /// Process one node-or-structure event. Returns a completed `Value`
    /// when the event finishes a node (a scalar, or a collection_end that
    /// pops a frame); returns null when the event only opens a collection
    /// (a frame was pushed) and there is nothing to attach yet.
    fn handleNode(self: *Composer, ev: Event) Error!?Value {
        switch (ev.kind) {
            .scalar => {
                const pos = try self.beginNode(ev.span);
                self.restorePath(pos);
                const v = try self.composeScalar(ev);
                if (ev.anchor) |name| try self.recordAnchor(name, v);
                // When this scalar will become a mapping key (top frame is a
                // map with no pending key yet), compute whether it is a plain
                // untagged `<<` and store the result so attach() can record it
                // alongside the entry. The decision is made here, before the
                // Value layer loses the style and tag information.
                if (self.stack.items.len > 0) {
                    const top = &self.stack.items[self.stack.items.len - 1];
                    if (top.kind == .map and top.pending_key == null) {
                        top.pending_key_is_merge = self.options.merge_keys and
                            ev.scalar_style == .plain and
                            ev.tag == null and
                            std.mem.eql(u8, ev.value, "<<");
                    }
                }
                return v;
            },
            .alias => {
                // The alias use site (`*name` event) is where the value
                // textually appears, so its span is recorded there.
                const pos = try self.beginNode(ev.span);
                self.restorePath(pos);
                // A re-anchored alias (`&y *x`) records the resolved value
                // under the new name so later `*y` references resolve.
                const v = try self.resolveAlias(ev);
                if (ev.anchor) |name| try self.recordAnchor(name, v);
                return v;
            },
            .sequence_start => {
                if (ev.tag) |raw| {
                    switch (classifyTag(raw)) {
                        // !!seq on a sequence: correct, allow.
                        .seq, .none, .other => {},
                        // !!map or any scalar-type tag on a sequence: mismatch.
                        .map, .str, .typed => return self.fail(ev.span, "tag does not match sequence"),
                    }
                }
                const pos = try self.beginNode(ev.span);
                try self.push(.{ .kind = .seq, .anchor = ev.anchor, .path_restore = pos.restore });
                return null;
            },
            .mapping_start => {
                if (ev.tag) |raw| {
                    switch (classifyTag(raw)) {
                        // !!map on a mapping: correct, allow.
                        .map, .none, .other => {},
                        // !!seq or any scalar-type tag on a mapping: mismatch.
                        .seq, .str, .typed => return self.fail(ev.span, "tag does not match mapping"),
                    }
                }
                const pos = try self.beginNode(ev.span);
                try self.push(.{ .kind = .map, .anchor = ev.anchor, .path_restore = pos.restore });
                return null;
            },
            .sequence_end => return try self.popCollection(ev.span, .seq),
            .mapping_end => return try self.popCollection(ev.span, .map),
            else => return self.fail(ev.span, "unexpected token"),
        }
    }

    fn push(self: *Composer, f: Frame) Error!void {
        if (self.stack.items.len >= self.options.max_depth) return error.NestingTooDeep;
        try self.stack.append(self.arena, f);
    }

    // Span path maintenance
    //
    // A node's path segment is decided by its parent frame at the moment the
    // node begins: a sequence element gets `[index]`, a mapping VALUE gets
    // its key (string keys only), the document root gets the empty path.
    // A mapping KEY and a value under a non-string key are not
    // string-addressable, so they record no span (mirrors `Value.get`).

    /// What a node about to be composed occupies in its parent.
    const NodePos = struct {
        /// Whether the node's span should be recorded (and its segment kept
        /// on the path while a collection's children compose).
        recordable: bool,
        /// Path length to restore once the node (and its subtree) is done.
        restore: usize,
    };

    /// Begin a node: append its path segment (when string-addressable) and
    /// return the position info. No-op returning a zeroed position when
    /// spans are off. Must be called before a collection-start pushes its
    /// frame, so the top frame still describes the PARENT.
    fn beginNode(self: *Composer, span: Span) Error!NodePos {
        if (self.options.spans == null) return .{ .recordable = false, .restore = 0 };
        const restore = self.current_path.items.len;
        if (self.stack.items.len == 0) {
            // Document root: path stays "" and is recordable.
            try self.recordSpan(span);
            return .{ .recordable = true, .restore = restore };
        }
        const f = &self.stack.items[self.stack.items.len - 1];
        switch (f.kind) {
            .seq => {
                try self.current_path.print(self.arena, "[{d}]", .{f.seq.items.len});
                try self.recordSpan(span);
                return .{ .recordable = true, .restore = restore };
            },
            .map => {
                if (f.pending_key) |k| {
                    // A mapping value: addressable only by a string key.
                    if (k == .string) {
                        if (restore > 0) try self.current_path.append(self.arena, '.');
                        try self.current_path.appendSlice(self.arena, k.string);
                        try self.recordSpan(span);
                        return .{ .recordable = true, .restore = restore };
                    }
                    return .{ .recordable = false, .restore = restore };
                }
                // A mapping key: never string-addressable as a value.
                return .{ .recordable = false, .restore = restore };
            },
        }
    }

    fn restorePath(self: *Composer, pos: NodePos) void {
        if (self.options.spans == null) return;
        self.current_path.shrinkRetainingCapacity(pos.restore);
    }

    /// Record `span` under the current path. The path is duped into the
    /// arena so it outlives the scratch buffer; a duplicate path (duplicate
    /// mapping key) overwrites, matching the tree's last-wins semantics.
    fn recordSpan(self: *Composer, span: Span) Error!void {
        const sm = self.options.spans orelse return;
        const path = try self.arena.dupe(u8, self.current_path.items);
        try sm.put(self.arena, path, span);
    }

    /// Pop the top frame, which must be of `kind`, and materialize it into a
    /// `Value`.
    fn popCollection(self: *Composer, span: Span, kind: @TypeOf(@as(Frame, undefined).kind)) Error!Value {
        if (self.stack.items.len == 0) return self.fail(span, "unmatched collection end");
        const f = self.stack.items[self.stack.items.len - 1];
        if (f.kind != kind) return self.fail(span, "mismatched collection end");
        _ = self.stack.pop();
        if (self.options.spans != null) self.current_path.shrinkRetainingCapacity(f.path_restore);
        const v: Value = switch (kind) {
            .seq => .{ .seq = f.seq.items },
            .map => blk: {
                if (f.pending_key != null) return self.fail(span, "mapping value missing for key");
                break :blk .{ .map = try self.applyMergeKeys(span, f.map.items) };
            },
        };
        if (f.anchor) |name| try self.recordAnchor(name, v);
        return v;
    }

    /// Attach a completed child value to the current top-of-stack frame: a
    /// sequence element, or a mapping key/value half.
    fn attach(self: *Composer, v: Value) Error!void {
        const f = &self.stack.items[self.stack.items.len - 1];
        switch (f.kind) {
            .seq => try f.seq.append(self.arena, v),
            .map => {
                if (f.pending_key) |k| {
                    try f.map.append(self.arena, .{
                        .entry = .{ .key = k, .value = v },
                        .is_merge = f.pending_key_is_merge,
                    });
                    f.pending_key = null;
                    f.pending_key_is_merge = false;
                } else {
                    f.pending_key = v;
                    // pending_key_is_merge is already set for this key;
                    // do not reset it here or the flag is lost before
                    // attach() completes the entry.
                }
            },
        }
    }

    // Anchors, aliases, merge keys

    /// Record a fully-composed node under its anchor name. A later
    /// re-definition of the same name overrides the earlier one, so
    /// subsequent aliases resolve to the most recent definition.
    fn recordAnchor(self: *Composer, name: []const u8, v: Value) Error!void {
        try self.anchors.put(self.arena, name, v);
    }

    /// Resolve an alias event to a deep copy of its anchored node. The
    /// anchor table holds only FULLY-composed nodes, so an alias to an
    /// anchor whose own subtree is still being built finds nothing -- that
    /// is how cycles (`&x { b: *x }`) are rejected. Each copied node spends
    /// one unit of the amplification budget.
    fn resolveAlias(self: *Composer, ev: Event) Error!Value {
        const target = self.anchors.get(ev.alias_name) orelse
            return self.fail(ev.span, "alias to undefined anchor");
        return try self.deepCopy(target);
    }

    /// Deep-copy a Value into the arena so the resulting tree shares no
    /// pointers with the anchored node (value semantics). Recurses through
    /// seq/map; each node copied decrements `alias_budget`, and exhaustion
    /// yields `error.AliasBudgetExceeded` to bound billion-laughs
    /// amplification. Recursion is bounded by the anchored subtree size,
    /// which is itself finite (anchors hold only completed, acyclic nodes).
    fn deepCopy(self: *Composer, v: Value) Error!Value {
        if (self.alias_budget == 0) return error.AliasBudgetExceeded;
        self.alias_budget -= 1;
        switch (v) {
            .null, .bool, .int, .float, .string => return v,
            .seq => |items| {
                const out = try self.arena.alloc(Value, items.len);
                for (items, 0..) |e, i| out[i] = try self.deepCopy(e);
                return .{ .seq = out };
            },
            .map => |entries| {
                const out = try self.arena.alloc(Entry, entries.len);
                for (entries, 0..) |e, i| out[i] = .{
                    .key = try self.deepCopy(e.key),
                    .value = try self.deepCopy(e.value),
                };
                return .{ .map = out };
            },
        }
    }

    /// Apply merge keys to a freshly-composed mapping's raw entries. Only
    /// entries flagged as merge (plain untagged `<<` key, determined at
    /// compose time before style info is lost) are treated as merge sources.
    /// All others are kept as ordinary entries. When `merge_keys` is off the
    /// entries pass through unchanged (the flag is never set in that mode).
    /// Multiple merge entries are all applied in document order; earlier
    /// sources win on key conflicts (local explicit keys always win).
    fn applyMergeKeys(self: *Composer, span: Span, raw: []MappingEntry) Error![]Entry {
        var has_merge = false;
        for (raw) |me| {
            if (me.is_merge) { has_merge = true; break; }
        }
        if (!has_merge) {
            const out = try self.arena.alloc(Entry, raw.len);
            for (raw, 0..) |me, i| out[i] = me.entry;
            return out;
        }

        var out: std.ArrayList(Entry) = .empty;
        // O(1)-membership mirror of `out`'s keys, so dedup stays O(N)
        // amortized instead of rescanning `out` per source entry. Keyed by
        // structural key identity (same predicate as the linear scan it
        // replaces); value is unused.
        var seen: std.HashMapUnmanaged(Value, void, KeyContext, std.hash_map.default_max_load_percentage) = .empty;

        // Explicit keys win over merge sources; collect them first.
        for (raw) |me| {
            if (!me.is_merge) {
                try out.append(self.arena, me.entry);
                try seen.put(self.arena, me.entry.key, {});
            }
        }

        // Earlier merge sources win on key conflicts; mergeFrom skips
        // keys already present in `seen`.
        for (raw) |me| {
            if (!me.is_merge) continue;
            switch (me.entry.value) {
                .map => |src| try self.mergeFrom(&out, &seen, src),
                .seq => |srcs| for (srcs) |s| switch (s) {
                    .map => |src| try self.mergeFrom(&out, &seen, src),
                    else => return self.fail(span, "merge value is not a mapping or sequence of mappings"),
                },
                else => return self.fail(span, "merge value is not a mapping or sequence of mappings"),
            }
        }
        return out.items;
    }

    /// Append entries from a merge source whose keys are not already present
    /// in `out` (membership tracked via `seen`). Key equality is structural
    /// over all Value kinds so that complex keys (e.g. sequences or nested
    /// mappings) are deduplicated the same way string keys are. Own keys win:
    /// a source key already present is silently dropped.
    fn mergeFrom(
        self: *Composer,
        out: *std.ArrayList(Entry),
        seen: *std.HashMapUnmanaged(Value, void, KeyContext, std.hash_map.default_max_load_percentage),
        src: []const Entry,
    ) Error!void {
        for (src) |e| {
            const gop = try seen.getOrPut(self.arena, e.key);
            if (gop.found_existing) continue;
            try out.append(self.arena, e);
        }
    }

    /// Hash/equality context for the merge-dedup set. `eql` defers to
    /// `Value.eql`; `hash` must agree with it, so float zeros and NaNs are
    /// canonicalized (Value.eql treats +0/-0 as equal and any two NaNs as
    /// equal).
    const KeyContext = struct {
        pub fn hash(_: KeyContext, key: Value) u64 {
            var h = std.hash.Wyhash.init(0);
            hashValue(&h, key);
            return h.final();
        }
        pub fn eql(_: KeyContext, a: Value, b: Value) bool {
            return a.eql(b);
        }
    };

    fn hashValue(h: *std.hash.Wyhash, v: Value) void {
        h.update(&[_]u8{@intFromEnum(std.meta.activeTag(v))});
        switch (v) {
            .null => {},
            .bool => |b| h.update(&[_]u8{@intFromBool(b)}),
            .int => |i| h.update(std.mem.asBytes(&i)),
            .float => |f| {
                const bits: u64 = if (std.math.isNan(f)) 0x7ff8000000000000 else if (f == 0) 0 else @bitCast(f);
                h.update(std.mem.asBytes(&bits));
            },
            .string => |s| h.update(s),
            .seq => |s| for (s) |e| hashValue(h, e),
            .map => |m| for (m) |e| {
                hashValue(h, e.key);
                hashValue(h, e.value);
            },
        }
    }

    // Scalar cooking + resolution

    pub fn composeScalar(self: *Composer, ev: Event) Error!Value {
        // A block scalar whose first content line is less indented than a
        // preceding all-blank line has ambiguous indentation: reject it.
        if (ev.block_header) |h| {
            if (h.leading_overindent) return self.fail(ev.span, "block scalar content less indented than a leading empty line");
        }

        const tag = if (ev.tag) |t| classifyTag(t) else Tag.none;

        const cooked: []const u8 = switch (ev.scalar_style) {
            // A plain scalar spanning multiple lines folds its breaks the
            // same way a flow scalar does (lone break -> space, blank lines
            // -> newlines, per-line surrounding white space trimmed). A
            // single-line plain scalar has no break, so the fold is a no-op
            // returning the source slice unchanged (zero-copy preserved).
            .plain => try foldFlowBreaks(self.arena, ev.value),
            .single => try self.cookSingle(ev.value),
            .double => try self.cookDouble(ev.value),
            .literal => try self.cookBlock(ev.value, ev.block_header orelse .{}, false),
            .folded => try self.cookBlock(ev.value, ev.block_header orelse .{}, true),
        };

        // Quoted and block styles are always strings; only a plain,
        // untagged scalar is schema-resolved.
        const quoted = ev.scalar_style != .plain;

        return switch (tag) {
            .none => if (quoted)
                .{ .string = cooked }
            else blk: {
                const resolved = try schema.resolve(self.options.schema, self.arena, cooked);
                // A plain scalar that resolves to .string keeps the cooked
                // text rather than the schema's dup: for a single-line scalar
                // `cooked` IS the source slice (fold was a no-op), preserving
                // zero-copy; for a folded multi-line scalar it is the folded
                // arena string, which the schema would have duped anyway.
                break :blk if (resolved == .string) .{ .string = cooked } else resolved;
            },
            .str => .{ .string = cooked },
            .typed => |want| try self.resolveTyped(want, cooked),
            // !!seq / !!map on a scalar is a structural mismatch.
            .seq, .map => error.YamlParseError,
            // Unknown/local tags: keep the cooked string.
            .other => .{ .string = cooked },
        };
    }

    /// Resolve a scalar under an explicit core type tag, erroring if the
    /// content does not match that type's predicate.
    fn resolveTyped(self: *Composer, want: Typed, content: []const u8) Error!Value {
        const v = try schema.resolve(.core, self.arena, content);
        const ok = switch (want) {
            .int => v == .int,
            .float => v == .float,
            .bool => v == .bool,
            .null => v == .null,
        };
        if (!ok) return self.failHere("scalar does not match its type tag");
        return v;
    }

    /// Single-quoted: line breaks fold per the flow rule (a single break
    /// between content becomes a space, blank lines become newlines, and
    /// surrounding white space is trimmed); the only escape is `''` -> `'`.
    /// Always a string.
    fn cookSingle(self: *Composer, raw: []const u8) Error![]const u8 {
        const folded = try foldFlowBreaks(self.arena, raw);
        if (std.mem.indexOfScalar(u8, folded, '\'') == null) return folded;
        var out = try std.ArrayList(u8).initCapacity(self.arena, folded.len);
        var i: usize = 0;
        while (i < folded.len) : (i += 1) {
            out.appendAssumeCapacity(folded[i]);
            if (folded[i] == '\'' and i + 1 < folded.len and folded[i + 1] == '\'') i += 1;
        }
        return out.items;
    }

    /// Double-quoted: line breaks fold per the flow rule, a `\`-at-end-of-
    /// line is an explicit line continuation (the break and the next line's
    /// indent are dropped), then the full YAML escape set is applied with
    /// `\u`/`\U`/`\x` numeric escapes (incl. surrogate pairs) encoded to
    /// UTF-8. Always a string.
    fn cookDouble(self: *Composer, input: []const u8) Error![]const u8 {
        // Fold flow line breaks first, marking each `\`-escaped backslash so
        // the folder does not mistake a `\` that precedes a real break for a
        // continuation it should consume. The folder leaves escapes intact.
        const raw = try foldFlowBreaksDouble(self.arena, input);
        var out = try std.ArrayList(u8).initCapacity(self.arena, raw.len);
        var i: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            if (c != '\\') {
                try out.append(self.arena, c);
                i += 1;
                continue;
            }
            i += 1;
            if (i >= raw.len) return self.failHere("dangling backslash in double-quoted scalar"); // dangling backslash
            const e = raw[i];
            i += 1;
            switch (e) {
                '0' => try out.append(self.arena, 0x00),
                'a' => try out.append(self.arena, 0x07),
                'b' => try out.append(self.arena, 0x08),
                't' => try out.append(self.arena, 0x09),
                'n' => try out.append(self.arena, 0x0A),
                'v' => try out.append(self.arena, 0x0B),
                'f' => try out.append(self.arena, 0x0C),
                'r' => try out.append(self.arena, 0x0D),
                'e' => try out.append(self.arena, 0x1B),
                ' ' => try out.append(self.arena, 0x20),
                // A backslash before a literal tab escapes the tab (the YAML
                // reference accepts `\<TAB>` as a tab, mirroring escaped space).
                '\t' => try out.append(self.arena, 0x09),
                '"' => try out.append(self.arena, '"'),
                '/' => try out.append(self.arena, '/'),
                '\\' => try out.append(self.arena, '\\'),
                'N' => try self.appendCodepoint(&out, 0x85),
                '_' => try self.appendCodepoint(&out, 0xA0),
                'L' => try self.appendCodepoint(&out, 0x2028),
                'P' => try self.appendCodepoint(&out, 0x2029),
                'x' => i = try self.cookHexEscape(&out, raw, i, 2),
                'u' => i = try self.cookHexEscape(&out, raw, i, 4),
                'U' => i = try self.cookHexEscape(&out, raw, i, 8),
                else => return self.failHere("unknown escape in double-quoted scalar"), // unknown escape
            }
        }
        return out.items;
    }

    /// Decode `width` hex digits at `raw[i..]`, encode the codepoint to
    /// UTF-8, and return the new index. `\u` high surrogates pair with a
    /// following `\uXXXX` low surrogate.
    ///
    /// YAML requires exactly `width` ASCII hex digits [0-9A-Fa-f]. Signs,
    /// underscores, and any other characters accepted by std.fmt.parseInt
    /// are rejected here as malformed escapes.
    fn cookHexEscape(self: *Composer, out: *std.ArrayList(u8), raw: []const u8, i: usize, width: usize) Error!usize {
        if (i + width > raw.len) return self.failHere("truncated numeric escape in double-quoted scalar");
        const field = raw[i .. i + width];
        for (field) |b| {
            if (!std.ascii.isHex(b)) return self.failHere("invalid hex in numeric escape");
        }
        const cp = std.fmt.parseInt(u32, field, 16) catch return self.failHere("invalid hex in numeric escape");
        const pos = i + width;

        if (width == 4 and cp >= 0xD800 and cp <= 0xDBFF) {
            // High surrogate: expect `\uXXXX` low surrogate to follow.
            if (pos + 6 <= raw.len and raw[pos] == '\\' and raw[pos + 1] == 'u') {
                const lo_field = raw[pos + 2 .. pos + 6];
                for (lo_field) |b| {
                    if (!std.ascii.isHex(b)) return self.failHere("invalid hex in numeric escape");
                }
                const lo = std.fmt.parseInt(u32, lo_field, 16) catch return self.failHere("invalid hex in numeric escape");
                if (lo >= 0xDC00 and lo <= 0xDFFF) {
                    const combined = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    try self.appendCodepoint(out, combined);
                    return pos + 6;
                }
            }
            return self.failHere("lone high surrogate in numeric escape"); // lone high surrogate
        }
        if (cp >= 0xD800 and cp <= 0xDFFF) return self.failHere("lone surrogate in numeric escape"); // lone/low surrogate
        try self.appendCodepoint(out, cp);
        return pos;
    }

    /// Literal/folded block scalar. The scanner's body span runs from the
    /// first body byte to the start of the terminating line, carrying every
    /// body line (including trailing blank lines) with original indentation
    /// intact; `header.content_indent` is the absolute column to strip. We
    /// strip that indentation, fold (folded only), then apply chomping.
    ///
    /// Folding rule (folded only): a single line break between two non-empty
    /// EQUALLY-indented lines folds to a space; blank lines become literal
    /// newlines; a "more-indented" line (one that keeps extra indentation
    /// after the strip) and the breaks adjacent to it are kept literal.
    fn cookBlock(self: *Composer, body: []const u8, header: BlockHeader, folded: bool) Error![]const u8 {
        if (body.len == 0) return "";

        const indent: usize = header.content_indent;

        // Split into lines and strip the block indentation. `over` marks a
        // "more-indented" content line (extra leading white space survived
        // the strip), which suppresses folding.
        const Line = struct { text: []const u8, blank: bool, over: bool };
        var lines: std.ArrayList(Line) = .empty;
        var it = LineIterator.init(body);
        while (it.next()) |raw| {
            // After the strip an empty remainder is an empty line; remaining
            // leading white space marks "more-indented" content.
            const stripped = stripIndent(raw, indent);
            const blank = stripped.len == 0;
            const over = !blank and (stripped[0] == ' ' or stripped[0] == '\t');
            try lines.append(self.arena, .{ .text = stripped, .blank = blank, .over = over });
        }

        // The body always ends at a line break, so the final split element is
        // an empty tail; drop it so it does not count as a trailing blank.
        if (lines.items.len > 0 and lines.items[lines.items.len - 1].text.len == 0)
            _ = lines.pop();

        // The index just past the last non-blank line. Lines beyond it are
        // trailing blanks whose breaks chomping governs.
        var last_content: usize = 0;
        for (lines.items, 0..) |ln, i| {
            if (!ln.blank) last_content = i + 1;
        }

        var out: std.ArrayList(u8) = .empty;
        if (!folded) {
            // Literal: every line is kept verbatim, joined by its own break.
            var i: usize = 0;
            while (i < last_content) : (i += 1) {
                if (i != 0) try out.append(self.arena, '\n');
                try out.appendSlice(self.arena, lines.items[i].text);
            }
        } else {
            // Folded: join consecutive non-empty lines. Between content lines
            // A and B with L line breaks (L = 1 + blank lines between):
            //   - both "flow" (not more-indented) and L == 1 -> one space
            //     (the single break folds);
            //   - both flow with L >= 2            -> L-1 newlines (one fold);
            //   - either A or B more-indented      -> L newlines (the break
            //     introducing/leaving the more-indented region is literal).
            var i: usize = 0;
            var prev_over = false;
            var emitted_content = false;
            var pending_blanks: usize = 0;
            while (i < last_content) : (i += 1) {
                const ln = lines.items[i];
                if (ln.blank) {
                    pending_blanks += 1;
                    continue;
                }
                if (!emitted_content) {
                    // Leading blank lines each contribute a literal newline.
                    var k: usize = 0;
                    while (k < pending_blanks) : (k += 1) try out.append(self.arena, '\n');
                } else {
                    const breaks = pending_blanks + 1;
                    const more_indented = prev_over or ln.over;
                    const newlines: usize = if (more_indented)
                        breaks
                    else if (breaks == 1)
                        0 // a lone flow break folds to a space
                    else
                        breaks - 1;
                    if (newlines == 0) {
                        try out.append(self.arena, ' ');
                    } else {
                        var k: usize = 0;
                        while (k < newlines) : (k += 1) try out.append(self.arena, '\n');
                    }
                }
                try out.appendSlice(self.arena, ln.text);
                pending_blanks = 0;
                emitted_content = true;
                prev_over = ln.over;
            }
        }

        if (last_content == 0) {
            // No content lines: only `keep` retains the blank lines as breaks.
            if (header.chomp == .keep) {
                var n = lines.items.len;
                while (n > 0) : (n -= 1) try out.append(self.arena, '\n');
            }
            return out.items;
        }

        // Trailing line breaks: `strip` keeps none, `clip` keeps exactly one
        // (the last content line's own break), `keep` keeps that break plus
        // one per trailing blank line.
        switch (header.chomp) {
            .strip => {},
            .clip => try out.append(self.arena, '\n'),
            .keep => {
                const trailing_blanks = lines.items.len - last_content;
                var n = trailing_blanks + 1;
                while (n > 0) : (n -= 1) try out.append(self.arena, '\n');
            },
        }
        return out.items;
    }

    /// Encode `cp` to UTF-8 and append it. An out-of-range codepoint
    /// (e.g. `\U00110000`) is a malformed escape.
    fn appendCodepoint(self: *Composer, out: *std.ArrayList(u8), cp: u32) Error!void {
        if (cp > 0x10FFFF) return self.failHere("codepoint out of range in numeric escape");
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(cp), &buf) catch return self.failHere("invalid codepoint in numeric escape");
        try out.appendSlice(self.arena, buf[0..n]);
    }
};

/// Cook a single scalar EVENT to its presentation text: unescape a
/// double-quoted scalar, collapse a single-quoted `''`, fold+chomp a
/// block scalar; a plain scalar passes through unchanged. Returns the
/// cooked bytes (the suite's `=VAL` text, before any schema resolution).
/// Shares the exact production cooking via a throwaway `Composer`, so the
/// text matches what `parse` would store. `src` must be the full source
/// buffer the event's spans index into. Intended for the conformance
/// event serializer and round-trip tooling.
pub fn cookScalarText(arena: std.mem.Allocator, src: []const u8, ev: Event) Error![]const u8 {
    var c: Composer = .{
        .arena = arena,
        .options = .{},
        .p = Parser.init(arena, src),
        .sink = Sink.init(arena, null),
    };
    defer c.p.deinit();
    return switch (ev.scalar_style) {
        .plain => foldFlowBreaks(arena, ev.value),
        .single => c.cookSingle(ev.value),
        .double => c.cookDouble(ev.value),
        .literal => c.cookBlock(ev.value, ev.block_header orelse .{}, false),
        .folded => c.cookBlock(ev.value, ev.block_header orelse .{}, true),
    };
}

/// True for the white space characters YAML trims around a folded flow
/// line break: space and tab.
fn isFlowSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// Splits `buf` on any YAML line break -- `\n`, `\r\n`, or a lone `\r` --
/// each counting as exactly one boundary (YAML 1.2.2 section 5.4), so a
/// scalar's folded content is identical however its source line breaks are
/// styled. Returned lines never include the break bytes. Mirrors
/// `std.mem.SplitIterator(u8, .scalar)`'s trailing-empty-line semantics: a
/// buffer ending in a break yields one final empty line.
const LineIterator = struct {
    buf: []const u8,
    pos: ?usize,

    fn init(buf: []const u8) LineIterator {
        return .{ .buf = buf, .pos = 0 };
    }

    fn next(self: *LineIterator) ?[]const u8 {
        const start = self.pos orelse return null;
        var i = start;
        while (i < self.buf.len and self.buf[i] != '\n' and self.buf[i] != '\r') i += 1;
        if (i >= self.buf.len) {
            self.pos = null;
        } else if (self.buf[i] == '\r' and i + 1 < self.buf.len and self.buf[i + 1] == '\n') {
            self.pos = i + 2;
        } else {
            self.pos = i + 1;
        }
        return self.buf[start..i];
    }

    fn peek(self: *LineIterator) ?[]const u8 {
        const saved = self.pos;
        defer self.pos = saved;
        return self.next();
    }
};

/// Fold the line breaks of a single-quoted flow scalar. A run of N line
/// breaks between content folds to N-1 line breaks, except a single break
/// folds to one space (the YAML flow rule); leading and trailing flow
/// white space on each interior line is trimmed. No break in the input is
/// a fast no-op.
fn foldFlowBreaks(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, raw, "\n\r") == null) return raw;
    var out: std.ArrayList(u8) = .empty;
    var lines = LineIterator.init(raw);
    var first = true;
    // Breaks accumulated since the last emitted content line: 1 for the
    // line break itself, +1 per intervening blank line.
    var breaks: usize = 0;
    while (lines.next()) |line| {
        // The final split element is the line bearing the closing quote: a
        // terminator, not content. When blank it ends the trailing break run
        // without adding a break of its own; when it carries content that
        // content is the scalar's last segment.
        const is_last = lines.peek() == null;
        var s: usize = 0;
        var e: usize = line.len;
        if (!first) while (s < e and isFlowSpace(line[s])) : (s += 1) {};
        // Trailing white space is flow padding before a line break, dropped;
        // on the terminator line (before the closing quote) it is significant
        // content and kept.
        if (!is_last) while (e > s and isFlowSpace(line[e - 1])) : (e -= 1) {};
        const content = line[s..e];

        if (content.len == 0 and !first and !is_last) {
            // A blank interior line: defer, counting an extra break.
            breaks += 1;
            continue;
        }
        if (first) {
            try out.appendSlice(arena, content);
            first = false;
        } else {
            // A run of `breaks` line breaks folds to a single space, or to
            // one newline per break past the first. Applies uniformly to an
            // interior separator and to the trailing run before the close.
            try appendFoldedBreaks(&out, arena, breaks);
            try out.appendSlice(arena, content);
        }
        breaks = 1;
    }
    return out.items;
}

/// Emit the folding of a run of `breaks` line breaks: one space for a single
/// break, otherwise one newline per break past the first (the YAML flow
/// folding rule, shared by single- and double-quoted scalars).
fn appendFoldedBreaks(out: *std.ArrayList(u8), arena: std.mem.Allocator, breaks: usize) !void {
    if (breaks <= 1) {
        try out.append(arena, ' ');
    } else {
        var k: usize = 1;
        while (k < breaks) : (k += 1) try out.append(arena, '\n');
    }
}

/// Fold the line breaks of a double-quoted flow scalar, leaving escapes
/// intact for the caller's escape pass. Two break kinds:
///   - a `\` at the end of a line's content is a line continuation: the
///     break and the next line's leading white space are dropped, and the
///     `\` is consumed here (it is not a content escape);
///   - any other break folds per the flow rule (single break -> space,
///     each extra break -> newline), trimming surrounding flow white space.
/// A run of backslashes decides continuation by parity: an odd count ends
/// in a live `\`, an even count is fully escaped pairs.
fn foldFlowBreaksDouble(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, raw, "\n\r") == null) return raw;
    var out: std.ArrayList(u8) = .empty;
    var lines = LineIterator.init(raw);
    var first = true;
    // Whether the previous emitted content line ended in a live `\`
    // continuation (its break and the next line's indent are dropped).
    var continued = false;
    // Breaks accumulated since the last emitted content line.
    var breaks: usize = 0;
    while (lines.next()) |line| {
        // The final split element bears the closing quote: a terminator, not
        // a content line. When blank it ends the trailing break run without
        // contributing a break of its own.
        const is_last = lines.peek() == null;
        var s: usize = 0;
        var e: usize = line.len;
        if (!first) while (s < e and isFlowSpace(line[s])) : (s += 1) {};
        // Trailing white space is flow padding before a break, dropped; on
        // the terminator line (before the closing quote) it is content, kept.
        if (!is_last) while (e > s and isFlowSpace(line[e - 1])) : (e -= 1) {};
        // A trailing whitespace char escaped by an odd run of backslashes
        // (`\<TAB>` / `\<space>` at line end) is content, not flow padding:
        // keep that one char so the escape pass can render it.
        if (e > s and e < line.len and isFlowSpace(line[e])) {
            var esc: usize = 0;
            while (e > s + esc and line[e - 1 - esc] == '\\') : (esc += 1) {}
            if (esc % 2 == 1) e += 1;
        }
        const content = line[s..e];

        if (content.len == 0 and !first and !continued and !is_last) {
            breaks += 1;
            continue;
        }

        if (first) {
            try out.appendSlice(arena, content);
            first = false;
        } else if (continued) {
            // Previous line's `\` consumed its break; just append.
            try out.appendSlice(arena, content);
        } else {
            try appendFoldedBreaks(&out, arena, breaks);
            try out.appendSlice(arena, content);
        }

        // A live trailing `\` (odd-length backslash run) is a continuation
        // marker, stripped here; an even run is escaped pairs, kept.
        var bs: usize = 0;
        while (bs < out.items.len and out.items[out.items.len - 1 - bs] == '\\') : (bs += 1) {}
        if (bs % 2 == 1) {
            out.shrinkRetainingCapacity(out.items.len - 1);
            continued = true;
            breaks = 0;
        } else {
            continued = false;
            breaks = 1;
        }
    }
    return out.items;
}

/// Remove up to `indent` leading spaces from a line. A line with fewer
/// leading spaces (a blank line) loses only what it has.
fn stripIndent(line: []const u8, indent: usize) []const u8 {
    var n: usize = 0;
    while (n < indent and n < line.len and line[n] == ' ') n += 1;
    return line[n..];
}

// Tag classification

const Typed = enum { int, float, bool, null };

const Tag = union(enum) {
    none,
    str,
    typed: Typed,
    seq,
    map,
    other,
};

/// Classify a raw tag slice (incl. its leading `!`) into the core kinds we
/// act on. Both the shorthand `!!x` and the resolved
/// `tag:yaml.org,2002:x` forms are recognized; anything else is `.other`.
fn classifyTag(raw: []const u8) Tag {
    const core_prefix = "tag:yaml.org,2002:";
    // Strip the verbatim wrapper `!<...>` to its inner URI first.
    var t = raw;
    if (std.mem.startsWith(u8, t, "!<") and std.mem.endsWith(u8, t, ">")) {
        t = t[2 .. t.len - 1];
    }
    const suffix = if (std.mem.startsWith(u8, t, "!!"))
        t[2..]
    else if (std.mem.startsWith(u8, t, core_prefix))
        t[core_prefix.len..]
    else
        return .other;

    if (std.mem.eql(u8, suffix, "str")) return .str;
    if (std.mem.eql(u8, suffix, "int")) return .{ .typed = .int };
    if (std.mem.eql(u8, suffix, "float")) return .{ .typed = .float };
    if (std.mem.eql(u8, suffix, "bool")) return .{ .typed = .bool };
    if (std.mem.eql(u8, suffix, "null")) return .{ .typed = .null };
    if (std.mem.eql(u8, suffix, "seq")) return .seq;
    if (std.mem.eql(u8, suffix, "map")) return .map;
    return .other;
}

/// Reader-input variants additionally surface the reader's allocation
/// failure path.
pub const ReaderError = Error || std.Io.Reader.LimitedAllocError;

/// Reader-input variant of `parse`. Pulls the full input into arena memory
/// first, then calls `parse` over it. A complete contiguous buffer is
/// required: zero-copy plain scalars slice into the drained buffer, and a
/// document is only valid once its final token is seen.
pub fn parseReader(arena: std.mem.Allocator, reader: *std.Io.Reader, options: ParseOptions) ReaderError!Value {
    const input = try reader.allocRemaining(arena, .unlimited);
    return parse(arena, input, options);
}

/// Reader-input variant of `parseStream`. Pulls the full input into arena
/// memory first, then calls `parseStream` over it.
pub fn parseStreamReader(arena: std.mem.Allocator, reader: *std.Io.Reader, options: ParseOptions) ReaderError![]Value {
    const input = try reader.allocRemaining(arena, .unlimited);
    return parseStream(arena, input, options);
}

// Tests

const testing = std.testing;

fn p(a: std.mem.Allocator, src: []const u8) !Value {
    return parse(a, src, .{});
}

test "multi-line plain scalar folds to spaces" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "key: line one\n  line two\n  line three\n", .{});
    try std.testing.expectEqualStrings("line one line two line three", v.getT([]const u8, "key").?);
}

test "multi-line plain scalar blank line becomes newline" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "key: para one\n\n  para two\n", .{});
    try std.testing.expectEqualStrings("para one\npara two", v.getT([]const u8, "key").?);
}

test "multi-line plain scalar with long indented lines folds correctly" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // Many continuation lines, each long: `plainContinues` derives the
    // continuation column FORWARD from the blank-skip walk. The prior
    // backward scan to the line start recomputed it per line, work that grows
    // with the indentation distance and is pure overhead. Drive a large input
    // (640k content bytes across 64 lines) so a reintroduced backward scan is
    // a measurable slowdown, and assert the fold is byte-for-byte correct so
    // the forward column matches what the backward scan produced.
    const line_len = 10_000;
    const lines = 64;
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "key: ");
    var li: usize = 0;
    while (li < lines) : (li += 1) {
        if (li != 0) try buf.appendSlice(a, "\n  "); // continuation indent
        try buf.appendNTimes(a, 'x', line_len);
    }
    try buf.append(a, '\n');

    const v = try parse(a, buf.items, .{});
    // Folded result: each line's x-run joined by single spaces.
    const got = v.getT([]const u8, "key").?;
    try std.testing.expectEqual(@as(usize, line_len * lines + (lines - 1)), got.len);
    for (got, 0..) |ch, idx| {
        const expect: u8 = if ((idx + 1) % (line_len + 1) == 0) ' ' else 'x';
        try std.testing.expectEqual(expect, ch);
    }
}

test "plain scalar value stays single-line when next line dedents" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "a: one\nb: two\n", .{});
    try std.testing.expectEqualStrings("one", v.getT([]const u8, "a").?);
    try std.testing.expectEqualStrings("two", v.getT([]const u8, "b").?);
}

test "top-level multi-line plain scalar" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "this is\na long\nplain scalar\n", .{});
    try std.testing.expectEqualStrings("this is a long plain scalar", v.string);
}

test "compose scalars with core schema" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try p(a, "n: 42\nf: 1.5\nb: true\nz: ~\ns: hi\n");
    try std.testing.expectEqual(@as(i64, 42), v.getT(i64, "n").?);
    try std.testing.expectEqual(@as(f64, 1.5), v.getT(f64, "f").?);
    try std.testing.expectEqual(true, v.getT(bool, "b").?);
    try std.testing.expect(v.get("z").? == .null);
    try std.testing.expectEqualStrings("hi", v.getT([]const u8, "s").?);
}

test "explicit ? key in a flow collection is not double-scanned" {
    // The explicit `?` emits the key indicator; the following scalar must not
    // be promoted to a second implicit key (`{? a : b}` is `{a: b}`, not a
    // doubled-key stream). PyYAML-verified expected values.
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    // `{? a : b}` -> {a: b}
    {
        const v = try p(a, "{? a : b}");
        try testing.expect(v == .map);
        try testing.expectEqual(@as(usize, 1), v.map.len);
        try testing.expectEqualStrings("a", v.map[0].key.string);
        try testing.expectEqualStrings("b", v.map[0].value.string);
    }
    // `[? a : b]` -> [{a: b}]
    {
        const v = try p(a, "[? a : b]");
        try testing.expect(v == .seq);
        try testing.expectEqual(@as(usize, 1), v.seq.len);
        try testing.expect(v.seq[0] == .map);
        try testing.expectEqualStrings("a", v.seq[0].map[0].key.string);
        try testing.expectEqualStrings("b", v.seq[0].map[0].value.string);
    }
    // `{? a: b, ? c: d}` -> {a: b, c: d}
    {
        const v = try p(a, "{? a: b, ? c: d}");
        try testing.expectEqualStrings("b", v.getT([]const u8, "a").?);
        try testing.expectEqualStrings("d", v.getT([]const u8, "c").?);
    }
    // `{? "a" : b}` -> {a: b} (quoted explicit key)
    {
        const v = try p(a, "{? \"a\" : b}");
        try testing.expectEqualStrings("b", v.getT([]const u8, "a").?);
    }
}

test "lone anchor or tag on an empty flow node is not dropped" {
    // A property with no following content in a flow collection decorates an
    // empty scalar; the entry must survive and its anchor must register so a
    // later alias resolves. PyYAML-verified expected values.
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    // `[&x]` / `[&x ]` -> [null]
    for ([_][]const u8{ "[&x]", "[&x ]" }) |src| {
        const v = try p(a, src);
        try testing.expect(v == .seq);
        try testing.expectEqual(@as(usize, 1), v.seq.len);
        try testing.expect(v.seq[0] == .null);
    }
    // `[&x, b]` -> [null, "b"]
    {
        const v = try p(a, "[&x, b]");
        try testing.expectEqual(@as(usize, 2), v.seq.len);
        try testing.expect(v.seq[0] == .null);
        try testing.expectEqualStrings("b", v.seq[1].string);
    }
    // `[a, &x ]` -> ["a", null]
    {
        const v = try p(a, "[a, &x ]");
        try testing.expectEqual(@as(usize, 2), v.seq.len);
        try testing.expectEqualStrings("a", v.seq[0].string);
        try testing.expect(v.seq[1] == .null);
    }
    // `[!!str ]` -> [""]  (tag forces an empty string, not null)
    {
        const v = try p(a, "[!!str ]");
        try testing.expectEqual(@as(usize, 1), v.seq.len);
        try testing.expect(v.seq[0] == .string);
        try testing.expectEqualStrings("", v.seq[0].string);
    }
    // `{&x }` -> {null: null}
    {
        const v = try p(a, "{&x }");
        try testing.expect(v == .map);
        try testing.expectEqual(@as(usize, 1), v.map.len);
        try testing.expect(v.map[0].key == .null);
        try testing.expect(v.map[0].value == .null);
    }
    // Cascade: the empty node's anchor registers, so a later alias resolves.
    // `a: [&x ]\nb: *x` -> {a: [null], b: null}
    {
        const v = try p(a, "a: [&x ]\nb: *x");
        const seq = v.get("a").?;
        try testing.expect(seq == .seq);
        try testing.expectEqual(@as(usize, 1), seq.seq.len);
        try testing.expect(seq.seq[0] == .null);
        try testing.expect(v.get("b").? == .null);
    }
}

test "compose nested block and flow" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const v = try p(ar.allocator(), "a:\n  - 1\n  - 2\nb: {c: 3}\n");
    try std.testing.expectEqual(@as(i64, 1), v.getT(i64, "a[0]").?);
    try std.testing.expectEqual(@as(i64, 3), v.getT(i64, "b.c").?);
}

test "double-quoted escapes are cooked" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const v = try p(ar.allocator(), "s: \"a\\nb\\u0041\\t\\\"\"\n");
    try std.testing.expectEqualStrings("a\nbA\t\"", v.getT([]const u8, "s").?);
}

test "backslash before a literal tab escapes the tab" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // `\<TAB>` mid-line is an escaped tab.
    const v = try p(a, "s: \"a\\\tb\"\n");
    try std.testing.expectEqualStrings("a\tb", v.getT([]const u8, "s").?);
    // `\<TAB>` at end of a folded line: the tab is kept, the break folds to a
    // space, the next line's indent is trimmed.
    const v2 = try p(a, "s: \"a\\\t\n    b\"\n");
    try std.testing.expectEqualStrings("a\t b", v2.getT([]const u8, "s").?);
}

test "single-quoted doubling" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const v = try p(ar.allocator(), "s: 'it''s ok'\n");
    try std.testing.expectEqualStrings("it's ok", v.getT([]const u8, "s").?);
}

test "quoted scalar trailing fold yields a trailing space" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // A single line break before the closing quote folds to one space, kept
    // as trailing content (not dropped as flow padding).
    try std.testing.expectEqualStrings("foo bar ", (try p(a, "s: \"foo\n  bar \"\n")).getT([]const u8, "s").?);
    try std.testing.expectEqualStrings("foo bar ", (try p(a, "s: 'foo\n  bar '\n")).getT([]const u8, "s").?);
}

test "quoted scalar whose only content is folded breaks" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // `'<break>  '`: one break between two empty lines folds to a single
    // space; extra blank lines each add a newline past the first break.
    try std.testing.expectEqualStrings(" ", (try p(a, "s: '\n  '\n")).getT([]const u8, "s").?);
    try std.testing.expectEqualStrings("\n", (try p(a, "s: '\n\n  '\n")).getT([]const u8, "s").?);
    try std.testing.expectEqualStrings("\n\n", (try p(a, "s: '\n\n\n  '\n")).getT([]const u8, "s").?);
}

test "literal block strips auto-detected indent, clip chomp" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "s: |\n  one\n  two\n", .{});
    try std.testing.expectEqualStrings("one\ntwo\n", v.getT([]const u8, "s").?);
}

test "literal more-indented line keeps extra indent" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "s: |\n  one\n    two\n  three\n", .{});
    try std.testing.expectEqualStrings("one\n  two\nthree\n", v.getT([]const u8, "s").?);
}

test "folded keeps newlines around more-indented lines" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // folded: equal-indent lines fold to space; more-indented block keeps literal newlines
    const v = try parse(a, "s: >\n  one\n  two\n    indented\n  three\n", .{});
    try std.testing.expectEqualStrings("one two\n  indented\nthree\n", v.getT([]const u8, "s").?);
}

test "chomp keep preserves trailing blanks" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "s: |+\n  x\n\n\n", .{});
    try std.testing.expectEqualStrings("x\n\n\n", v.getT([]const u8, "s").?);
}

test "explicit indent indicator" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "s: |2\n    four\n   three\n", .{});
    // strip exactly 2 cols: "  four\n three\n"
    try std.testing.expectEqualStrings("  four\n three\n", v.getT([]const u8, "s").?);
}

test "document marker terminates block scalar" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const docs = try parseStream(a, "s: |\n  body\n...\n", .{});
    try std.testing.expectEqual(@as(usize, 1), docs.len);
    try std.testing.expectEqualStrings("body\n", docs[0].getT([]const u8, "s").?);
}

test "literal and folded block scalars cook correctly" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const lit = try p(a, "s: |\n  line1\n  line2\n");
    try std.testing.expectEqualStrings("line1\nline2\n", lit.getT([]const u8, "s").?);
    const fold = try p(a, "s: >\n  line1\n  line2\n");
    try std.testing.expectEqualStrings("line1 line2\n", fold.getT([]const u8, "s").?);
    const strip = try p(a, "s: |-\n  x\n");
    try std.testing.expectEqualStrings("x", strip.getT([]const u8, "s").?);
    const keep = try p(a, "s: |+\n  x\n\n");
    try std.testing.expectEqualStrings("x\n\n", keep.getT([]const u8, "s").?);
}

test "line breaks: CRLF and lone CR normalize to LF (YAML 1.2.2 section 5.4)" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    // Plain multi-line scalar: folds to spaces regardless of break style.
    {
        const lf = try p(a, "key: line one\n  line two\n  line three\n");
        const crlf = try p(a, "key: line one\r\n  line two\r\n  line three\r\n");
        const cr = try p(a, "key: line one\r  line two\r  line three\r");
        try std.testing.expectEqualStrings("line one line two line three", lf.getT([]const u8, "key").?);
        try std.testing.expectEqualStrings(lf.getT([]const u8, "key").?, crlf.getT([]const u8, "key").?);
        try std.testing.expectEqualStrings(lf.getT([]const u8, "key").?, cr.getT([]const u8, "key").?);
    }

    // Double-quoted multi-line scalar: same fold rule as plain.
    {
        const lf = try p(a, "key: \"line one\n  line two\n  line three\"\n");
        const crlf = try p(a, "key: \"line one\r\n  line two\r\n  line three\"\r\n");
        const cr = try p(a, "key: \"line one\r  line two\r  line three\"\r");
        try std.testing.expectEqualStrings("line one line two line three", lf.getT([]const u8, "key").?);
        try std.testing.expectEqualStrings(lf.getT([]const u8, "key").?, crlf.getT([]const u8, "key").?);
        try std.testing.expectEqualStrings(lf.getT([]const u8, "key").?, cr.getT([]const u8, "key").?);
    }

    // Literal block scalar: line breaks preserved, but as LF, never raw CR.
    {
        const lf = try p(a, "key: |\n  line one\n  line two\n  line three\n");
        const crlf = try p(a, "key: |\r\n  line one\r\n  line two\r\n  line three\r\n");
        const cr = try p(a, "key: |\r  line one\r  line two\r  line three\r");
        try std.testing.expectEqualStrings("line one\nline two\nline three\n", lf.getT([]const u8, "key").?);
        try std.testing.expectEqualStrings(lf.getT([]const u8, "key").?, crlf.getT([]const u8, "key").?);
        try std.testing.expectEqualStrings(lf.getT([]const u8, "key").?, cr.getT([]const u8, "key").?);
    }

    // Folded block scalar: same fold rule as literal, plus space-folding.
    {
        const lf = try p(a, "key: >\n  line one\n  line two\n  line three\n");
        const crlf = try p(a, "key: >\r\n  line one\r\n  line two\r\n  line three\r\n");
        const cr = try p(a, "key: >\r  line one\r  line two\r  line three\r");
        try std.testing.expectEqualStrings("line one line two line three\n", lf.getT([]const u8, "key").?);
        try std.testing.expectEqualStrings(lf.getT([]const u8, "key").?, crlf.getT([]const u8, "key").?);
        try std.testing.expectEqualStrings(lf.getT([]const u8, "key").?, cr.getT([]const u8, "key").?);
    }

    // Simple mapping/sequence: structure parses identically under all three
    // line-break styles (a lone CR must still separate mapping entries).
    {
        const lf = try p(a, "a: 1\nb: 2\nseq:\n  - x\n  - y\n");
        const crlf = try p(a, "a: 1\r\nb: 2\r\nseq:\r\n  - x\r\n  - y\r\n");
        const cr = try p(a, "a: 1\rb: 2\rseq:\r  - x\r  - y\r");
        for ([_]Value{ lf, crlf, cr }) |v| {
            try std.testing.expectEqual(@as(i64, 1), v.getT(i64, "a").?);
            try std.testing.expectEqual(@as(i64, 2), v.getT(i64, "b").?);
            try std.testing.expectEqualStrings("x", v.getT([]const u8, "seq[0]").?);
            try std.testing.expectEqualStrings("y", v.getT([]const u8, "seq[1]").?);
        }
    }
}

test "quoted scalars are always strings, never schema-resolved" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const v = try p(ar.allocator(), "a: \"123\"\nb: 'true'\nc: 123\n");
    try std.testing.expectEqualStrings("123", v.getT([]const u8, "a").?);
    try std.testing.expectEqualStrings("true", v.getT([]const u8, "b").?);
    try std.testing.expectEqual(@as(i64, 123), v.getT(i64, "c").?);
}

test "explicit tag forces type" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const v = try p(ar.allocator(), "s: !!str 123\n");
    try std.testing.expectEqualStrings("123", v.getT([]const u8, "s").?);
}

test "parse requires exactly one document; parseStream allows many" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try std.testing.expectError(error.YamlParseError, parse(a, "---\na: 1\n---\nb: 2\n", .{}));
    const docs = try parseStream(a, "---\na: 1\n---\nb: 2\n", .{});
    try std.testing.expectEqual(@as(usize, 2), docs.len);
    try std.testing.expectEqual(@as(i64, 2), docs[1].getT(i64, "b").?);
}

test "parse with errors sink records a diagnostic for zero or multiple documents" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    // Zero documents: whitespace-only input.
    {
        var errs: std.ArrayList(Diagnostic) = .empty;
        try std.testing.expectError(error.YamlParseError, parse(a, "   \n", .{ .errors = &errs }));
        try std.testing.expectEqual(@as(usize, 1), errs.items.len);
        try std.testing.expectEqualStrings("expected exactly one document, found 0", errs.items[0].message);
    }

    // Two documents.
    {
        var errs: std.ArrayList(Diagnostic) = .empty;
        try std.testing.expectError(error.YamlParseError, parse(a, "a: 1\n---\nb: 2\n", .{ .errors = &errs }));
        try std.testing.expectEqual(@as(usize, 1), errs.items.len);
        try std.testing.expectEqualStrings("expected exactly one document, found 2", errs.items[0].message);
    }
}

test "plain string scalar is zero-copy into source" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const src = "key: plainvalue\n";
    const v = try parse(ar.allocator(), src, .{});
    const s = v.getT([]const u8, "key").?;
    const base = @intFromPtr(src.ptr);
    const got = @intFromPtr(s.ptr);
    try std.testing.expect(got >= base and got < base + src.len); // points into src
    try std.testing.expectEqualStrings("plainvalue", s);
}

test "collection tag mismatch errors" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try std.testing.expectError(error.YamlParseError, parse(a, "x: !!seq {a: 1}\n", .{}));
    try std.testing.expectError(error.YamlParseError, parse(a, "x: !!map [1, 2]\n", .{}));
    try std.testing.expectError(error.YamlParseError, parse(a, "x: !!str [1, 2]\n", .{}));
}

test "matching collection tag is accepted" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "x: !!seq [1, 2]\n", .{});
    try std.testing.expectEqual(@as(i64, 1), v.getT(i64, "x[0]").?);
    const w = try parse(a, "x: !!map {a: 1}\n", .{});
    try std.testing.expectEqual(@as(i64, 1), w.getT(i64, "x.a").?);
}

test "explicit block key scalar" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "? key\n: value\n", .{});
    try std.testing.expectEqualStrings("value", v.getT([]const u8, "key").?);
}

test "explicit key mixed with implicit entries" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "a: 1\n? b\n: 2\nc: 3\n", .{});
    try std.testing.expectEqual(@as(i64, 1), v.getT(i64, "a").?);
    try std.testing.expectEqual(@as(i64, 2), v.getT(i64, "b").?);
    try std.testing.expectEqual(@as(i64, 3), v.getT(i64, "c").?);
}

test "explicit key with no value is null" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "? lonely\n", .{});
    try std.testing.expect(v.get("lonely").? == .null);
}

test "explicit key that is a sequence" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // a complex (sequence) key; not string-addressable, but must compose
    // without error and have 1 entry
    const v = try parse(a, "? - a\n  - b\n: mapped\n", .{});
    try std.testing.expect(v == .map);
    try std.testing.expectEqual(@as(usize, 1), v.map.len);
    try std.testing.expect(v.map[0].key == .seq);
    try std.testing.expectEqualStrings("mapped", v.map[0].value.string);
}

test "collects multiple errors in one pass" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(a);
    // two bad documents in a stream: each has a malformed scalar/quote
    const src = "a: \"unterminated\n";
    const r = parse(a, src, .{ .errors = &errs });
    try std.testing.expectError(error.YamlParseError, r);
    try std.testing.expect(errs.items.len >= 1);
    try std.testing.expect(errs.items[0].span.lineCol(src).line >= 1);
}

test "renderRich renders a caret line" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(a);
    const src = "a: \"oops\n";
    _ = parse(a, src, .{ .errors = &errs }) catch {};
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try errs.items[0].renderRich(&aw.writer, src);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "^") != null);
}

test "null errors bails on first error" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    try std.testing.expectError(error.YamlParseError, parse(ar.allocator(), "a: \"oops\n", .{}));
}

test "reused errors list across parses: clean parse after failed one succeeds" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(a);
    _ = parse(a, "a: \"oops\n", .{ .errors = &errs }) catch {};
    const v = try parse(a, "a: 1\n", .{ .errors = &errs }); // must SUCCEED despite errs non-empty
    try std.testing.expectEqual(@as(i64, 1), v.getT(i64, "a").?);
}

test "recovery collects one error per broken document across a stream" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(a);
    // Two documents, each with a tab used for indentation. The error is
    // line-local (unlike a greedy unterminated quote), so per-document
    // recovery skips to the `---` boundary and the second document's error
    // is also diagnosed in one pass.
    const src = "a: 1\n\tb: 2\n---\nc: 3\n\td: 4\n";
    const r = parseStream(a, src, .{ .errors = &errs });
    try std.testing.expectError(error.YamlParseError, r);
    try std.testing.expectEqual(@as(usize, 2), errs.items.len);
    try std.testing.expect(errs.items[1].span.lineCol(src).line > errs.items[0].span.lineCol(src).line);
    try std.testing.expectEqualStrings("found tab used for indentation", errs.items[0].message);
}

/// Drive the errors-sink recovery path under a hard iteration cap. Mirrors
/// `Composer.run`: pull events, recover on error, bounding the total
/// event+recovery iterations so a non-progressing recovery loop is caught
/// (`error.ParserRunaway`) rather than spinning unbounded. The scanner-level
/// `drainBoundedScan` test is the fast-failing guard for the scanner half of
/// this bug; this exercises the full errors-sink recovery and asserts it
/// completes with a bounded diagnostic count. Returns that count.
fn recoverBounded(a: std.mem.Allocator, src: []const u8, max_iters: usize) !usize {
    var errs: std.ArrayList(Diagnostic) = .empty;
    var c: Composer = .{
        .arena = a,
        .options = .{ .errors = &errs },
        .p = Parser.init(a, src),
        .sink = Sink.init(a, &errs),
    };
    defer c.p.deinit();
    c.p.setSink(&c.sink);
    var n: usize = 0;
    while (true) : (n += 1) {
        if (n > max_iters) return error.ParserRunaway;
        const ev = (c.p.next() catch |err| {
            try c.recover(err);
            continue;
        }) orelse break;
        switch (ev.kind) {
            .document_start => {
                c.last_span = ev.span;
                _ = c.composeDocument() catch |err| {
                    try c.recover(err);
                    continue;
                };
            },
            else => {},
        }
    }
    return errs.items.len;
}

test "error-sink recovery makes forward progress and does not hang" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // A flow collection glued to further same-line key/value framing
    // (`{}b: 1`) re-enters the nested-block-mapping rejection. Recovery must
    // make forward progress and finish with one diagnostic per document, not
    // loop. The cap bounds the drive so a regressed recovery loop reports
    // `ParserRunaway` rather than spinning unbounded.
    try std.testing.expectEqual(@as(usize, 1), try recoverBounded(a, "a: {}b: 1\n", 256));
    try std.testing.expectEqual(@as(usize, 1), try recoverBounded(a, "a: {}b: []\n", 256));
    try std.testing.expectEqual(@as(usize, 1), try recoverBounded(a, "tags: [x,y]\nempty_map: {}empty_seq: []\n", 256));
}

test "clean documents around a broken one still parse" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(a);
    // Middle document is broken; the recovered tree is discarded but the
    // stream still fails overall, recording exactly one diagnostic.
    const src = "a: 1\n---\nb: \"oops\n---\nc: 3\n";
    const r = parseStream(a, src, .{ .errors = &errs });
    try std.testing.expectError(error.YamlParseError, r);
    try std.testing.expectEqual(@as(usize, 1), errs.items.len);
}

test "alias expands to a copy of the anchored node" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const v = try parse(ar.allocator(),
        \\defaults: &d
        \\  timeout: 30
        \\  retries: 3
        \\prod:
        \\  timeout: 60
        \\dev: *d
    , .{});
    try std.testing.expectEqual(@as(i64, 30), v.getT(i64, "dev.timeout").?);
    try std.testing.expectEqual(@as(i64, 3), v.getT(i64, "dev.retries").?);
}

test "alias to a scalar" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const v = try parse(ar.allocator(), "a: &x 42\nb: *x\n", .{});
    try std.testing.expectEqual(@as(i64, 42), v.getT(i64, "b").?);
}

test "node properties on a mapping key attach to the key" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // `!!str a: b` -- the tag decorates the key `a`, not the mapping; sibling
    // keys at the tag's column stay in the same mapping.
    const v = try parse(a, "!!str a: b\nc: 2\n", .{});
    try std.testing.expectEqualStrings("b", v.getT([]const u8, "a").?);
    try std.testing.expectEqual(@as(i64, 2), v.getT(i64, "c").?);
    // An anchor on a key works in either property order with a tag.
    const v2 = try parse(a, "&k1 key: value\n", .{});
    try std.testing.expectEqualStrings("value", v2.getT([]const u8, "key").?);
}

test "properties split between a mapping and its first key" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // `&m !!map` decorate the mapping; `&k !!str key:` decorate the key, each
    // property set on its own line. The mapping anchor and the key anchor must
    // not be confused.
    const v = try parse(a, "&m !!map\n&k !!str key: val\n", .{});
    try std.testing.expectEqualStrings("val", v.getT([]const u8, "key").?);
    // Properties for one node split across two lines all decorate that node.
    const v2 = try parse(a, "outer: &anc\n !!map\n  a: b\n", .{});
    try std.testing.expectEqualStrings("b", v2.getT([]const u8, "outer.a").?);
}

test "an alias may be a mapping key" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "x: &a name\n*a : value\n", .{});
    try std.testing.expectEqualStrings("value", v.getT([]const u8, "name").?);
}

test "a value indicator may be separated from its key by blanks" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // Spaces before the `:` are valid for both quoted and plain keys.
    const v = try parse(a, "\"k\" : v\nplain   : w\n", .{});
    try std.testing.expectEqualStrings("v", v.getT([]const u8, "k").?);
    try std.testing.expectEqualStrings("w", v.getT([]const u8, "plain").?);
}

test "an alias node may not carry node properties" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // Per YAML 1.2, properties may not be specified for an alias node; an
    // anchor or tag glued onto `*name` is invalid.
    try std.testing.expectError(error.YamlParseError, parse(a, "a: &x 1\nb: &y *x\n", .{}));
    try std.testing.expectError(error.YamlParseError, parse(a, "a: &x 1\nb: !!str *x\n", .{}));
}

test "merge key merges mappings with override precedence" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const v = try parse(ar.allocator(),
        \\base: &b
        \\  a: 1
        \\  b: 2
        \\derived:
        \\  <<: *b
        \\  b: 20
        \\  c: 30
    , .{});
    try std.testing.expectEqual(@as(i64, 1), v.getT(i64, "derived.a").?); // from merge
    try std.testing.expectEqual(@as(i64, 20), v.getT(i64, "derived.b").?); // local wins
    try std.testing.expectEqual(@as(i64, 30), v.getT(i64, "derived.c").?);
    try std.testing.expectEqual(@as(?Value, null), v.get("derived.<<")); // << key removed
}

// Bounds merge-key resolution at O(N): a quadratic rescan of the growing
// output would take tens of seconds for this size, so the wall-clock guard
// fails loudly on a regression instead of merely running slow.
test "merge of a large map is linear, not quadratic" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const n: usize = 50_000;
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "base: &b\n");
    for (0..n) |i| try buf.print(a, "  k{d}: {d}\n", .{ i, i });
    try buf.appendSlice(a, "derived:\n  <<: *b\n  k0: 999\n");

    const start = std.Io.Timestamp.now(std.testing.io, .awake);
    const v = try parse(a, buf.items, .{});
    const elapsed_ns = start.durationTo(std.Io.Timestamp.now(std.testing.io, .awake)).nanoseconds;
    try std.testing.expect(elapsed_ns < 5 * std.time.ns_per_s);

    // Explicit key wins; merged keys come through; nothing duplicated.
    try std.testing.expectEqual(@as(i64, 999), v.getT(i64, "derived.k0").?);
    try std.testing.expectEqual(@as(i64, 1), v.getT(i64, "derived.k1").?);
    try std.testing.expectEqual(@as(i64, n - 1), v.getT(i64, "derived.k49999").?);
    try std.testing.expectEqual(n, v.get("derived").?.map.len);
}

test "merge_keys=false leaves << as a literal key" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const v = try parse(ar.allocator(),
        \\base: &b
        \\  a: 1
        \\derived:
        \\  <<: *b
    , .{ .merge_keys = false });
    try std.testing.expect(v.get("derived").? == .map);
    // the literal "<<" entry is present, unresolved -- assert by walking derived.map for a "<<" key
    const derived = v.get("derived").?;
    var found_merge_key = false;
    for (derived.map) |e| if (e.key == .string and std.mem.eql(u8, e.key.string, "<<")) {
        found_merge_key = true;
    };
    try std.testing.expect(found_merge_key);
}

test "alias cycle is rejected" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    try std.testing.expectError(error.YamlParseError, parse(ar.allocator(), "a: &x\n  b: *x\n", .{}));
}

test "alias to undefined anchor errors" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    try std.testing.expectError(error.YamlParseError, parse(ar.allocator(), "a: *nope\n", .{}));
}

test "spans recorded per dotted path" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var spans: Spans = .empty;
    const src = "server:\n  port: 8080\ntags:\n  - a\n  - b\n";
    const v = try parse(a, src, .{ .spans = &spans });
    const port = v.locate(spans, "server.port").?;
    try std.testing.expectEqual(@as(i64, 8080), port.value.int);
    try std.testing.expectEqualStrings("8080", src[port.span.start..port.span.end]);
    const b = v.locate(spans, "tags[1]").?;
    try std.testing.expectEqualStrings("b", src[b.span.start..b.span.end]);
}

test "spans map: offsets past 4 GiB record without truncation" {
    // Event.span carries u64 offsets, so recordSpan stores them straight
    // through. Verify an offset well past maxInt(u32) round-trips intact.
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var spans: Spans = .empty;
    var c = Composer{
        .arena = a,
        .options = .{ .spans = &spans },
        .p = Parser.init(a, "x"),
        .sink = Sink.init(a, null),
    };
    defer c.p.deinit();

    const past_4gib: u64 = @as(u64, std.math.maxInt(u32)) + 100;
    try c.recordSpan(.{ .start = past_4gib, .end = past_4gib + 4 });
    const s = spans.get("").?;
    try std.testing.expectEqual(past_4gib, s.start);
    try std.testing.expectEqual(past_4gib + 4, s.end);
}

test "spans: root, nested maps, and seq-of-maps paths" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var spans: Spans = .empty;
    const src = "a:\n  b:\n    c: 5\nm:\n  - k: v\n";
    _ = try parse(a, src, .{ .spans = &spans });
    // Root records under the empty path.
    try std.testing.expect(spans.get("") != null);
    const c = spans.get("a.b.c").?;
    try std.testing.expectEqualStrings("5", src[c.start..c.end]);
    const kv = spans.get("m[0].k").?;
    try std.testing.expectEqualStrings("v", src[kv.start..kv.end]);
}

test "spans: aliased value records the use-site span" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var spans: Spans = .empty;
    const src = "a: &x 42\nb: *x\n";
    _ = try parse(a, src, .{ .spans = &spans });
    const a_span = spans.get("a").?;
    const b = spans.get("b").?;
    // `b`'s span points at the `*x` use site (the alias name), distinct
    // from and after the `&x 42` definition that `a` records.
    try std.testing.expectEqualStrings("x", src[b.start..b.end]);
    try std.testing.expect(b.start > a_span.start);
    try std.testing.expectEqual(@as(u32, 2), b.lineCol(src).line);
}

test "spans: non-string-keyed entry value is not recorded" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var spans: Spans = .empty;
    // A flow sequence used as a mapping key: its value is not
    // string-addressable, so the value records no span.
    const src = "{[1, 2]: mapped}\n";
    _ = try parse(a, src, .{ .spans = &spans });
    // Root still recorded; the value under the seq key records nothing.
    try std.testing.expect(spans.get("") != null);
    var it = spans.iterator();
    while (it.next()) |e| {
        const sp = e.value_ptr.*;
        try std.testing.expect(!std.mem.eql(u8, src[sp.start..sp.end], "mapped"));
    }
}

test "spans: off by default leaves the path stack untouched" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // No spans option: the run must behave identically and allocate no path.
    const v = try parse(a, "a:\n  - 1\n  - 2\nb: {c: 3}\n", .{});
    try std.testing.expectEqual(@as(i64, 1), v.getT(i64, "a[0]").?);
}

test "alias amplification budget bounds billion laughs" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const bomb =
        \\a: &a ["x","x","x","x","x","x","x","x","x"]
        \\b: &b [*a,*a,*a,*a,*a,*a,*a,*a,*a]
        \\c: &c [*b,*b,*b,*b,*b,*b,*b,*b,*b]
        \\d: [*c,*c,*c,*c,*c,*c,*c,*c,*c]
    ;
    try std.testing.expectError(error.AliasBudgetExceeded, parse(ar.allocator(), bomb, .{ .max_alias_nodes = 1000 }));
}

test "parseReader equals parse" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "k:\n  - 1\n  - 2\n  - 3\n";
    var r: std.Io.Reader = .fixed(src);
    const v = try parseReader(a, &r, .{});
    try std.testing.expectEqual(@as(i64, 3), v.getT(i64, "k[2]").?);
}

test "parseReader: block scalar via reader" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "s: |\n  a\n  b\n";
    var r: std.Io.Reader = .fixed(src);
    const v = try parseReader(a, &r, .{});
    try std.testing.expectEqualStrings("a\nb\n", v.getT([]const u8, "s").?);
}

test "parseStreamReader: multi-document stream via reader" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "---\na: 1\n---\nb: 2\n";
    var r: std.Io.Reader = .fixed(src);
    const docs = try parseStreamReader(a, &r, .{});
    try std.testing.expectEqual(@as(usize, 2), docs.len);
    try std.testing.expectEqual(@as(i64, 1), docs[0].getT(i64, "a").?);
    try std.testing.expectEqual(@as(i64, 2), docs[1].getT(i64, "b").?);
}

test "double-quoted << is a literal key, not a merge key" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // double-quoted "<<" must be an ordinary string key, not trigger a merge
    const v = try parse(a, "base: &b {a: 1}\nd:\n  \"<<\": *b\n  c: 2\n", .{});
    const d = v.get("d").?;
    try std.testing.expect(d == .map);
    // the "<<" key must be present as a literal entry
    var found = false;
    for (d.map) |e| {
        if (e.key == .string and std.mem.eql(u8, e.key.string, "<<")) found = true;
    }
    try std.testing.expect(found);
    // c must also be present (not merged away)
    try std.testing.expectEqual(@as(i64, 2), v.getT(i64, "d.c").?);
    // a must NOT be merged (merge was not triggered)
    try std.testing.expect(v.getT(i64, "d.a") == null);
}

test "single-quoted << is a literal key, not a merge key" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "base: &b {a: 1}\nd:\n  '<<': *b\n  c: 2\n", .{});
    const d = v.get("d").?;
    try std.testing.expect(d == .map);
    var found = false;
    for (d.map) |e| {
        if (e.key == .string and std.mem.eql(u8, e.key.string, "<<")) found = true;
    }
    try std.testing.expect(found);
    try std.testing.expect(v.getT(i64, "d.a") == null);
}

test "tagged !!str << is a literal key, not a merge key" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "base: &b {a: 1}\nd:\n  !!str <<: *b\n  c: 2\n", .{});
    const d = v.get("d").?;
    try std.testing.expect(d == .map);
    var found = false;
    for (d.map) |e| {
        if (e.key == .string and std.mem.eql(u8, e.key.string, "<<")) found = true;
    }
    try std.testing.expect(found);
    try std.testing.expect(v.getT(i64, "d.a") == null);
}

test "plain << still triggers merge (regression guard)" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "base: &b {a: 1}\nd:\n  <<: *b\n  c: 2\n", .{});
    // plain untagged << merges: a should be present from merge source
    try std.testing.expectEqual(@as(i64, 1), v.getT(i64, "d.a").?);
    try std.testing.expectEqual(@as(i64, 2), v.getT(i64, "d.c").?);
    // the << key itself is removed
    const d = v.get("d").?;
    var found_merge_key = false;
    for (d.map) |e| {
        if (e.key == .string and std.mem.eql(u8, e.key.string, "<<")) found_merge_key = true;
    }
    try std.testing.expect(!found_merge_key);
}

test "two plain << in same mapping both applied" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // Both merge sources applied; earlier wins on key conflict
    const v = try parse(a, "<<: {a: 1}\n<<: {b: 2}\nc: 3\n", .{});
    try std.testing.expectEqual(@as(i64, 3), v.getT(i64, "c").?);
    try std.testing.expectEqual(@as(i64, 1), v.getT(i64, "a").?);
    try std.testing.expectEqual(@as(i64, 2), v.getT(i64, "b").?);
}

test "leading UTF-8 BOM is stripped: plain mapping" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // BOM before a plain mapping key: key must be "a", not BOM+"a"
    const v = try parse(a, "\xEF\xBB\xBFa: 1\n", .{});
    try std.testing.expectEqual(@as(i64, 1), v.getT(i64, "a").?);
}

test "leading UTF-8 BOM is stripped: document-start marker recognized" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // BOM before ---: the marker must be recognized, yielding one document
    const docs = try parseStream(a, "\xEF\xBB\xBF---\na: 1\n", .{});
    try std.testing.expectEqual(@as(usize, 1), docs.len);
    try std.testing.expectEqual(@as(i64, 1), docs[0].getT(i64, "a").?);
}

test "numeric escape: valid \\u, \\U, \\x still decode correctly" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "s: \"\\u0041\"\n", .{});
    try std.testing.expectEqualStrings("A", v.getT([]const u8, "s").?);
    const v2 = try parse(a, "s: \"\\x41\"\n", .{});
    try std.testing.expectEqualStrings("A", v2.getT([]const u8, "s").?);
    const v3 = try parse(a, "s: \"\\U00000041\"\n", .{});
    try std.testing.expectEqualStrings("A", v3.getT([]const u8, "s").?);
}

test "numeric escape: sign character is rejected" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try std.testing.expectError(error.YamlParseError, parse(a, "s: \"\\u+041A\"\n", .{}));
    try std.testing.expectError(error.YamlParseError, parse(a, "s: \"\\U+0000041\"\n", .{}));
    try std.testing.expectError(error.YamlParseError, parse(a, "s: \"\\x+A1\"\n", .{}));
}

test "numeric escape: underscore digit separator is rejected" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try std.testing.expectError(error.YamlParseError, parse(a, "s: \"\\u0_41\"\n", .{}));
}

test "numeric escape: sign in low-surrogate field is rejected" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // High surrogate D800 followed by a malformed low-surrogate field with sign
    try std.testing.expectError(error.YamlParseError, parse(a, "s: \"\\uD800\\u+DC00\"\n", .{}));
}

test "alias budget: default 1M limit fires on deep-bomb" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    // 6-level bomb: a=10, b=100, c=1K, d=10K, e=100K, f=1M+ nodes.
    // Expansion exceeds the default 1M budget.
    const bomb =
        \\a: &a ["x","x","x","x","x","x","x","x","x","x"]
        \\b: &b [*a,*a,*a,*a,*a,*a,*a,*a,*a,*a]
        \\c: &c [*b,*b,*b,*b,*b,*b,*b,*b,*b,*b]
        \\d: &d [*c,*c,*c,*c,*c,*c,*c,*c,*c,*c]
        \\e: &e [*d,*d,*d,*d,*d,*d,*d,*d,*d,*d]
        \\f: [*e,*e,*e,*e,*e,*e,*e,*e,*e,*e]
    ;
    try std.testing.expectError(error.AliasBudgetExceeded, parse(ar.allocator(), bomb, .{}));
}

test "merge dedup: complex key already present in receiver is not duplicated" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // Receiver has a sequence key [1,2]; merge source also provides [1,2].
    // The receiver's own value must win and no duplicate entry must appear.
    const src =
        \\defaults: &defaults
        \\  ? [1, 2]
        \\  : from_source
        \\result:
        \\  ? [1, 2]
        \\  : own_value
        \\  <<: *defaults
    ;
    const v = try parse(a, src, .{});
    const result = v.getT(Value, "result").?;
    // Count entries with key [1,2]: must be exactly one
    var count: usize = 0;
    for (result.map) |e| {
        if (e.key == .seq and e.key.seq.len == 2 and
            e.key.seq[0] == .int and e.key.seq[0].int == 1 and
            e.key.seq[1] == .int and e.key.seq[1].int == 2)
        {
            count += 1;
            // Own value wins
            try std.testing.expectEqualStrings("own_value", e.value.string);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "merge dedup: NaN-keyed entry in receiver is not duplicated by merge source" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // Build the merge scenario directly via Value/Entry to avoid the YAML
    // parse layer (NaN cannot be expressed as a plain scalar in core schema
    // without going through the float resolution path, which does not produce
    // a literal NaN from text in a way portable across schemas). We exercise
    // Value.eql and mergeFrom, which are the code paths the fix targets.
    var composer = Composer{
        .arena = a,
        .options = .{},
        .p = Parser.init(a, ""),
        .sink = Sink.init(a, null),
    };
    defer composer.p.deinit();

    const nan_key = Value{ .float = std.math.nan(f64) };
    // Receiver has one entry: {NaN: "own"}.
    var out: std.ArrayList(Entry) = .empty;
    try out.append(a, .{ .key = nan_key, .value = .{ .string = "own" } });
    var seen: std.HashMapUnmanaged(Value, void, Composer.KeyContext, std.hash_map.default_max_load_percentage) = .empty;
    try seen.put(a, nan_key, {});
    // Merge source also has {NaN: "merged"}.
    const src = [_]Entry{.{ .key = nan_key, .value = .{ .string = "merged" } }};
    // mergeFrom must skip the source entry because NaN == NaN structurally.
    try composer.mergeFrom(&out, &seen, &src);

    // Exactly one NaN-keyed entry; own value wins.
    var count: usize = 0;
    for (out.items) |e| {
        if (e.key == .float and std.math.isNan(e.key.float)) {
            count += 1;
            try std.testing.expectEqualStrings("own", e.value.string);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}
