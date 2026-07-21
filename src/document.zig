//! Lossless document model for YAML -- parse, edit, and emit.
//!
//! Unlike `yaml.parse`, which composes a typed `Value` and discards
//! comments, formatting, and original byte representations, `Document.parse`
//! keeps the source bytes alongside a structural node tree of byte ranges
//! built from the comment-aware scanner token stream. The tree records, per
//! editable position, the byte range a `set`/`remove` targets, so emitting
//! an unmodified `Document` reproduces the input byte-for-byte and an
//! edited one differs only where edited.
//!
//! All allocations go through the arena passed to `parse`; calling
//! `arena.deinit()` releases everything. There is no `Document.deinit`.
//! Each non-batched edit retains a full new source/tree generation in the
//! arena, so memory and time grow with edit count. For a many-edit session,
//! `beginBatch`/`commitBatch` accumulate splices and reparse ONCE at commit;
//! for long-lived sessions, periodically emit and re-parse into a fresh arena.
//!
//! Multi-document streams: the node tree spans every document. `get`/`getT`
//! read through the FIRST document's composed `Value` (the common
//! single-document access pattern); `emit` reproduces the whole stream.
//!
//! `set` on a path whose intermediate mapping(s) are also missing creates
//! them too, as a single block-mapping chain appended at the first missing
//! key, indented one level deeper per nesting level (matching the sibling
//! indentation where the chain starts). Only mappings are ever created this
//! way: sequence elements can still only be replaced, never created, so a
//! `[N]` anywhere in the missing tail (including as the leaf itself) stays
//! `error.PathNotFound`, unchanged from before.
//!
//! `Document.empty` bootstraps a document with no source bytes at all (a
//! not-yet-created file): reads see nothing, and the first `set` splices the
//! root mapping and the whole requested path in one shot. `Document.parse`
//! still requires well-formed YAML -- an empty input still composes to its
//! usual (non-mapping) root, same as `yaml.parse`; `empty` is the dedicated
//! entry point for the "file may not exist yet" case.
//!
//! `setValueSegments` / `setSegments` / `removeSegments` take a path as
//! pre-split segments (`&.{ "host", "example.com" }`) instead of a dotted
//! string, so a key containing a literal `.` is addressed unambiguously
//! (each segment is a literal key, never re-split on `.` or `[...]`). `set`
//! / `setValue` / `remove` still take dotted string paths and split them
//! into segments the same way (`PathIterator`) before doing the same work,
//! so a dot-free path behaves identically either way.
//!
//! ```zig
//! var doc = try yaml.Document.parse(arena, src, .{});
//! const port = doc.getT(u16, "server.port").?;
//! var aw: std.Io.Writer.Allocating = .init(gpa);
//! defer aw.deinit();
//! try doc.emit(&aw.writer);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const yaml = @import("yaml.zig");
const value_mod = @import("value.zig");
const scanner_mod = @import("scanner.zig");
const composer = @import("composer.zig");
const emitter = @import("emitter.zig");

const Value = value_mod.Value;
const Span = value_mod.Span;
const Scanner = scanner_mod.Scanner;
const Token = scanner_mod.RawToken;
const TokenKind = scanner_mod.TokenKind;
const Segment = value_mod.PathIterator.Segment;

pub const Error = error{
    PathNotFound,
    InvalidValue,
    InvalidComment,
    NestingTooDeep,
    ConflictingEdits,
} || Allocator.Error;

/// One recorded splice in a batch: replace `source[start..end)` with
/// `replacement`. Offsets address the PRE-batch source, so they are applied in
/// descending `start` order at commit (a higher splice never shifts a lower
/// one's offsets).
const PendingEdit = struct { start: usize, end: usize, replacement: []const u8 };

/// A half-open byte range `[start, end)` into the document's `source`.
/// usize offsets index any in-memory buffer without a size cap.
pub const Span2 = struct { start: usize, end: usize };

/// Presentation style of a scalar node, mirroring the scanner. Drives how
/// `outer` (the editable envelope) is computed from `content` (the inner
/// value bytes the scanner points at).
const ScalarStyle = scanner_mod.ScalarStyle;

/// One node in the source: its byte ranges plus structure. Mapping and
/// sequence nodes hold child nodes; scalars are leaves.
///
/// `outer` is the full presentation envelope -- the bytes a `set`/`remove`
/// splices and `emit` reproduces. `content` is the inner value bytes a read
/// decodes from and matching consults: for a double/single-quoted scalar
/// `content` excludes the surrounding quotes; for a `|`/`>` block scalar
/// `content` is the body and `outer` runs from the header indicator through
/// the body; for a plain scalar and every collection the two coincide.
const Node = struct {
    /// The byte range an edit replaces (the whole scalar/collection text,
    /// quotes and block header included).
    outer: Span2,
    /// The inner value bytes a read decodes from / matches on.
    content: Span2,
    style: ScalarStyle = .plain,
    data: union(enum) {
        scalar,
        mapping: std.ArrayList(Member),
        sequence: std.ArrayList(*Node),
    },
};

/// One `key: value` pair inside a mapping node.
///
/// `key.decoded` is the canonical key identity -- the unescaped/cooked bytes a
/// lookup compares against, decoded once at build time so reads and writes
/// share one notion of "which key". `key.outer` is the original key token
/// (quotes included) so emit and anchoring reproduce the source spelling.
/// `sep_end` is the byte just past the `:` value indicator (when present), the
/// anchor an empty value's edit splices at.
const Member = struct {
    key: struct {
        decoded: []const u8,
        outer: Span2,
    },
    /// Byte just past the `:` value indicator, or null for a bare key with no
    /// `:` at all. An empty value's node is anchored here so a `set` renders
    /// after the colon rather than splicing into the key.
    sep_end: ?usize,
    value: *Node,
};

pub const Document = struct {
    arena: Allocator,
    source: []const u8,
    /// Composed read-through trees, one per document in the stream. `get`/
    /// `getT` operate on `docs[0]`.
    docs: []Value,
    /// Per-document root node of the byte-range tree. Parallel to `docs`.
    roots: []*Node,
    /// The options `parse` ran with, retained so each edit rebuilds the
    /// composed view and node tree against the new source identically.
    options: yaml.ParseOptions,
    /// Non-null while a batch is open: edits RECORD a splice here instead of
    /// reparsing. `commitBatch` applies them all in one pass and reparses once.
    /// All recorded offsets address the pre-batch `source`/tree.
    batch: ?std.ArrayList(PendingEdit) = null,

    /// Parse `src` losslessly: dupe the source, compose the read-through
    /// `Value`(s) via the composer, and build a byte-range node tree
    /// from the comment-aware scanner token stream.
    ///
    /// The document stores per-node u64 byte offsets, so any in-memory input
    /// is addressable without a size cap.
    pub fn parse(arena: Allocator, src: []const u8, options: yaml.ParseOptions) Error!Document {
        const source = try arena.dupe(u8, src);
        const docs = composer.parseStream(arena, source, options) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NestingTooDeep => return error.NestingTooDeep,
            error.YamlParseError, error.AliasBudgetExceeded => return error.InvalidValue,
        };
        const roots = try buildTree(arena, source, options.max_depth);
        return .{
            .arena = arena,
            .source = source,
            .docs = docs,
            .roots = roots,
            .options = options,
        };
    }

    /// Bootstrap a document with no source bytes -- the "file doesn't exist
    /// yet" case. Reads (`get`/`getT`/`has`) see nothing; emitting
    /// unmodified reproduces the empty input, same as `parse` does for any
    /// untouched document. The first `set` (or any segment variant) splices
    /// the root mapping and the whole requested path in as a single edit.
    /// Unlike `parse`, this never fails.
    pub fn empty(arena: Allocator, options: yaml.ParseOptions) Error!Document {
        const root = try arena.create(Node);
        root.* = .{
            .outer = .{ .start = 0, .end = 0 },
            .content = .{ .start = 0, .end = 0 },
            .data = .{ .mapping = .empty },
        };
        const docs = try arena.dupe(Value, &.{Value{ .map = &.{} }});
        const roots = try arena.dupe(*Node, &.{root});
        return .{
            .arena = arena,
            .source = "",
            .docs = docs,
            .roots = roots,
            .options = options,
        };
    }

    /// Look up a value by dotted path in the first document (syntax as
    /// `Value.get`). Returns null if absent or if the stream is empty.
    pub fn get(self: *const Document, path: []const u8) ?Value {
        if (self.docs.len == 0) return null;
        return self.docs[0].get(path);
    }

    /// Convenience: `self.get(path) != null`.
    pub fn has(self: *const Document, path: []const u8) bool {
        return self.get(path) != null;
    }

    /// Typed read by dotted path against the first document. Null on missing
    /// path, traversal through a non-container, type mismatch, or overflow.
    pub fn getT(self: *const Document, comptime T: type, path: []const u8) ?T {
        if (self.docs.len == 0) return null;
        return self.docs[0].getT(T, path);
    }

    /// Write the (possibly edited) document. Byte-identical to the input when
    /// no edit was made; an edited document differs only where edited.
    pub fn emit(self: *const Document, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeAll(self.source);
    }

    /// Replace the value at `path` (first-document dotted path, same syntax
    /// as `Value.get`) with `value`, touching only that value's bytes --
    /// keys, comments, indentation, and siblings are preserved. Comptime-
    /// dispatched on `@TypeOf(value)`:
    ///   - `yaml.Value`       -> rendered via the emitter (scalars only here)
    ///   - `bool`             -> `true`/`false`
    ///   - integer types      -> decimal
    ///   - float types        -> emitter float format
    ///   - `[]const u8` / string literal -> plain or round-trip-safe quoted
    ///   - `null` / null optional -> `null`
    /// The new scalar is rendered with the SAME round-trip-safe quoting as
    /// `emit`, so a set string `"true"`/`"123"`/`"~"`/`"a: b"` is quoted.
    /// If the leaf is absent but its parent block mapping exists, the member
    /// is APPENDED at the sibling indentation; a missing intermediate
    /// mapping is created too (a new block-mapping chain, indented one level
    /// deeper per nesting level), and only mappings are ever created this
    /// way -- a `[N]` sequence index anywhere in the missing tail stays
    /// `error.PathNotFound`. Each edit retains a fresh source/tree
    /// generation in the arena.
    pub fn set(self: *Document, path: []const u8, value: anytype) Error!void {
        const v = try valueFromAny(self.arena, @TypeOf(value), value);
        return self.setValue(path, v);
    }

    /// Set the value at `path` from a structured `yaml.Value`, rendered via
    /// the emitter so the quoting matches `emit` (a `.string` of `"true"`/
    /// `"123"`/`"~"` is round-trip-safe quoted). Splices over the value's
    /// bytes like `set`; a missing leaf in an existing block mapping appends a
    /// new member, creating any missing intermediate mapping(s) too. This is
    /// the named, canonical setter `set` delegates to for its `Value` case.
    pub fn setValue(self: *Document, path: []const u8, value: Value) Error!void {
        const raw = try renderScalarValue(self.arena, value);
        return self.setRaw(path, raw);
    }

    /// Set the value at `path` to literal YAML source. `raw` must parse as a
    /// single standalone YAML value (a scalar, or a flow/block collection);
    /// it is validated by reparsing and rejected with `error.InvalidValue`
    /// otherwise. Splices verbatim, so this is the escape hatch for inserting
    /// pre-formatted YAML (specific flow style, quoting) without the scalar
    /// renderer's normalization. Like `set`, a missing leaf in an existing
    /// block mapping appends a new member, creating any missing intermediate
    /// mapping(s) too.
    pub fn setLiteral(self: *Document, path: []const u8, raw: []const u8) Error!void {
        try self.validateLiteral(raw);
        return self.setRaw(path, try self.arena.dupe(u8, raw));
    }

    /// Segment-taking twin of `set`. `segments` are literal mapping keys
    /// addressed in order -- never re-split on `.` or `[N]` -- so a key
    /// containing either byte (e.g. `"example.com"`) is addressed
    /// unambiguously. See `set` for the type-dispatch rules.
    pub fn setSegments(self: *Document, segments: []const []const u8, value: anytype) Error!void {
        const v = try valueFromAny(self.arena, @TypeOf(value), value);
        return self.setValueSegments(segments, v);
    }

    /// Segment-taking twin of `setValue`.
    pub fn setValueSegments(self: *Document, segments: []const []const u8, value: Value) Error!void {
        const raw = try renderScalarValue(self.arena, value);
        return self.setRawSegments(try segmentsFromKeys(self.arena, segments), raw);
    }

    /// Reparse `raw` on its own; `error.InvalidValue` unless it yields exactly
    /// one YAML document holding a single value.
    fn validateLiteral(self: *const Document, raw: []const u8) Error!void {
        _ = composer.parse(self.arena, raw, self.options) catch {
            return error.InvalidValue;
        };
    }

    /// Splice `raw` over the value span of the node at `path`, then rebuild
    /// the source, node tree, and composed view so subsequent reads/edits see
    /// the result. When the leaf does not exist but its parent block mapping
    /// does, append it as a new member instead.
    fn setRaw(self: *Document, path: []const u8, raw: []const u8) Error!void {
        return self.setRawSegments(try segmentsFromPath(self.arena, path), raw);
    }

    /// Segment-based core shared by `setRaw` (string paths, pre-split via
    /// `segmentsFromPath`) and `setValueSegments` (already literal key
    /// segments). An existing full path is edited in place; a missing one is
    /// created by `insertMissing`.
    fn setRawSegments(self: *Document, segments: []const Segment, raw: []const u8) Error!void {
        if (self.roots.len == 0) return error.PathNotFound;
        if (resolveNodeSegments(self.roots[0], segments)) |node| {
            // An empty value is a zero-width node anchored just past the `:`
            // (or the key end). Splicing `raw` at the anchor may glue it to
            // the colon/key (`a:` + 1 -> `a:1`). When the byte at the anchor
            // is already a space or tab, scan forward past the whitespace run
            // and insert at the end of that run (reusing the existing
            // separator). When there is no leading whitespace, prepend a space.
            if (node.outer.start == node.outer.end) {
                const at = node.outer.start;
                if (at < self.source.len and
                    (self.source[at] == ' ' or self.source[at] == '\t'))
                {
                    // Scan forward over the whitespace run; insert value there.
                    var ws_end = at;
                    while (ws_end < self.source.len and
                        (self.source[ws_end] == ' ' or self.source[ws_end] == '\t'))
                    {
                        ws_end += 1;
                    }
                    // A trailing comment opens right after the run (`a: # c`).
                    // Inserting at the run end would glue the value to the `#`
                    // (`a: 1# c`), which is no longer a comment. Keep a space
                    // before the `#` so it stays one.
                    if (ws_end < self.source.len and self.source[ws_end] == '#') {
                        const spaced = try std.mem.concat(self.arena, u8, &.{ raw, " " });
                        return self.applyEdit(ws_end, ws_end, spaced);
                    }
                    return self.applyEdit(ws_end, ws_end, raw);
                } else {
                    const spaced = try std.mem.concat(self.arena, u8, &.{ " ", raw });
                    return self.applyEdit(at, at, spaced);
                }
            }
            return self.applyEdit(node.outer.start, node.outer.end, raw);
        }
        return self.insertMissing(segments, raw);
    }

    /// Splice a brand-new leaf, creating any missing intermediate mapping(s)
    /// along the way. `segments` is never empty here: `resolveNodeSegments`
    /// on zero segments always finds the root, so `setRawSegments` never
    /// falls through to this function with an empty list.
    ///
    /// Only mappings are ever created. If the leaf segment is a sequence
    /// index (or a malformed bracket), or any segment in the missing tail
    /// is, creation is refused and the path stays `error.PathNotFound` --
    /// sequence elements can only be replaced, never created, whether or not
    /// their container exists yet.
    fn insertMissing(self: *Document, segments: []const Segment, raw: []const u8) Error!void {
        if (segments[segments.len - 1] != .key) return error.PathNotFound;

        // Walk the existing prefix as far as it goes. Reaching the end of
        // the loop normally (not via `break`) means every segment up to the
        // leaf's immediate parent already exists -- only the leaf itself is
        // new, today's single-level append. A `break` means `cur` (a real,
        // existing mapping) is missing `missing_key` and everything from
        // there through the leaf must be created.
        var cur = self.roots[0];
        var i: usize = 0;
        var missing_key: []const u8 = undefined;
        while (i < segments.len - 1) : (i += 1) {
            switch (segments[i]) {
                .key => |k| {
                    if (cur.data != .mapping) return error.PathNotFound;
                    if (findMemberIndex(cur, k)) |mi| {
                        cur = cur.data.mapping.items[mi].value;
                    } else {
                        missing_key = k;
                        break;
                    }
                },
                .index => |idx| {
                    if (cur.data != .sequence or idx >= cur.data.sequence.items.len) return error.PathNotFound;
                    cur = cur.data.sequence.items[idx];
                },
                .raw => return error.PathNotFound,
            }
        } else {
            if (cur.data != .mapping) return error.PathNotFound;
            return self.appendMember(cur, segments[segments.len - 1].key, raw);
        }

        // `cur` is missing `missing_key`; every remaining segment through
        // the leaf must be a key too -- only mappings are ever created, so a
        // `[N]` anywhere in the tail (including the leaf) stays
        // `error.PathNotFound`.
        var keys: std.ArrayList([]const u8) = .empty;
        try keys.append(self.arena, missing_key);
        for (segments[i + 1 ..]) |seg| {
            switch (seg) {
                .key => |k| try keys.append(self.arena, k),
                .index, .raw => return error.PathNotFound,
            }
        }
        return self.appendMappingTail(cur, keys.items, raw);
    }

    /// Where and at what indentation a new member should be spliced into
    /// `parent`: after the last existing member at its indentation, or --
    /// for a virtual zero-width root (only `Document.empty`'s bootstrap
    /// mapping has one) -- at the root itself with no indentation. A real
    /// empty flow mapping (`{}`, non-zero-width but no members) has no block
    /// line to model an indentation from, so appending into it is out of
    /// scope (`error.InvalidValue`), unchanged from before.
    fn memberInsertion(self: *const Document, parent: *Node) Error!struct { indent: []const u8, at: usize } {
        const members = parent.data.mapping.items;
        if (members.len == 0) {
            if (parent.outer.start == parent.outer.end) {
                return .{ .indent = "", .at = parent.outer.start };
            }
            return error.InvalidValue;
        }

        const last = members[members.len - 1];
        // Indentation of the new member = the column the last sibling's key
        // begins at (the bytes from its line start to the key).
        var line_start = last.key.outer.start;
        while (line_start > 0 and self.source[line_start - 1] != '\n') line_start -= 1;
        const indent = self.source[line_start..last.key.outer.start];
        // A non-whitespace indent prefix means the last member is not the
        // first thing on its line (e.g. a flow mapping); not a block append.
        for (indent) |c| {
            if (c != ' ' and c != '\t') return error.InvalidValue;
        }

        // Insert after the LINE end of the last sibling's value (not the raw
        // value-span end), so any trailing comment or whitespace on that line
        // stays with the last sibling instead of being pushed onto the new
        // member's line.  `lineEnd` scans forward to the newline and steps over
        // it, so the new member lands on its own fresh line.  For a block scalar
        // whose span already includes its trailing newline, `lineEnd` of its end
        // resolves to the same position (it finds a `\n` immediately and returns
        // one past it), so no extra blank line is introduced.
        return .{ .indent = indent, .at = self.lineEnd(last.value.outer.end) };
    }

    /// Append `<key>: raw` as a new member of `parent`, at the indentation
    /// and position `memberInsertion` resolves.
    fn appendMember(self: *Document, parent: *Node, key: []const u8, raw: []const u8) Error!void {
        const ins = try self.memberInsertion(parent);
        const text = try std.mem.concat(self.arena, u8, &.{ ins.indent, key, ": ", raw, "\n" });
        return self.applyEdit(ins.at, ins.at, text);
    }

    /// Append a brand-new nested block-mapping chain as one member of
    /// `parent`: `keys[0]` becomes the new member's key (at `parent`'s
    /// member indentation), wrapping `keys[1]`, ... down to the leaf, whose
    /// value is `raw`.
    fn appendMappingTail(self: *Document, parent: *Node, keys: []const []const u8, raw: []const u8) Error!void {
        const ins = try self.memberInsertion(parent);
        const text = try renderMappingTail(self.arena, ins.indent, keys, raw);
        return self.applyEdit(ins.at, ins.at, text);
    }

    /// Splice `replacement` over `source[start..end)`. Outside a batch this
    /// rebuilds the source, composed view, and node tree immediately (a splice
    /// that yields malformed YAML leaves the document untouched and returns
    /// `error.InvalidValue`). Inside a batch it instead RECORDS the splice
    /// against the pre-batch source for `commitBatch` to apply in one pass.
    /// `replacement` must outlive the call (callers pass arena-owned or static
    /// bytes), since a batch holds the slice until commit.
    fn applyEdit(self: *Document, start: usize, end: usize, replacement: []const u8) Error!void {
        if (self.batch) |*edits| {
            try edits.append(self.arena, .{ .start = start, .end = end, .replacement = replacement });
            return;
        }
        const new_source = try std.mem.concat(self.arena, u8, &.{
            self.source[0..start], replacement, self.source[end..],
        });
        try self.reparse(new_source);
    }

    /// Compose and rebuild the node tree for `new_source`, then adopt it. A
    /// `new_source` that does not compose leaves the document untouched and
    /// returns `error.InvalidValue`.
    fn reparse(self: *Document, new_source: []const u8) Error!void {
        const new_docs = composer.parseStream(self.arena, new_source, self.options) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NestingTooDeep => return error.NestingTooDeep,
            error.YamlParseError, error.AliasBudgetExceeded => return error.InvalidValue,
        };
        const new_roots = try buildTree(self.arena, new_source, self.options.max_depth);
        self.source = new_source;
        self.docs = new_docs;
        self.roots = new_roots;
    }

    /// Open a batch: subsequent `set`/`setValue`/`setLiteral`/`remove`/
    /// `setTrailingComment`/`addCommentBefore`/`removeCommentBefore` calls
    /// RECORD a byte-range splice (resolved against the CURRENT tree at call
    /// time) instead of reparsing, and apply with a single reparse at
    /// `commitBatch`. Reads (`get`/`getT`/`has`/`valueSpanForTest`) during a
    /// batch see the PRE-batch tree; recorded edits are not reflected until
    /// commit. All edits in a batch address the original document's structure.
    /// Idempotent: opening an already-open batch keeps the accumulated edits.
    pub fn beginBatch(self: *Document) void {
        if (self.batch == null) self.batch = .empty;
    }

    /// Apply every recorded splice in one pass and reparse once. The result is
    /// byte-identical to applying the same edits sequentially (each with its
    /// own reparse), PROVIDED no two edits touch overlapping byte ranges. Any
    /// overlap (including two zero-width inserts at the same offset, or an
    /// insert inside a replaced range) -> `error.ConflictingEdits` with the
    /// document left UNCHANGED (atomic). An edit whose combined result is
    /// malformed YAML -> `error.InvalidValue`, also unchanged. After a
    /// successful (or failed) commit the batch is closed; an empty batch
    /// commit is a no-op.
    pub fn commitBatch(self: *Document) Error!void {
        const edits = self.batch orelse return;
        // Close the batch up front so the splices below go through the
        // immediate path and so a later edit after commit is non-batched.
        self.batch = null;
        if (edits.items.len == 0) return;

        // Sort by start DESCENDING; on ties (zero-width inserts at the same
        // offset) order by end DESCENDING. Applying high-to-low means a splice
        // never invalidates the recorded offsets of a lower one.
        const items = edits.items;
        std.mem.sort(PendingEdit, items, {}, struct {
            fn lessThan(_: void, a: PendingEdit, b: PendingEdit) bool {
                if (a.start != b.start) return a.start > b.start;
                return a.end > b.end;
            }
        }.lessThan);

        // Overlap check over the descending order. For adjacent edits (prev =
        // the higher-start one already seen, e = the current lower-or-equal
        // one), non-overlap requires e.end <= prev_start: e's replaced range
        // must lie entirely before where prev begins. A strictly-greater end
        // overlaps prev's range. Coincident starts (two edits anchored at the
        // same byte, e.g. two appends to one mapping, or two replacements of
        // the same span) have an undefined relative emit order, so they
        // conflict too -- caught because such an e has start == prev_start,
        // hence (for a non-empty prev) end > prev_start, and for two zero-width
        // inserts the explicit same-point test below.
        var prev_start: usize = std.math.maxInt(usize);
        var prev_empty = false;
        for (items) |e| {
            if (e.start > e.end) return error.ConflictingEdits;
            if (e.end > prev_start) return error.ConflictingEdits;
            // Two zero-width inserts at the same offset: e.end == e.start ==
            // prev_start passes the e.end<=prev_start test, but their order is
            // ambiguous. Reject.
            if (e.start == prev_start and e.end == e.start and prev_empty)
                return error.ConflictingEdits;
            prev_start = e.start;
            prev_empty = e.start == e.end;
        }

        // Build the new source by splicing in descending order onto a copy.
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(self.arena, self.source);
        for (items) |e| {
            try buf.replaceRange(self.arena, e.start, e.end - e.start, e.replacement);
        }
        const new_source = try self.arena.dupe(u8, buf.items);
        return self.reparse(new_source);
    }

    /// Delete the mapping member or sequence element at `path` (first-document
    /// dotted path), removing its full line(s): the leading indentation before
    /// the key or `-`, the value (including a multi-line nested collection or
    /// block scalar), any trailing comment on the line, and the trailing
    /// newline. Removing the only member of a collection replaces that
    /// collection with an empty flow `{}` / `[]`, since a block collection with
    /// no members has no valid presentation. The document root itself cannot be
    /// removed (`error.InvalidValue`); a missing path is `error.PathNotFound`.
    pub fn remove(self: *Document, path: []const u8) Error!void {
        return self.removeSeg(try segmentsFromPath(self.arena, path));
    }

    /// Segment-taking twin of `remove`.
    pub fn removeSegments(self: *Document, segments: []const []const u8) Error!void {
        return self.removeSeg(try segmentsFromKeys(self.arena, segments));
    }

    fn removeSeg(self: *Document, segments: []const Segment) Error!void {
        if (self.roots.len == 0) return error.PathNotFound;
        const r = resolveWithParentSegments(self.roots[0], segments) orelse return error.PathNotFound;
        const parent = r.parent orelse return error.InvalidValue;

        // Sole member: a block collection cannot be empty, so collapse the
        // whole collection to an empty flow form over its value span.
        const count = switch (parent.data) {
            .mapping => parent.data.mapping.items.len,
            .sequence => parent.data.sequence.items.len,
            .scalar => unreachable,
        };
        if (count == 1) {
            const empty_form = if (parent.data == .mapping) "{}" else "[]";
            return self.applyEdit(parent.outer.start, parent.outer.end, empty_form);
        }

        // A flow collection (`[1, 2, 3]` / `{x: 1, y: 2}`) packs every member
        // onto the span starting at its `[`/`{`. Deleting by LINE would wipe the
        // whole collection, so splice out just the element and one adjacent
        // comma instead.
        if (parent.outer.start < self.source.len and
            (self.source[parent.outer.start] == '[' or self.source[parent.outer.start] == '{'))
        {
            return self.removeFlowElement(parent, r);
        }

        // Otherwise delete the member/element's full line(s): from the start of
        // the line its key/`-` begins on, through the newline ending its last
        // value line (which carries any trailing comment with it). For a
        // mapping the line begins at the KEY (the value may be a multi-line
        // nested collection whose own span starts on a later line); for a
        // sequence element the node span already begins at the value, and the
        // `-` indicator sits before it on the same line.
        const head: usize = switch (parent.data) {
            .mapping => parent.data.mapping.items[r.index].key.outer.start,
            .sequence => r.node.outer.start,
            .scalar => unreachable,
        };
        const line_lo = self.lineStart(head);
        const line_hi = self.lineEnd(r.node.outer.end);
        return self.applyEdit(line_lo, line_hi, "");
    }

    /// Splice out one element of a FLOW collection, leaving the collection
    /// otherwise intact. The element span runs from its key (mapping) or value
    /// (sequence) start through its value end; one adjacent comma is removed
    /// with it -- the trailing `,` when there is one (interior elements), else
    /// the leading `,` (the last element). `remove` already handled the
    /// sole-member case, so a separator always exists here.
    fn removeFlowElement(self: *Document, parent: *Node, r: Resolved) Error!void {
        const src = self.source;
        const el_start: usize = switch (parent.data) {
            .mapping => parent.data.mapping.items[r.index].key.outer.start,
            .sequence => r.node.outer.start,
            .scalar => unreachable,
        };
        const el_end = r.node.outer.end;

        var del_start = el_start;
        var del_end = el_end;

        // Prefer the trailing comma: scan past spaces/tabs after the element.
        var i = el_end;
        while (i < src.len and (src[i] == ' ' or src[i] == '\t')) i += 1;
        if (i < src.len and src[i] == ',') {
            i += 1;
            while (i < src.len and (src[i] == ' ' or src[i] == '\t')) i += 1;
            del_end = i;
        } else {
            // Last element: take the leading comma instead.
            var j = el_start;
            while (j > 0 and (src[j - 1] == ' ' or src[j - 1] == '\t')) j -= 1;
            if (j > 0 and src[j - 1] == ',') del_start = j - 1;
        }
        return self.applyEdit(del_start, del_end, "");
    }

    /// Set or remove the trailing `# comment` on the line of the node at
    /// `path`. `text != null` adds or replaces the comment; `text == null`
    /// removes an existing one (no-op when there is none). The comment goes
    /// after the node's value, separated by a single space when adding fresh.
    /// When replacing, the whitespace gap before the existing `#` is preserved.
    /// Missing path -> `error.PathNotFound`.
    pub fn setTrailingComment(self: *Document, path: []const u8, text: ?[]const u8) Error!void {
        // A newline in the comment text would inject real YAML structure that
        // survives reparse; reject before touching the document (atomic).
        if (text) |t| {
            if (std.mem.indexOfAny(u8, t, "\n\r") != null) return error.InvalidComment;
        }
        if (self.roots.len == 0) return error.PathNotFound;
        const node = resolveNode(self.roots[0], path) orelse return error.PathNotFound;

        // Scan from the end of the value's PRESENTATION envelope (past the
        // closing quote / block body) to the end of the line, looking for an
        // existing trailing comment. Using `outer.end` rather than the content
        // end means the scan never starts on a delimiter byte (a closing quote)
        // and so can never overwrite it, and a `#` inside a quoted value lies
        // before `outer.end` and is correctly ignored.
        const value_end = node.outer.end;
        const src = self.source;

        // Find the newline (or EOF) that terminates the value's line.
        var line_end: usize = value_end;
        while (line_end < src.len and src[line_end] != '\n') line_end += 1;

        // Within [value_end, line_end) look for a `#` preceded by whitespace.
        // The gap between the value and the `#` starts at `gap_start` and the
        // `#` sits at `hash_pos`; both are null when no comment exists.
        var gap_start: ?usize = null;
        var hash_pos: ?usize = null;
        {
            var i: usize = value_end;
            while (i < line_end) : (i += 1) {
                if (src[i] == ' ' or src[i] == '\t') continue;
                if (src[i] == '#') {
                    // A `#` is a comment only when preceded by white space (or
                    // at the very start of the post-value region, i.e. value_end
                    // itself). Since we iterate from value_end and skip only
                    // spaces/tabs before this, any `#` we reach here satisfies
                    // the whitespace requirement.
                    gap_start = value_end;
                    hash_pos = i;
                }
                // Stop at the first non-whitespace byte regardless of whether it
                // was a `#`; anything else is not a comment.
                break;
            }
        }

        if (text) |t| {
            if (hash_pos) |hp| {
                // REPLACE: keep the gap before `#`, replace only the `# text`
                // part, so the whitespace before `#` is preserved.
                const new_comment = try std.mem.concat(self.arena, u8, &.{ "# ", t });
                return self.applyEdit(hp, line_end, new_comment);
            } else {
                // ADD: insert ` # text` between value_end and the newline,
                // replacing whatever whitespace was already there (there should
                // be none, but trim defensively).
                const insert = try std.mem.concat(self.arena, u8, &.{ " # ", t });
                return self.applyEdit(value_end, line_end, insert);
            }
        } else {
            if (hash_pos != null) {
                // REMOVE: delete from gap_start through line_end (exclusive of
                // the newline itself, which stays).
                return self.applyEdit(gap_start.?, line_end, "");
            }
            // No comment exists; nothing to remove.
        }
    }

    /// Insert a full-line `# text` comment on its OWN line immediately before
    /// the line of the node at `path`, indented to match that line. For a
    /// mapping member the anchor is its key; for a sequence element the `-`
    /// indicator establishes the indentation column. The comment is valid YAML
    /// trivia, so reads still work after the edit. Missing path ->
    /// `error.PathNotFound`.
    pub fn addCommentBefore(self: *Document, path: []const u8, text: []const u8) Error!void {
        // A newline would inject real YAML structure; reject before mutating.
        if (std.mem.indexOfAny(u8, text, "\n\r") != null) return error.InvalidComment;
        if (self.roots.len == 0) return error.PathNotFound;
        const r = resolveWithParent(self.roots[0], path) orelse return error.PathNotFound;
        const anchor = commentAnchor(r);
        const line_lo = self.lineStart(anchor);
        // Clip to leading whitespace: for a sequence element the anchor points
        // to the value (past `- `), so `source[line_lo..anchor]` would include
        // the `- ` indicator. Only the whitespace prefix sets the indent column.
        var ws_end = line_lo;
        while (ws_end < anchor and (self.source[ws_end] == ' ' or self.source[ws_end] == '\t')) ws_end += 1;
        const indent = self.source[line_lo..ws_end];
        const insertion = try std.mem.concat(self.arena, u8, &.{ indent, "# ", text, "\n" });
        return self.applyEdit(line_lo, line_lo, insertion);
    }

    /// Remove a full-line `# comment` immediately preceding the line of the
    /// node at `path`, if there is one; a no-op when the preceding line is not
    /// a full-line comment. Missing path -> `error.PathNotFound`.
    pub fn removeCommentBefore(self: *Document, path: []const u8) Error!void {
        if (self.roots.len == 0) return error.PathNotFound;
        const r = resolveWithParent(self.roots[0], path) orelse return error.PathNotFound;
        const anchor = commentAnchor(r);
        const line_lo = self.lineStart(anchor);
        if (line_lo == 0) return;
        const prev_lo = self.lineStart(line_lo - 1);
        // A full-line comment is leading whitespace then `#` up to the line
        // its node sits on; a trailing comment on the previous member's line
        // is not removed (it is not a line of its own).
        var i = prev_lo;
        while (i < line_lo and (self.source[i] == ' ' or self.source[i] == '\t')) i += 1;
        if (i >= line_lo or self.source[i] != '#') return;
        return self.applyEdit(prev_lo, line_lo, "");
    }

    /// The byte where the node's line content begins: a mapping member's key,
    /// otherwise the node's own value span start. `lineStart` of this yields
    /// the line whose leading whitespace is the node's indentation.
    fn commentAnchor(r: Resolved) usize {
        if (r.parent) |p| {
            if (p.data == .mapping) return p.data.mapping.items[r.index].key.outer.start;
        }
        return r.node.outer.start;
    }

    /// First byte of the line containing `at`: scan back to just after the
    /// preceding newline (or the buffer start).
    fn lineStart(self: *const Document, at: usize) usize {
        var i = at;
        while (i > 0 and self.source[i - 1] != '\n') i -= 1;
        return i;
    }

    /// One past the newline that ends the line containing `at`: scan forward to
    /// the next newline and step over it, so the trailing comment and line
    /// break are consumed. At end-of-buffer with no newline, returns the end.
    fn lineEnd(self: *const Document, at: usize) usize {
        var i = at;
        while (i < self.source.len and self.source[i] != '\n') i += 1;
        if (i < self.source.len) i += 1;
        return i;
    }

    /// Test-only accessor: the value byte `Span2` for a dotted path in the
    /// first document, walked through the node tree. Proves the tree's spans
    /// are precise -- the invariant every edit operation relies on.
    pub fn valueSpanForTest(self: *const Document, path: []const u8) ?Span2 {
        if (self.roots.len == 0) return null;
        const node = resolveNode(self.roots[0], path) orelse return null;
        return node.content;
    }

    /// Walk `path` through the node tree (same syntax as `Value.get`).
    fn resolveNode(root: *Node, path: []const u8) ?*Node {
        var cur = root;
        var it = value_mod.PathIterator.init(path);
        while (it.next()) |segment| {
            switch (segment) {
                .key => |k| {
                    const mi = findMemberIndex(cur, k) orelse return null;
                    cur = cur.data.mapping.items[mi].value;
                },
                .index => |idx| {
                    if (cur.data != .sequence) return null;
                    if (idx >= cur.data.sequence.items.len) return null;
                    cur = cur.data.sequence.items[idx];
                },
                .raw => return null,
            }
        }
        return cur;
    }

    /// A resolved node together with its enclosing collection and the
    /// member/element index within it. `parent` is null only for the root.
    const Resolved = struct { node: *Node, parent: ?*Node, index: usize };

    /// Walk `path` through the node tree like `resolveNode`, but also report the
    /// enclosing collection node and the index of `node` within it, so `remove`
    /// can address the member/element line. Null on any missing segment.
    fn resolveWithParent(root: *Node, path: []const u8) ?Resolved {
        var cur = root;
        var parent: ?*Node = null;
        var index: usize = 0;
        var it = value_mod.PathIterator.init(path);
        while (it.next()) |segment| {
            switch (segment) {
                .key => |k| {
                    const mi = findMemberIndex(cur, k) orelse return null;
                    parent = cur;
                    index = mi;
                    cur = cur.data.mapping.items[mi].value;
                },
                .index => |idx| {
                    if (cur.data != .sequence) return null;
                    if (idx >= cur.data.sequence.items.len) return null;
                    parent = cur;
                    index = idx;
                    cur = cur.data.sequence.items[idx];
                },
                .raw => return null,
            }
        }
        return .{ .node = cur, .parent = parent, .index = index };
    }

    /// Walk pre-split `segments` through the node tree, the segment-taking
    /// twin of `resolveNode` shared by `setRawSegments` and `insertMissing`.
    fn resolveNodeSegments(root: *Node, segments: []const Segment) ?*Node {
        var cur = root;
        for (segments) |segment| {
            switch (segment) {
                .key => |k| {
                    const mi = findMemberIndex(cur, k) orelse return null;
                    cur = cur.data.mapping.items[mi].value;
                },
                .index => |idx| {
                    if (cur.data != .sequence) return null;
                    if (idx >= cur.data.sequence.items.len) return null;
                    cur = cur.data.sequence.items[idx];
                },
                .raw => return null,
            }
        }
        return cur;
    }

    /// Segment-taking twin of `resolveWithParent`, backing `removeSegments`.
    fn resolveWithParentSegments(root: *Node, segments: []const Segment) ?Resolved {
        var cur = root;
        var parent: ?*Node = null;
        var index: usize = 0;
        for (segments) |segment| {
            switch (segment) {
                .key => |k| {
                    const mi = findMemberIndex(cur, k) orelse return null;
                    parent = cur;
                    index = mi;
                    cur = cur.data.mapping.items[mi].value;
                },
                .index => |idx| {
                    if (cur.data != .sequence) return null;
                    if (idx >= cur.data.sequence.items.len) return null;
                    parent = cur;
                    index = idx;
                    cur = cur.data.sequence.items[idx];
                },
                .raw => return null,
            }
        }
        return .{ .node = cur, .parent = parent, .index = index };
    }
};

/// Duplicate keys are last-wins (matching the composed `Value`'s `mapGet`):
/// scan for the LAST member of `node` (must be `.mapping`) whose decoded key
/// equals `key`, so reads and writes agree on which member a duplicated key
/// designates. Returns null when `node` is not a mapping or has no such key.
fn findMemberIndex(node: *const Node, key: []const u8) ?usize {
    if (node.data != .mapping) return null;
    const items = node.data.mapping.items;
    var mi = items.len;
    while (mi > 0) {
        mi -= 1;
        if (std.mem.eql(u8, items[mi].key.decoded, key)) return mi;
    }
    return null;
}

/// Split a dotted string path into segments via `PathIterator`,
/// arena-allocated so the creation-aware core (`insertMissing`) can walk it
/// more than once (the streaming iterator is single-pass).
fn segmentsFromPath(arena: Allocator, path: []const u8) Error![]const Segment {
    var list: std.ArrayList(Segment) = .empty;
    var it = value_mod.PathIterator.init(path);
    while (it.next()) |segment| try list.append(arena, segment);
    return list.toOwnedSlice(arena);
}

/// Wrap pre-split key segments as `Segment.key` values. The segments API
/// never interprets `.` or `[...]`, so a key containing either byte still
/// addresses exactly that one member.
fn segmentsFromKeys(arena: Allocator, keys: []const []const u8) Error![]const Segment {
    const out = try arena.alloc(Segment, keys.len);
    for (keys, out) |k, *seg| seg.* = .{ .key = k };
    return out;
}

/// Spaces of indentation per nesting level when materializing a brand-new
/// nested block-mapping chain (no existing sibling to infer a step from).
/// Matches the emitter's own default `indent` option and every hand-written
/// example in this library's docs/tests.
const default_indent_step: usize = 2;

/// Render the block-mapping chain text for one or more newly-created
/// nesting levels: `keys[0]` at `base_indent` wraps `keys[1]` one level
/// deeper, and so on down to the leaf (`keys[keys.len - 1]`), whose value is
/// `raw`. `base_indent` is the indentation the FIRST line (`keys[0]`) is
/// inserted at -- `appendMappingTail`'s caller-determined sibling style or
/// the empty-document bootstrap.
fn renderMappingTail(arena: Allocator, base_indent: []const u8, keys: []const []const u8, raw: []const u8) Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (keys, 0..) |k, level| {
        try buf.appendSlice(arena, base_indent);
        try buf.appendNTimes(arena, ' ', level * default_indent_step);
        try buf.appendSlice(arena, k);
        if (level == keys.len - 1) {
            try buf.appendSlice(arena, ": ");
            try buf.appendSlice(arena, raw);
            try buf.append(arena, '\n');
        } else {
            try buf.appendSlice(arena, ":\n");
        }
    }
    return buf.toOwnedSlice(arena);
}

// Node-tree construction
//
// The tree is built by driving the comment-aware scanner and consuming its
// structural token stream with a recursive descent that mirrors the parser's
// block/flow grammar. Comments (and document/stream framing) carry no
// editable position, so the builder skips them -- emit is a source
// passthrough, and only the key/value/element byte ranges need to be
// precise. Each builder routine returns the node it built and leaves the
// cursor on the token after the node.

/// Buffered structural tokens (comments and stream/directive framing dropped)
/// with a cursor, plus the source for span arithmetic.
const TokenStream = struct {
    toks: []const Token,
    src: []const u8,
    pos: usize = 0,

    fn peekKind(self: *const TokenStream) ?TokenKind {
        if (self.pos >= self.toks.len) return null;
        return self.toks[self.pos].kind;
    }

    fn peek(self: *const TokenStream) ?Token {
        if (self.pos >= self.toks.len) return null;
        return self.toks[self.pos];
    }

    fn take(self: *TokenStream) Token {
        const t = self.toks[self.pos];
        self.pos += 1;
        return t;
    }
};

/// Collect every scanner token for one stream into a flat list, dropping
/// comments and framing the build does not need (stream_start/end, directives,
/// comment tokens). Document markers are kept so the per-document split works.
/// An `.invalid` token means the source did not pass the composer, which the
/// caller already ruled out, so it maps to `error.InvalidValue` defensively.
fn buildTree(arena: Allocator, src: []const u8, max_depth: usize) Error![]*Node {
    var toks: std.ArrayList(Token) = .empty;
    var sc = Scanner.initWithComments(src);
    while (sc.nextRaw()) |t| {
        switch (t.kind) {
            .comment, .stream_start, .stream_end, .directive => continue,
            .invalid => return error.InvalidValue,
            else => try toks.append(arena, t),
        }
    }

    var ts: TokenStream = .{ .toks = toks.items, .src = src };
    var roots: std.ArrayList(*Node) = .empty;
    // The stream is a sequence of documents, each optionally fenced by `---`
    // and terminated by `...`. A document's content is one root node, possibly
    // empty (an absent node between markers).
    while (ts.peek()) |t| {
        switch (t.kind) {
            .document_start => {
                _ = ts.take();
                const node = try buildDocumentRoot(arena, &ts, max_depth);
                try roots.append(arena, node);
            },
            .document_end => {
                // A bare `...` with no preceding content frames an empty doc
                // only when the composer produced one; otherwise it just closes
                // the previous document. The composer's doc count is the source
                // of truth, so do not synthesize a root here.
                _ = ts.take();
            },
            else => {
                // Content with no explicit `---`: an implicit document.
                const node = try buildDocumentRoot(arena, &ts, max_depth);
                try roots.append(arena, node);
            },
        }
    }
    return roots.items;
}

/// Build the single root node of one document: everything up to the next
/// document boundary (`---`/`...`) or stream end. An empty document (no
/// content token before the boundary) yields an empty scalar node at the
/// current position.
fn buildDocumentRoot(arena: Allocator, ts: *TokenStream, max_depth: usize) Error!*Node {
    const k = ts.peekKind();
    if (k == null or k == .document_start or k == .document_end) {
        // Empty document: a zero-width scalar at the boundary point.
        const at: usize = if (ts.peek()) |t| tokStart(t) else ts.src.len;
        return makeNode(arena, .{ .start = at, .end = at }, .scalar);
    }
    return buildNode(arena, ts, max_depth, 0);
}

/// Build one node (scalar / mapping / sequence) starting at the cursor,
/// consuming its whole subtree. `depth` bounds nesting.
fn buildNode(arena: Allocator, ts: *TokenStream, max_depth: usize, depth: usize) Error!*Node {
    if (depth > max_depth) return error.NestingTooDeep;
    // Skip leading node properties (anchor/tag): they decorate the node but are
    // not part of its value span for editing purposes.
    while (ts.peekKind()) |k| {
        if (k == .anchor or k == .tag) _ = ts.take() else break;
    }
    const t = ts.peek() orelse {
        // Properties with no following node: an empty scalar at end.
        const at: usize = ts.src.len;
        return makeNode(arena, .{ .start = at, .end = at }, .scalar);
    };
    switch (t.kind) {
        .block_mapping_start, .flow_mapping_start => return buildMapping(arena, ts, max_depth, depth),
        .block_sequence_start, .flow_sequence_start => return buildSequence(arena, ts, max_depth, depth),
        .scalar => {
            _ = ts.take();
            return makeScalarNode(arena, ts.src, t);
        },
        // An alias (`*name`) is a complete value node, sigil included. The
        // scanner's token span covers the NAME only -- correct for an anchor
        // PROPERTY, wrong for an alias VALUE -- so widen the editable envelope
        // back over the leading `*`. Without it a `set` over an alias splices
        // only the name and leaves a stray `*`, silently re-aliasing the value.
        .alias => {
            _ = ts.take();
            return makeNode(arena, .{ .start = tokStart(t) - 1, .end = tokEnd(t) }, .scalar);
        },
        // A bare `key`/`value` indicator with no scalar is an empty node.
        .key, .value, .block_entry => {
            return makeNode(arena, .{ .start = tokStart(t), .end = tokStart(t) }, .scalar);
        },
        else => {
            // Defensive: any other token here means the stream shape did not
            // match the grammar (already ruled out by the composer).
            return makeNode(arena, .{ .start = tokStart(t), .end = tokStart(t) }, .scalar);
        },
    }
}

/// Build a mapping node. Block mappings are framed by
/// `block_mapping_start`/`block_end`; flow mappings by
/// `flow_mapping_start`/`flow_mapping_end` with `flow_entry` (`,`) separators
/// and explicit `key`/`value` indicators (`?`/`:`). In both, the per-entry
/// shape is an optional `key` indicator, the key node, a `value` indicator,
/// then the value node; an absent half is an empty node.
fn buildMapping(arena: Allocator, ts: *TokenStream, max_depth: usize, depth: usize) Error!*Node {
    const open = ts.take();
    const flow = open.kind == .flow_mapping_start;
    const end_kind: TokenKind = if (flow) .flow_mapping_end else .block_end;

    var members: std.ArrayList(Member) = .empty;
    var lo: usize = tokStart(open);
    var hi: usize = tokEnd(open);

    while (true) {
        const k = ts.peekKind() orelse break;
        if (k == end_kind) {
            const close = ts.take();
            // A flow close (`}`) is a zero-width point at the brace; the brace
            // itself is one byte past it, so it extends the span. A block_end
            // is a zero-width point at the DEDENT position (past the trailing
            // line break), which is not mapping content, so it does not.
            if (flow) hi = @max(hi, tokEnd(close) + 1);
            break;
        }
        if (flow and k == .flow_entry) {
            _ = ts.take();
            continue;
        }
        // Optional explicit-key indicator (`?` in block, `?` in flow). Track
        // the cursor so an entry that consumes no token (an unforeseen stuck
        // token shape) fails fast instead of spinning this loop forever.
        const before = ts.pos;
        if (k == .key) _ = ts.take();

        // The key node.
        const key_node = try buildNode(arena, ts, max_depth, depth + 1);
        lo = @min(lo, key_node.outer.start);
        hi = @max(hi, key_node.outer.end);

        // The value indicator (`:`); may be absent for a key-only entry. When
        // present, `sep_end` is the byte just past it -- the anchor an empty
        // value's edit splices at, so it lands after the `:` not inside the key.
        var value_node: *Node = undefined;
        var sep_end: ?usize = null;
        if (ts.peekKind() == .value) {
            const colon = ts.take();
            sep_end = tokEnd(colon);
            // After the `:`, a value node -- unless the next token closes the
            // mapping or starts the next entry (an empty value).
            const nk = ts.peekKind();
            if (nk == null or nk == end_kind or nk == .key or
                (flow and nk == .flow_entry))
            {
                const at = sep_end.?;
                value_node = try makeNode(arena, .{ .start = at, .end = at }, .scalar);
            } else {
                value_node = try buildNode(arena, ts, max_depth, depth + 1);
            }
        } else {
            // Key with no value indicator: empty value at the key's end.
            const at = key_node.outer.end;
            value_node = try makeNode(arena, .{ .start = at, .end = at }, .scalar);
        }
        lo = @min(lo, value_node.outer.start);
        hi = @max(hi, value_node.outer.end);

        try members.append(arena, .{
            .key = .{
                .decoded = try decodeNodeContent(arena, ts.src, key_node),
                .outer = key_node.outer,
            },
            .sep_end = sep_end,
            .value = value_node,
        });
        if (ts.pos == before) return error.InvalidValue;
    }

    return makeNode(arena, .{ .start = lo, .end = hi }, .{ .mapping = members });
}

/// Build a sequence node. Block sequences are framed by
/// `block_sequence_start`/`block_end` with a `block_entry` (`-`) before each
/// element; flow sequences by `flow_sequence_start`/`flow_sequence_end` with
/// `flow_entry` (`,`) separators. A flow sequence element may itself be a
/// single-pair mapping (`[a: 1]`), which the scanner frames with `key`/`value`
/// indicators; that is handled by routing the element through `buildNode`,
/// which sees the synthesized `block_mapping_start`-equivalent only in block
/// context. In flow, a bare `key`+`value` element with no collection-start is
/// treated as one mapping built inline.
fn buildSequence(arena: Allocator, ts: *TokenStream, max_depth: usize, depth: usize) Error!*Node {
    const open = ts.take();
    const flow = open.kind == .flow_sequence_start;
    const end_kind: TokenKind = if (flow) .flow_sequence_end else .block_end;

    var elems: std.ArrayList(*Node) = .empty;
    var lo: usize = tokStart(open);
    var hi: usize = tokEnd(open);

    while (true) {
        const k = ts.peekKind() orelse break;
        if (k == end_kind) {
            const close = ts.take();
            // A flow close (`]`) is a zero-width point at the bracket; the
            // bracket itself is one byte past it, so it extends the span. A
            // block_end is at the DEDENT position (past the trailing line
            // break), which is not sequence content, so it does not.
            if (flow) hi = @max(hi, tokEnd(close) + 1);
            break;
        }
        if (flow and k == .flow_entry) {
            _ = ts.take();
            continue;
        }
        if (!flow and k == .block_entry) {
            _ = ts.take();
            // An empty entry (`-` with nothing, then end/next entry).
            const nk = ts.peekKind();
            if (nk == null or nk == end_kind or nk == .block_entry) {
                const at: usize = tokEnd(open);
                const e = try makeNode(arena, .{ .start = at, .end = at }, .scalar);
                try elems.append(arena, e);
                continue;
            }
            const e = try buildNode(arena, ts, max_depth, depth + 1);
            lo = @min(lo, e.outer.start);
            hi = @max(hi, e.outer.end);
            try elems.append(arena, e);
            continue;
        }
        // Flow element (a node, or an inline single-pair mapping). Guard cursor
        // progress: every element builder must consume at least one token, or a
        // malformed/unforeseen token shape would spin this loop forever.
        const before = ts.pos;
        const e = try buildFlowSeqElement(arena, ts, max_depth, depth, flow, end_kind);
        if (ts.pos == before) return error.InvalidValue;
        lo = @min(lo, e.outer.start);
        hi = @max(hi, e.outer.end);
        try elems.append(arena, e);
    }

    return makeNode(arena, .{ .start = lo, .end = hi }, .{ .sequence = elems });
}

/// Build one flow-sequence element. Usually a plain node, but a `key`/`value`
/// pair appearing bare inside a flow sequence (`[a: 1, b: 2]`) is a
/// single-pair mapping; gather it into a one-entry mapping node so the element
/// addresses like a map. An element opening with a bare `value` indicator and
/// no `key` is a single-pair with an EMPTY key (`[: v]`, `[ : v ]`); the empty
/// key node sits at the indicator position.
fn buildFlowSeqElement(
    arena: Allocator,
    ts: *TokenStream,
    max_depth: usize,
    depth: usize,
    flow: bool,
    end_kind: TokenKind,
) Error!*Node {
    const k = ts.peekKind();
    if (k == .key or k == .value) {
        // `?`-style explicit key consumes the indicator and builds a key node;
        // a `:`-first element has an empty key at the value indicator's start.
        const key_node = if (k == .key) blk: {
            _ = ts.take();
            break :blk try buildNode(arena, ts, max_depth, depth + 1);
        } else blk: {
            const at = tokStart(ts.peek().?);
            break :blk try makeNode(arena, .{ .start = at, .end = at }, .scalar);
        };
        var lo = key_node.outer.start;
        var hi = key_node.outer.end;
        var value_node: *Node = undefined;
        var sep_end: ?usize = null;
        if (ts.peekKind() == .value) {
            const colon = ts.take();
            sep_end = tokEnd(colon);
            const nk = ts.peekKind();
            if (nk == null or nk == end_kind or nk == .flow_entry) {
                const at = sep_end.?;
                value_node = try makeNode(arena, .{ .start = at, .end = at }, .scalar);
            } else {
                value_node = try buildNode(arena, ts, max_depth, depth + 1);
            }
        } else {
            value_node = try makeNode(arena, .{ .start = hi, .end = hi }, .scalar);
        }
        lo = @min(lo, value_node.outer.start);
        hi = @max(hi, value_node.outer.end);
        var members: std.ArrayList(Member) = .empty;
        try members.append(arena, .{
            .key = .{
                .decoded = try decodeNodeContent(arena, ts.src, key_node),
                .outer = key_node.outer,
            },
            .sep_end = sep_end,
            .value = value_node,
        });
        return makeNode(arena, .{ .start = lo, .end = hi }, .{ .mapping = members });
    }
    _ = flow;
    return buildNode(arena, ts, max_depth, depth + 1);
}

/// A scanner token's usize byte offsets, used directly as the document's
/// `Span2` offsets. usize indexes any in-memory buffer without a size cap.
fn tokStart(t: Token) usize {
    return t.span.start;
}

fn tokEnd(t: Token) usize {
    return t.span.end;
}

/// Step back over one trailing line break (`\n` or `\r\n`) at `end`, if any.
/// A block scalar's body span ends past the break that terminates its last
/// line; excluding that break from the editable envelope keeps the line
/// terminator intact when a `set` replaces the block.
fn trimTrailingBreak(src: []const u8, end: usize) usize {
    if (end > 0 and src[end - 1] == '\n') {
        if (end >= 2 and src[end - 2] == '\r') return end - 2;
        return end - 1;
    }
    return end;
}

/// Decode a scalar node's content bytes to its cooked value text, the single
/// key/scalar identity reads compare against. Reuses the composer's scalar
/// cooking (unescape / fold / `''` collapse) via `cookScalarText`, so a key's
/// decoded form here is exactly what `Value.get` matches: an escaped or quoted
/// key spelling resolves to its decoded form. A non-scalar node has no decoded
/// content; callers only invoke this on key/scalar nodes.
fn decodeNodeContent(arena: Allocator, src: []const u8, node: *const Node) Error![]const u8 {
    const content = src[node.content.start..node.content.end];
    const style: scanner_mod.ScalarStyle = node.style;
    const ev: yaml.Event = .{
        .kind = .scalar,
        .span = .{ .start = node.content.start, .end = node.content.end },
        .scalar_style = style,
        .value = content,
        // A key is never a block scalar in practice; pass a default header so
        // the cooker has one if a `|`/`>` content ever reaches here.
        .block_header = if (style == .literal or style == .folded) .{} else null,
    };
    return composer.cookScalarText(arena, src, ev) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidValue,
    };
}

/// Build a node whose `outer` and `content` coincide (collections, empty
/// nodes, and plain scalars). `style` defaults to plain.
fn makeNode(arena: Allocator, span: Span2, data: @FieldType(Node, "data")) Error!*Node {
    const node = try arena.create(Node);
    node.* = .{ .outer = span, .content = span, .style = .plain, .data = data };
    return node;
}

/// Build a scalar leaf from a scanner scalar token, computing the editable
/// `outer` envelope from the token's style. The token's span is the inner
/// content the scanner points at:
///   - double/single quoted: content is between the quotes; outer adds the
///     surrounding quote bytes.
///   - literal `|` / folded `>`: content is the body; outer runs from the
///     header indicator (recorded on the block header) through the body end.
///   - plain (and numbers/bools/null): outer == content.
fn makeScalarNode(arena: Allocator, src: []const u8, t: Token) Error!*Node {
    const content: Span2 = .{ .start = tokStart(t), .end = tokEnd(t) };
    const outer: Span2 = switch (t.style) {
        .plain => content,
        .single, .double => .{ .start = content.start - 1, .end = content.end + 1 },
        // The body span runs through the trailing line break that terminates
        // the block; exclude that one break from `outer` so a `set` replacing
        // the block leaves the line terminator in place (like a plain scalar,
        // whose span ends before its `\n`).
        .literal, .folded => .{
            .start = @intCast(t.block_header.header_start),
            .end = trimTrailingBreak(src, content.end),
        },
    };
    const node = try arena.create(Node);
    node.* = .{ .outer = outer, .content = content, .style = t.style, .data = .scalar };
    return node;
}

// Edit value rendering

/// Render a scalar `Value` to its YAML bytes via the emitter, so the quoting
/// is identical to `emit`. Collections are out of scope for scalar edits.
fn renderScalarValue(arena: Allocator, value: Value) Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    defer aw.deinit();
    emitter.renderScalar(&aw.writer, value) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
        error.UnrepresentableScalar, error.UnrepresentableInt, error.NestingTooDeep => return error.InvalidValue,
    };
    return arena.dupe(u8, aw.written());
}

/// Convert a native Zig value into a `Value`, comptime-dispatched on
/// `@TypeOf(value)`. Backs `Document.set`. Supported: `Value` passthrough,
/// bool, integer, float, `[]const u8` / string literal (arena-duped), `null`,
/// and optionals of the above. Other types compile-error.
fn valueFromAny(arena: Allocator, comptime T: type, value: T) Error!Value {
    if (T == Value) return value;
    if (T == @TypeOf(null)) return .null;
    return switch (@typeInfo(T)) {
        .bool => .{ .bool = value },
        .int => .{ .int = std.math.cast(i128, value) orelse return error.InvalidValue },
        .comptime_int => .{ .int = value },
        .float => .{ .float = @floatCast(value) },
        .comptime_float => .{ .float = value },
        .optional => |o| if (value) |inner| try valueFromAny(arena, o.child, inner) else .null,
        .pointer => |p| blk: {
            if (p.size == .slice and p.child == u8 and p.is_const) {
                break :blk .{ .string = try arena.dupe(u8, value) };
            }
            if (p.size == .one and p.is_const) {
                const child_info = @typeInfo(p.child);
                if (child_info == .array and child_info.array.child == u8) {
                    const as_slice: []const u8 = value;
                    break :blk .{ .string = try arena.dupe(u8, as_slice) };
                }
            }
            @compileError("Document.set: only []const u8 / string literal supported, got " ++ @typeName(T));
        },
        else => @compileError("Document.set: unsupported type " ++ @typeName(T)),
    };
}

// Tests

test "Span2 offsets are usize (no 4 GiB cap)" {
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(@FieldType(Span2, "start")));
}

test "unmodified emit is byte-identical: block mapping with comments" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "# header\nname: app   # trailing\nports:\n  - 80\n  - 443\nnested:\n  k: v\n";
    var doc = try Document.parse(a, src, .{});
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings(src, aw.written());
}

test "byte-identical: flow, anchors, tags, multi-doc, block scalars" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // The anchor decorates a completed scalar (`base: &anchor 1`); a node-root
    // anchor referenced from within its own subtree (`--- &anchor ... *anchor`)
    // is a self-reference the composer rejects as a cycle, so it is not used
    // here -- the node tree handles anchor/alias tokens regardless.
    const src = "--- \nbase: &anchor 1\nlist: [1, 2, 3]\nmap: {x: 1, y: 2}\ntag: !!str 5\nlit: |\n  line1\n  line2\nref: *anchor\n...\n---\ndoc2: true\n";
    var doc = try Document.parse(a, src, .{});
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings(src, aw.written());
}

test "byte-identical: no trailing newline, CRLF, blank lines" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    for ([_][]const u8{ "a: 1", "a: 1\r\nb: 2\r\n", "a: 1\n\n\nb: 2\n", "key: value" }) |src| {
        var doc = try Document.parse(a, src, .{});
        var aw: std.Io.Writer.Allocating = .init(a);
        defer aw.deinit();
        try doc.emit(&aw.writer);
        try std.testing.expectEqualStrings(src, aw.written());
    }
}

test "getT reads through document" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    var doc = try Document.parse(ar.allocator(), "server:\n  port: 8080\nname: app\n", .{});
    try std.testing.expectEqual(@as(u16, 8080), doc.getT(u16, "server.port").?);
    try std.testing.expectEqualStrings("app", doc.getT([]const u8, "name").?);
}

test "node tree records value spans for editing" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const src = "server:\n  port: 8080\n";
    var doc = try Document.parse(ar.allocator(), src, .{});
    const span = doc.valueSpanForTest("server.port").?;
    try std.testing.expectEqualStrings("8080", src[span.start..span.end]);
}

test "value spans: nested map, sequence, scalars" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "name: app\nports:\n  - 80\n  - 443\nnested:\n  k: v\n";
    var doc = try Document.parse(a, src, .{});

    const name_span = doc.valueSpanForTest("name").?;
    try std.testing.expectEqualStrings("app", src[name_span.start..name_span.end]);

    const p0 = doc.valueSpanForTest("ports[0]").?;
    try std.testing.expectEqualStrings("80", src[p0.start..p0.end]);
    const p1 = doc.valueSpanForTest("ports[1]").?;
    try std.testing.expectEqualStrings("443", src[p1.start..p1.end]);

    const k = doc.valueSpanForTest("nested.k").?;
    try std.testing.expectEqualStrings("v", src[k.start..k.end]);

    // The nested mapping's own value span covers its whole text.
    const nested = doc.valueSpanForTest("nested").?;
    try std.testing.expectEqualStrings("k: v", src[nested.start..nested.end]);
}

test "value spans: flow collections cover brackets" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "list: [1, 2, 3]\nmap: {x: 1, y: 2}\n";
    var doc = try Document.parse(a, src, .{});

    const list = doc.valueSpanForTest("list").?;
    try std.testing.expectEqualStrings("[1, 2, 3]", src[list.start..list.end]);
    const e1 = doc.valueSpanForTest("list[1]").?;
    try std.testing.expectEqualStrings("2", src[e1.start..e1.end]);

    const map = doc.valueSpanForTest("map").?;
    try std.testing.expectEqualStrings("{x: 1, y: 2}", src[map.start..map.end]);
    const y = doc.valueSpanForTest("map.y").?;
    try std.testing.expectEqualStrings("2", src[y.start..y.end]);
}

test "byte-identical: flow sequence single-pair with empty key" {
    // A flow-sequence element that is a single-pair mapping with an EMPTY key
    // (`[: v]`, `[ : v ]`) opens on a bare `value` indicator with no `key`. The
    // tree builder must consume that indicator; before the empty-key path was
    // modeled the entry loop spun forever. Byte-identity proves emit passes the
    // input through unchanged; the cursor-progress guard bounds the loop.
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "- [ : empty key ]\n- [: another empty key]\n";
    var doc = try Document.parse(a, src, .{});
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings(src, aw.written());
}

test "value spans: quoted scalar value is the inner content" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "s: \"hello\"\n";
    var doc = try Document.parse(a, src, .{});
    const s = doc.valueSpanForTest("s").?;
    try std.testing.expectEqualStrings("hello", src[s.start..s.end]);
}

test "multi-doc: get reads first document, emit reproduces stream" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "a: 1\n---\nb: 2\n";
    var doc = try Document.parse(a, src, .{});
    try std.testing.expectEqual(@as(i64, 1), doc.getT(i64, "a").?);
    try std.testing.expect(doc.getT(i64, "b") == null);
    try std.testing.expect(doc.docs.len == 2);
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings(src, aw.written());
}

test "set replaces only the value bytes" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "name: app   # keep\nport: 80\n", .{});
    try doc.set("port", @as(u16, 9090));
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("name: app   # keep\nport: 9090\n", aw.written());
}
test "set a string that needs quoting stays round-trip-safe" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "k: v\n", .{});
    try doc.set("k", "true");
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("k: \"true\"\n", aw.written());
}
test "set nested and sequence element" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "server:\n  port: 1\nlist:\n  - a\n  - b\n", .{});
    try doc.set("server.port", @as(u16, 2));
    try doc.set("list[1]", "z");
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("server:\n  port: 2\nlist:\n  - a\n  - z\n", aw.written());
}
test "set bool int float null" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a: x\nb: x\nc: x\nd: x\n", .{});
    try doc.set("a", true);
    try doc.set("b", @as(i64, -5));
    try doc.set("c", @as(f64, 1.5));
    try doc.set("d", null);
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("a: true\nb: -5\nc: 1.5\nd: null\n", aw.written());
}
test "set a missing leaf appends a new member" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a: 1\n", .{});
    try doc.set("nope", @as(i64, 1));
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("a: 1\nnope: 1\n", aw.written());
}
test "multiple edits compose; getT reflects them" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "x: 1\ny: 2\n", .{});
    try doc.set("x", @as(i64, 10));
    try doc.set("y", @as(i64, 20));
    try std.testing.expectEqual(@as(i64, 10), doc.getT(i64, "x").?);
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("x: 10\ny: 20\n", aw.written());
}
test "setLiteral splices a raw value" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "tags: []\n", .{});
    try doc.setLiteral("tags", "[alpha, beta]");
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("tags: [alpha, beta]\n", aw.written());
}
test "setLiteral rejects a malformed value" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    var doc = try Document.parse(ar.allocator(), "k: v\n", .{});
    try std.testing.expectError(error.InvalidValue, doc.setLiteral("k", "[unterminated"));
}
test "set appends a new key matching sibling indentation" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "name: app\nport: 80\n", .{});
    try doc.set("tls", true); // new top-level key
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("name: app\nport: 80\ntls: true\n", aw.written());
}
test "append a nested new key" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "server:\n  port: 80\n", .{});
    try doc.set("server.host", "0.0.0.0");
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("server:\n  port: 80\n  host: 0.0.0.0\n", aw.written());
}
test "append via setLiteral" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a: 1\n", .{});
    try doc.setLiteral("b", "[1, 2]");
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("a: 1\nb: [1, 2]\n", aw.written());
}
test "set creates a missing intermediate mapping, then the leaf" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a: 1\n", .{});
    try doc.set("x.y", @as(i64, 1)); // x doesn't exist yet
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("a: 1\nx:\n  y: 1\n", aw.written());
    try std.testing.expectEqual(@as(i64, 1), doc.getT(i64, "x.y").?);
}
test "set creates a 3-deep missing path, preserving surrounding trivia" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "# header\na: 1  # keep\n";
    var doc = try Document.parse(a, src, .{});
    try doc.set("x.y.z", @as(i64, 2));
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("# header\na: 1  # keep\nx:\n  y:\n    z: 2\n", aw.written());
    try std.testing.expectEqual(@as(i64, 2), doc.getT(i64, "x.y.z").?);
    // Untouched prefix bytes (comment + original key/comment) are preserved.
    try std.testing.expectEqual(@as(i64, 1), doc.getT(i64, "a").?);
}
test "set creates missing intermediates through a partially existing prefix" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "top:\n  x: 1\n", .{});
    try doc.set("top.a.b", @as(i64, 2));
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("top:\n  x: 1\n  a:\n    b: 2\n", aw.written());
    try std.testing.expectEqual(@as(i64, 2), doc.getT(i64, "top.a.b").?);
    try std.testing.expectEqual(@as(i64, 1), doc.getT(i64, "top.x").?);
}
test "intermediate creation never fabricates a sequence: a [N] anywhere in the missing tail stays PathNotFound" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    var doc = try Document.parse(ar.allocator(), "a: 1\n", .{});
    // "missing" doesn't exist; the path would need it to become a sequence
    // to hold index 0 -- creation only ever builds mappings, so this stays
    // an error, exactly like the pre-existing "leaf is an index" rule.
    try std.testing.expectError(error.PathNotFound, doc.set("missing[0].c", true));
    try std.testing.expectError(error.PathNotFound, doc.set("missing[0]", true));
    try std.testing.expectError(error.PathNotFound, doc.set("missing.mid[0].c", true));
}
test "set through a scalar stays PathNotFound, unchanged from before" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    var doc = try Document.parse(ar.allocator(), "a: 1\n", .{});
    try std.testing.expectError(error.PathNotFound, doc.set("a.leaf", true));
}
test "Document.empty bootstraps root + full path on first set" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.empty(a, .{});
    var aw0: std.Io.Writer.Allocating = .init(a);
    defer aw0.deinit();
    try doc.emit(&aw0.writer);
    try std.testing.expectEqualStrings("", aw0.written());
    try std.testing.expect(!doc.has("a.b.c"));

    try doc.set("a.b.c", @as(i64, 1));
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("a:\n  b:\n    c: 1\n", aw.written());
    try std.testing.expectEqual(@as(i64, 1), doc.getT(i64, "a.b.c").?);
}
test "Document.empty then a single-segment set" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.empty(a, .{});
    try doc.set("x", @as(i64, 9));
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("x: 9\n", aw.written());
}
test "setValueSegments creates the single literal key, not a nested dotted path" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "other: 1\n", .{});
    try doc.setValueSegments(&.{ "host", "example.com" }, .{ .string = "1.2.3.4" });
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("other: 1\nhost:\n  example.com: 1.2.3.4\n", aw.written());

    // Re-parse independently and confirm the key is the single literal
    // "example.com", not a nested "example" -> "com" mapping. A dotted-path
    // lookup would re-split on the key's own `.`, so inspect the node tree
    // directly instead.
    var check = try Document.parse(a, aw.written(), .{});
    const host = check.roots[0].data.mapping.items[1];
    try std.testing.expectEqualStrings("host", host.key.decoded);
    try std.testing.expect(host.value.data == .mapping);
    try std.testing.expectEqual(@as(usize, 1), host.value.data.mapping.items.len);
    const inner = host.value.data.mapping.items[0];
    try std.testing.expectEqualStrings("example.com", inner.key.decoded);
    // Cross-check against the composed Value tree too: one entry, keyed by
    // the single literal "example.com", not two levels of nesting.
    const host_value = check.get("host").?;
    try std.testing.expectEqual(@as(usize, 1), host_value.map.len);
    try std.testing.expectEqualStrings("example.com", host_value.map[0].key.string);
    try std.testing.expectEqualStrings("1.2.3.4", host_value.map[0].value.string);
}
test "setSegments dispatches native types like set" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "top: 1\n", .{});
    try doc.setSegments(&.{ "server", "host" }, "example.com");
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("top: 1\nserver:\n  host: example.com\n", aw.written());
    try std.testing.expectEqualStrings("example.com", doc.getT([]const u8, "server.host").?);
}
test "removeSegments removes a member addressed by literal key segments" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "host:\n  example.com: 1\n  other: 2\n", .{});
    try doc.removeSegments(&.{ "host", "example.com" });
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("host:\n  other: 2\n", aw.written());
    try std.testing.expectError(error.PathNotFound, doc.removeSegments(&.{ "host", "example.com" }));
}
test "existing-key set via segments is byte-identical to the string-path route" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "a: 1\nb: 2\n";

    var via_path = try Document.parse(a, src, .{});
    try via_path.set("a", @as(i64, 99));

    var via_seg = try Document.parse(a, src, .{});
    try via_seg.setSegments(&.{"a"}, @as(i64, 99));

    var pw: std.Io.Writer.Allocating = .init(a);
    defer pw.deinit();
    try via_path.emit(&pw.writer);
    var sw: std.Io.Writer.Allocating = .init(a);
    defer sw.deinit();
    try via_seg.emit(&sw.writer);

    const wanted = "a: 99\nb: 2\n";
    try std.testing.expectEqualStrings(wanted, pw.written());
    try std.testing.expectEqualStrings(wanted, sw.written());
}
test "remove a middle mapping member deletes its whole line" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a: 1\nb: 2\nc: 3\n", .{});
    try doc.remove("b");
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("a: 1\nc: 3\n", aw.written());
}
test "remove first and last mapping member" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a: 1\nb: 2\nc: 3\n", .{});
    try doc.remove("a");
    try doc.remove("c");
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("b: 2\n", aw.written());
}
test "remove a nested member" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "server:\n  host: h\n  port: 80\n", .{});
    try doc.remove("server.port");
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("server:\n  host: h\n", aw.written());
}
test "remove a sequence element" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "list:\n  - a\n  - b\n  - c\n", .{});
    try doc.remove("list[1]");
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("list:\n  - a\n  - c\n", aw.written());
}
test "remove member with a trailing comment removes the comment too" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a: 1\nb: 2  # gone\nc: 3\n", .{});
    try doc.remove("b");
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("a: 1\nc: 3\n", aw.written());
}
test "remove missing path errors" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    var doc = try Document.parse(ar.allocator(), "a: 1\n", .{});
    try std.testing.expectError(error.PathNotFound, doc.remove("nope"));
}
test "remove the only member of a nested mapping leaves an empty flow mapping" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "server:\n  port: 80\nname: app\n", .{});
    try doc.remove("server.port");
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("server:\n  {}\nname: app\n", aw.written());
    try std.testing.expect(doc.get("server").?.map.len == 0);
    try std.testing.expectEqualStrings("app", doc.getT([]const u8, "name").?);
}
test "remove the only element of a nested sequence leaves an empty flow sequence" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "list:\n  - a\nname: app\n", .{});
    try doc.remove("list[0]");
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("list:\n  []\nname: app\n", aw.written());
    try std.testing.expect(doc.get("list").?.seq.len == 0);
}
test "remove the document root errors" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    var doc = try Document.parse(ar.allocator(), "a: 1\n", .{});
    try std.testing.expectError(error.InvalidValue, doc.remove(""));
}

test "setTrailingComment adds a trailing comment" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "port: 80\n", .{});
    try doc.setTrailingComment("port", "the port");
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("port: 80 # the port\n", aw.written());
}
test "setTrailingComment replaces an existing trailing comment" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "port: 80  # old\n", .{});
    try doc.setTrailingComment("port", "new");
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("port: 80  # new\n", aw.written());
}
test "setTrailingComment null removes a trailing comment" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "port: 80 # remove me\n", .{});
    try doc.setTrailingComment("port", null);
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("port: 80\n", aw.written());
}
test "setTrailingComment on a nested member" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "server:\n  host: h\n", .{});
    try doc.setTrailingComment("server.host", "hostname");
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("server:\n  host: h # hostname\n", aw.written());
}
test "setTrailingComment missing path errors" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    var doc = try Document.parse(ar.allocator(), "a: 1\n", .{});
    try std.testing.expectError(error.PathNotFound, doc.setTrailingComment("nope", "x"));
}

test "append does not steal a previous sibling's trailing comment" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a: 1\nb: 2  # note on b\n", .{});
    try doc.set("c", @as(i64, 3));
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("a: 1\nb: 2  # note on b\nc: 3\n", aw.written());
}
test "append after a nested member with a trailing comment" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "srv:\n  port: 80  # the port\n", .{});
    try doc.set("srv.tls", true);
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("srv:\n  port: 80  # the port\n  tls: true\n", aw.written());
}
test "append after a block scalar value lands with no extra blank line" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "block: |\n  line1\n  line2\nname: app\n", .{});
    try doc.set("extra", @as(i64, 1));
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("block: |\n  line1\n  line2\nname: app\nextra: 1\n", aw.written());
}

test "setValue sets from a structured Value" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "port: 80\n", .{});
    try doc.setValue("port", .{ .int = 9090 });
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("port: 9090\n", aw.written());
}
test "setValue with a string quotes round-trip-safely" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "k: v\n", .{});
    try doc.setValue("k", .{ .string = "true" });
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("k: \"true\"\n", aw.written());
}
test "addCommentBefore inserts a full-line comment at the node's indentation" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "name: app\nport: 80\n", .{});
    try doc.addCommentBefore("port", "the listen port");
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("name: app\n# the listen port\nport: 80\n", aw.written());
}
test "addCommentBefore on a nested member matches indentation" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "server:\n  host: h\n  port: 80\n", .{});
    try doc.addCommentBefore("server.port", "port comment");
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("server:\n  host: h\n  # port comment\n  port: 80\n", aw.written());
}
test "addCommentBefore missing path errors" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    var doc = try Document.parse(ar.allocator(), "a: 1\n", .{});
    try std.testing.expectError(error.PathNotFound, doc.addCommentBefore("nope", "x"));
}
test "addCommentBefore then emit re-parses (comment is valid trivia)" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a: 1\nb: 2\n", .{});
    try doc.addCommentBefore("b", "note");
    try std.testing.expectEqual(@as(i64, 2), doc.getT(i64, "b").?);
    try std.testing.expectEqual(@as(i64, 1), doc.getT(i64, "a").?);
}
test "removeCommentBefore strips a preceding full-line comment" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "name: app\n# the listen port\nport: 80\n", .{});
    try doc.removeCommentBefore("port");
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("name: app\nport: 80\n", aw.written());
}
test "removeCommentBefore is a no-op when the preceding line is not a comment" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "name: app\nport: 80\n", .{});
    try doc.removeCommentBefore("port");
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("name: app\nport: 80\n", aw.written());
}
test "removeCommentBefore on a nested member" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "server:\n  host: h\n  # port comment\n  port: 80\n", .{});
    try doc.removeCommentBefore("server.port");
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("server:\n  host: h\n  port: 80\n", aw.written());
}
test "removeCommentBefore missing path errors" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    var doc = try Document.parse(ar.allocator(), "a: 1\n", .{});
    try std.testing.expectError(error.PathNotFound, doc.removeCommentBefore("nope"));
}

test "addCommentBefore on a sequence element uses element indentation not value offset" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "list:\n  - a\n  - b\n", .{});
    try doc.addCommentBefore("list[1]", "second item");
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("list:\n  - a\n  # second item\n  - b\n", aw.written());
}
test "setValue with a collection Value yields InvalidValue" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "k: v\n", .{});
    const seq_items = try a.dupe(Value, &.{ .{ .int = 1 }, .{ .int = 2 } });
    try std.testing.expectError(error.InvalidValue, doc.setValue("k", .{ .seq = seq_items }));
    const map_items = try a.dupe(value_mod.Entry, &.{.{ .key = .{ .string = "x" }, .value = .{ .int = 1 } }});
    try std.testing.expectError(error.InvalidValue, doc.setValue("k", .{ .map = map_items }));
}
test "addCommentBefore twice stacks both comment lines before the node" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a: 1\nb: 2\n", .{});
    try doc.addCommentBefore("b", "first comment");
    try doc.addCommentBefore("b", "second comment");
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    const got = aw.written();
    try std.testing.expectEqualStrings("a: 1\n# first comment\n# second comment\nb: 2\n", got);
}

test "batched edits produce the same result as sequential edits" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "a: 1\nb: 2\nc: 3\nd: 4\n";
    // sequential reference
    var seq = try Document.parse(a, src, .{});
    try seq.set("a", @as(i64, 10));
    try seq.set("c", @as(i64, 30));
    try seq.setTrailingComment("b", "note");
    var sw: std.Io.Writer.Allocating = .init(a);
    defer sw.deinit();
    try seq.emit(&sw.writer);
    // batched
    var bat = try Document.parse(a, src, .{});
    bat.beginBatch();
    try bat.set("a", @as(i64, 10));
    try bat.set("c", @as(i64, 30));
    try bat.setTrailingComment("b", "note");
    try bat.commitBatch();
    var bw: std.Io.Writer.Allocating = .init(a);
    defer bw.deinit();
    try bat.emit(&bw.writer);
    try std.testing.expectEqualStrings(sw.written(), bw.written());
}
test "batched edits do one reparse and getT reflects them after commit" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "x: 1\ny: 2\nz: 3\n", .{});
    doc.beginBatch();
    try doc.set("x", @as(i64, 100));
    try doc.set("z", @as(i64, 300));
    try doc.commitBatch();
    try std.testing.expectEqual(@as(i64, 100), doc.getT(i64, "x").?);
    try std.testing.expectEqual(@as(i64, 300), doc.getT(i64, "z").?);
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("x: 100\ny: 2\nz: 300\n", aw.written());
}
test "conflicting batched edits error and leave the document unchanged" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a: 1\n", .{});
    doc.beginBatch();
    try doc.set("a", @as(i64, 2));
    // a second edit to the same value span conflicts
    try doc.set("a", @as(i64, 3));
    try std.testing.expectError(error.ConflictingEdits, doc.commitBatch());
    // document unchanged (still a: 1)
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("a: 1\n", aw.written());
}
test "batched remove + set on different keys" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a: 1\nb: 2\nc: 3\n", .{});
    doc.beginBatch();
    try doc.remove("b");
    try doc.set("c", @as(i64, 30));
    try doc.commitBatch();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("a: 1\nc: 30\n", aw.written());
}
test "empty batch commit is a no-op" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a: 1\n", .{});
    doc.beginBatch();
    try doc.commitBatch();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("a: 1\n", aw.written());
}
test "batched reads see the pre-batch tree until commit" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a: 1\nb: 2\n", .{});
    doc.beginBatch();
    try doc.set("a", @as(i64, 10));
    // mid-batch read still reflects the pre-batch value
    try std.testing.expectEqual(@as(i64, 1), doc.getT(i64, "a").?);
    try doc.commitBatch();
    try std.testing.expectEqual(@as(i64, 10), doc.getT(i64, "a").?);
}
test "batched edits that shift offsets stay consistent" {
    // remove() deletes a whole line (shifting later offsets) and an append
    // inserts; descending-order application must keep both correct.
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "a: 1\nb: 2\nc: 3\nd: 4\n";
    var seq = try Document.parse(a, src, .{});
    try seq.remove("a");
    try seq.set("c", @as(i64, 30));
    try seq.set("new", @as(i64, 9));
    var sw: std.Io.Writer.Allocating = .init(a);
    defer sw.deinit();
    try seq.emit(&sw.writer);

    var bat = try Document.parse(a, src, .{});
    bat.beginBatch();
    try bat.remove("a");
    try bat.set("c", @as(i64, 30));
    try bat.set("new", @as(i64, 9));
    try bat.commitBatch();
    var bw: std.Io.Writer.Allocating = .init(a);
    defer bw.deinit();
    try bat.emit(&bw.writer);
    try std.testing.expectEqualStrings(sw.written(), bw.written());
}
test "batch can be reused after commit" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a: 1\nb: 2\n", .{});
    doc.beginBatch();
    try doc.set("a", @as(i64, 10));
    try doc.commitBatch();
    doc.beginBatch();
    try doc.set("b", @as(i64, 20));
    try doc.commitBatch();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("a: 10\nb: 20\n", aw.written());
}

fn emitToString(a: Allocator, doc: *const Document) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);
    return a.dupe(u8, aw.written());
}

// H2: set over a quoted/block scalar splices the whole presentation

test "set over a double-quoted scalar replaces the quotes too" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "port: \"8080\"\n", .{});
    try doc.set("port", @as(u16, 9090));
    try std.testing.expectEqualStrings("port: 9090\n", try emitToString(a, &doc));
    try std.testing.expectEqual(@as(u16, 9090), doc.getT(u16, "port").?);
}
test "set over a double-quoted scalar parses into a typed struct" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "port: \"8080\"\n", .{});
    try doc.set("port", @as(u16, 9090));
    const parsed = try yaml.parse(a, try emitToString(a, &doc), .{});
    try std.testing.expectEqual(@as(i128, 9090), parsed.get("port").?.int);
}
test "set over a single-quoted scalar replaces the quotes too" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a: 'hi'\n", .{});
    try doc.set("a", @as(i64, 5));
    try std.testing.expectEqualStrings("a: 5\n", try emitToString(a, &doc));
    try std.testing.expectEqual(@as(i64, 5), doc.getT(i64, "a").?);
}
test "set over a literal block scalar replaces the whole block" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a: |\n  x\n", .{});
    try doc.set("a", "y");
    try std.testing.expectEqualStrings("a: y\n", try emitToString(a, &doc));
    try std.testing.expectEqualStrings("y", doc.getT([]const u8, "a").?);
}
test "set over an unquoted plain scalar still works (control)" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "port: 8080\n", .{});
    try doc.set("port", @as(u16, 9090));
    try std.testing.expectEqualStrings("port: 9090\n", try emitToString(a, &doc));
}

// H3: setTrailingComment on a quoted scalar keeps the closing quote

test "setTrailingComment on a double-quoted scalar keeps the closing quote" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a: \"hello\"\nb: 2\n", .{});
    try doc.setTrailingComment("a", "C");
    try std.testing.expectEqualStrings("a: \"hello\" # C\nb: 2\n", try emitToString(a, &doc));
    try std.testing.expectEqualStrings("hello", doc.getT([]const u8, "a").?);
}
test "setTrailingComment on a single-quoted scalar keeps the closing quote" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a: 'hello'\nb: 2\n", .{});
    try doc.setTrailingComment("a", "C");
    try std.testing.expectEqualStrings("a: 'hello' # C\nb: 2\n", try emitToString(a, &doc));
}
test "setTrailingComment on a plain scalar (control)" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a: hello\nb: 2\n", .{});
    try doc.setTrailingComment("a", "C");
    try std.testing.expectEqualStrings("a: hello # C\nb: 2\n", try emitToString(a, &doc));
}

// H4: set / setTrailingComment on an empty mapping value

test "set on an empty mapping value renders after the colon" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a:\nb: 2\n", .{});
    try doc.set("a", @as(i64, 1));
    try std.testing.expectEqualStrings("a: 1\nb: 2\n", try emitToString(a, &doc));
    try std.testing.expectEqual(@as(i64, 1), doc.getT(i64, "a").?);
}
test "set on a trailing empty mapping value renders after the colon" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "k: v\nempty:\n", .{});
    try doc.set("empty", @as(i64, 7));
    try std.testing.expectEqualStrings("k: v\nempty: 7\n", try emitToString(a, &doc));
    try std.testing.expectEqual(@as(i64, 7), doc.getT(i64, "empty").?);
}
test "setTrailingComment on an empty mapping value keeps the key intact" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a:\nb: 2\n", .{});
    try doc.setTrailingComment("a", "c");
    try std.testing.expectEqualStrings("a: # c\nb: 2\n", try emitToString(a, &doc));
    try std.testing.expect(doc.has("a"));
    try std.testing.expect(doc.get("a").? == .null);
}

// H4: set on empty value with trailing whitespace after colon

test "set on empty value with single space after colon" {
    // `a: \n` -- sep_end lands on the space; value must be inserted after it.
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a: \nb: 2\n", .{});
    try doc.set("a", @as(i64, 1));
    try std.testing.expectEqualStrings("a: 1\nb: 2\n", try emitToString(a, &doc));
    try std.testing.expectEqual(@as(i64, 1), doc.getT(i64, "a").?);
}
test "set on empty value with multiple spaces after colon" {
    // `a:  \n` -- two spaces after the colon.
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a:  \nb: 2\n", .{});
    try doc.set("a", @as(i64, 1));
    try std.testing.expectEqualStrings("a:  1\nb: 2\n", try emitToString(a, &doc));
    try std.testing.expectEqual(@as(i64, 1), doc.getT(i64, "a").?);
}
test "set on empty value with tab after colon" {
    // `a:\t\n` -- tab between colon and newline.
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a:\t\nb: 2\n", .{});
    try doc.set("a", @as(i64, 1));
    try std.testing.expectEqualStrings("a:\t1\nb: 2\n", try emitToString(a, &doc));
    try std.testing.expectEqual(@as(i64, 1), doc.getT(i64, "a").?);
}
test "set on empty value with space at EOF (no newline)" {
    // `a: ` at end-of-file -- the space is present but there is no newline.
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a: ", .{});
    try doc.set("a", @as(i64, 1));
    try std.testing.expectEqualStrings("a: 1", try emitToString(a, &doc));
    try std.testing.expectEqual(@as(i64, 1), doc.getT(i64, "a").?);
}
test "set on empty value no whitespace after colon (existing behaviour)" {
    // `a:\n` -- no whitespace; a space must be prepended.
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a:\nb: 2\n", .{});
    try doc.set("a", @as(i64, 1));
    try std.testing.expectEqualStrings("a: 1\nb: 2\n", try emitToString(a, &doc));
    try std.testing.expectEqual(@as(i64, 1), doc.getT(i64, "a").?);
}
test "setTrailingComment on empty value with space after colon" {
    // outer.end = sep_end (byte after `:`). setTrailingComment replaces
    // [value_end, line_end) with ` # note`, which consumes the trailing space.
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a: \nb: 2\n", .{});
    try doc.setTrailingComment("a", "note");
    try std.testing.expectEqualStrings("a: # note\nb: 2\n", try emitToString(a, &doc));
}

// Last-wins for duplicate keys

test "duplicate key: read, set, remove target the last occurrence" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a: 1\na: 2\n", .{});
    try std.testing.expectEqual(@as(i64, 2), doc.getT(i64, "a").?);
    try doc.set("a", @as(i64, 9));
    try std.testing.expectEqualStrings("a: 1\na: 9\n", try emitToString(a, &doc));
    try doc.remove("a");
    try std.testing.expectEqualStrings("a: 1\n", try emitToString(a, &doc));
}

// Invariant: resolveNode content matches Value.get; outer splice no-op

test "invariant: resolve content matches Value.get across quoted/empty/dup keys" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "a: 1\na: 2\nq: \"5\"\ne:\nn:\n  x: 3\n";
    var doc = try Document.parse(a, src, .{});
    // Unmodified emit stays byte-identical: every node's outer span re-splices
    // to its own bytes.
    try std.testing.expectEqualStrings(src, try emitToString(a, &doc));
    // resolveNode's decoded content agrees with the composed Value.
    try std.testing.expectEqual(@as(i64, 2), doc.getT(i64, "a").?); // last-wins
    try std.testing.expectEqualStrings("5", doc.getT([]const u8, "q").?);
    try std.testing.expect(doc.get("e").? == .null);
    try std.testing.expectEqual(@as(i64, 3), doc.getT(i64, "n.x").?);
}

// Lossless-model corruption regressions

test "set on an alias replaces the whole *name, not just the name" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "x: &x 1\ny: &y 2\nref: *x\n", .{});
    // Intends the STRING "y"; must NOT leave a `*` turning it into an alias.
    try doc.set("ref", "y");
    try std.testing.expectEqualStrings("x: &x 1\ny: &y 2\nref: y\n", try emitToString(a, &doc));
    try std.testing.expectEqualStrings("y", doc.getT([]const u8, "ref").?);
    // It is a string, not an alias re-resolving to &y's int 2.
    try std.testing.expect(doc.getT(i64, "ref") == null);
}

test "remove a flow-sequence element keeps the collection (first/middle/last)" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    {
        var doc = try Document.parse(a, "before: ok\nlist: [1, 2, 3]\nafter: ok\n", .{});
        try doc.remove("list[1]");
        try std.testing.expectEqualStrings("before: ok\nlist: [1, 3]\nafter: ok\n", try emitToString(a, &doc));
        try std.testing.expect(doc.get("list").?.seq.len == 2);
        try std.testing.expectEqual(@as(i64, 1), doc.getT(i64, "list[0]").?);
        try std.testing.expectEqual(@as(i64, 3), doc.getT(i64, "list[1]").?);
    }
    {
        var doc = try Document.parse(a, "list: [1, 2, 3]\n", .{});
        try doc.remove("list[0]");
        try std.testing.expectEqualStrings("list: [2, 3]\n", try emitToString(a, &doc));
    }
    {
        var doc = try Document.parse(a, "list: [1, 2, 3]\n", .{});
        try doc.remove("list[2]");
        try std.testing.expectEqualStrings("list: [1, 2]\n", try emitToString(a, &doc));
    }
}

test "remove a flow-mapping element keeps the key and the other members" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    {
        var doc = try Document.parse(a, "m: {x: 1, y: 2}\n", .{});
        try doc.remove("m.x");
        try std.testing.expectEqualStrings("m: {y: 2}\n", try emitToString(a, &doc));
        try std.testing.expect(doc.has("m"));
        try std.testing.expectEqual(@as(i64, 2), doc.getT(i64, "m.y").?);
    }
    {
        var doc = try Document.parse(a, "m: {x: 1, y: 2}\n", .{});
        try doc.remove("m.y");
        try std.testing.expectEqualStrings("m: {x: 1}\n", try emitToString(a, &doc));
        try std.testing.expectEqual(@as(i64, 1), doc.getT(i64, "m.x").?);
    }
}

test "set on an empty value before a trailing comment keeps the comment" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a: # c\nb: 2\n", .{});
    try doc.set("a", @as(i64, 1));
    try std.testing.expectEqualStrings("a: 1 # c\nb: 2\n", try emitToString(a, &doc));
    try std.testing.expectEqual(@as(i64, 1), doc.getT(i64, "a").?);
    try std.testing.expectEqual(@as(i64, 2), doc.getT(i64, "b").?);
}

test "comment APIs reject embedded newlines and leave the document unchanged" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var doc = try Document.parse(a, "a: 1\nb: 2\n", .{});
    try std.testing.expectError(error.InvalidComment, doc.setTrailingComment("a", "note\ninjected: pwned"));
    try std.testing.expectError(error.InvalidComment, doc.addCommentBefore("a", "x\ny"));
    try std.testing.expectError(error.InvalidComment, doc.setTrailingComment("a", "carriage\rreturn"));
    try std.testing.expectEqualStrings("a: 1\nb: 2\n", try emitToString(a, &doc));
    try std.testing.expect(doc.getT(i64, "injected") == null);
}
