//! YAML value types.
//!
//! `Value` is a tagged union covering the YAML node kinds: null, bool,
//! int, float, string, seq (sequence), map (mapping). A mapping is an
//! ordered slice of key/value `Entry` pairs, because YAML keys may be
//! any node, not just strings.
//!
//! Memory model: all allocations belong to a caller-owned arena. Free
//! everything with `arena.deinit()`. `string` may be a zero-copy slice
//! into the original input buffer or an arena-allocated copy; the caller
//! must keep the input alive while the parse tree is in use.

const std = @import("std");
const testing = std.testing;

/// 1-indexed line/column derived from a byte offset. Produced by `Span.lineCol`.
pub const LineCol = struct {
    line: u32,
    col: u32,
};

/// Source byte range of a parsed node, as offsets into the input buffer.
/// Offsets are u64, so a span addresses any in-memory `[]const u8` without a
/// 4 GiB cap. Line/column are not stored; derive them on demand with `lineCol`.
pub const Span = struct {
    start: u64,
    end: u64,

    /// 1-indexed line and column of `start` within `src`. O(start): scans
    /// `src[0..start]` counting newlines. Intended for occasional human-facing
    /// location display (diagnostics, tooling), not bulk per-value use. Column
    /// is the byte count since the last newline, plus one. Both saturate at
    /// `maxInt(u32)` for absurdly large inputs.
    pub fn lineCol(self: Span, src: []const u8) LineCol {
        const limit: usize = @intCast(@min(self.start, src.len));
        var line: u64 = 1;
        var line_start: usize = 0;
        var i: usize = 0;
        while (i < limit) : (i += 1) {
            if (src[i] == '\n') {
                line += 1;
                line_start = i + 1;
            }
        }
        return .{
            .line = std.math.cast(u32, line) orelse std.math.maxInt(u32),
            .col = std.math.cast(u32, limit - line_start + 1) orelse std.math.maxInt(u32),
        };
    }
};

/// Internal span with usize byte offsets and incremental line/col, threaded
/// scanner -> parser. The scanner maintains `line`/`col` as it advances (YAML
/// block structure is indentation-sensitive, so the parser consults them for
/// same-line and indentation decisions); they are NOT byte offsets and never
/// reach a stored span. A transient per-token value, never held in bulk, so it
/// has no bearing on stored-span memory or the input-size limit. Public `Span`
/// is materialized from this at the parser/scanner boundary, offsets copied
/// straight through (u64 holds any usize) and line/col dropped.
pub const RawSpan = struct {
    start: usize,
    end: usize,
    line: u32,
    col: u32,
};

/// Saturating add of a usize delta onto a u32 line/col counter. Past
/// maxInt(u32) the counter clamps; a scan of a >4 GiB single line never
/// panics on the col counter (line/col past 4 GiB are best-effort).
pub fn satAdd(base: u32, delta: usize) u32 {
    const sum = @as(u64, base) + @as(u64, delta);
    return std.math.cast(u32, sum) orelse std.math.maxInt(u32);
}

/// Materialize a diagnostic `Span` from a `RawSpan`: copy the byte offsets and
/// drop the incremental line/col. u64 offsets address any in-memory input, so
/// there is no cap; line/col are derived on demand from the span and source at
/// diagnostic render time.
pub fn diagSpan(rs: RawSpan) Span {
    return .{ .start = rs.start, .end = rs.end };
}

/// A map from dotted path to source span (e.g., "users[0].name" ->
/// Span). Sequence elements use `[N]` index segments; the root value's
/// path is the empty string `""`. Populated by the parser via
/// `ParseOptions.spans`; see `Value.locate` for the paired lookup helper.
///
/// Keys are stored as-is: a key whose bytes contain `.` or `[` may
/// collide with a structurally different nested path (e.g. the key
/// `"a.b"` and key `"b"` inside map `"a"` both map to path "a.b"),
/// in which case the later recording wins.
///
/// Span path keys recorded by the parser are arena-allocated and live
/// as long as the value tree. The map stores key slices, not copies, so
/// callers populating it themselves must not key it with reused scratch
/// buffers.
pub const Spans = std.StringHashMapUnmanaged(Span);

/// A single key/value pair in a mapping. The key is itself a `Value`, so
/// mappings can be keyed by scalars, sequences, or nested mappings.
pub const Entry = struct {
    key: Value,
    value: Value,
};

/// Iterator over the segments of a dotted path: `a.b[2].c` yields keys
/// "a", "b", index 2, key "c". The single owner of the path grammar;
/// `Value.get` walks paths through it.
///
/// Grammar:
/// - Key segments end at `.` or `[`; one `.` after a segment is
///   consumed as the separator, so a trailing dot yields nothing
///   (`"a."` iterates like `"a"`) and consecutive dots yield an empty
///   key (which only matches a literal `""` key).
/// - `[N]` yields an index when N parses as usize. A bracket whose
///   interior is empty, non-numeric, negative, or overflows usize
///   yields `.raw` instead, as does an unclosed `[`; lookups treat
///   `.raw` as matching nothing.
pub const PathIterator = struct {
    path: []const u8,
    pos: usize = 0,
    /// Offset just past the last consumed separator (a skipped `.` or
    /// a bracket's `]`): where the path's final raw tail starts once
    /// iteration ends.
    tail_start: usize = 0,

    pub const Segment = union(enum) {
        key: []const u8,
        index: usize,
        /// Malformed bracket segment: unclosed `[`, or `[...]` whose
        /// interior is not a valid usize. Matches nothing.
        raw,
    };

    pub fn init(path: []const u8) PathIterator {
        return .{ .path = path };
    }

    pub fn next(self: *PathIterator) ?Segment {
        if (self.pos >= self.path.len) return null;
        if (self.path[self.pos] == '[') {
            if (std.mem.indexOfScalarPos(u8, self.path, self.pos + 1, ']')) |close| {
                const interior = self.path[self.pos + 1 .. close];
                self.pos = close + 1;
                self.tail_start = self.pos;
                self.skipDot();
                const idx = std.fmt.parseInt(usize, interior, 10) catch return .raw;
                return .{ .index = idx };
            }
            // Unclosed bracket: the bytes up to the next `.` (or the
            // end) form one raw segment; later `.`-separated segments
            // still iterate so `tail_start` stays exact.
            self.pos = std.mem.indexOfScalarPos(u8, self.path, self.pos + 1, '.') orelse self.path.len;
            self.skipDot();
            return .raw;
        }
        const start = self.pos;
        while (self.pos < self.path.len and self.path[self.pos] != '.' and self.path[self.pos] != '[') {
            self.pos += 1;
        }
        const segment = self.path[start..self.pos];
        self.skipDot();
        return .{ .key = segment };
    }

    fn skipDot(self: *PathIterator) void {
        if (self.pos < self.path.len and self.path[self.pos] == '.') {
            self.pos += 1;
            self.tail_start = self.pos;
        }
    }
};

/// Dynamic YAML value. Mappings preserve insertion order for
/// deterministic emit and may be keyed by any value.
pub const Value = union(enum) {
    null,
    bool: bool,
    int: i128,
    float: f64,
    string: []const u8,
    seq: []Value,
    map: []Entry,

    /// Look up a dotted path. Returns null if any segment is missing or
    /// traverses through a non-mapping. Sequence indices use `[N]`
    /// syntax: `users[0].name`, `matrix[3][7]`. A trailing `.` (e.g.,
    /// `"a."`) is stripped -- `get("a.")` and `get("a")` return the same
    /// value. Segments split on `.` and `[` (see `PathIterator`), so a
    /// key whose bytes contain either character cannot be addressed
    /// through a path. Only entries with a `.string` key are matched by a
    /// key segment; entries keyed by any other value kind are skipped.
    pub fn get(self: Value, path: []const u8) ?Value {
        var cur = self;
        var it = PathIterator.init(path);
        while (it.next()) |segment| {
            switch (segment) {
                .key => |k| {
                    if (cur != .map) return null;
                    cur = mapGet(cur.map, k) orelse return null;
                },
                .index => |idx| {
                    if (cur != .seq) return null;
                    if (idx >= cur.seq.len) return null;
                    cur = cur.seq[idx];
                },
                .raw => return null,
            }
        }
        return cur;
    }

    /// Linear-scan an entry list for the LAST entry whose key is a `.string`
    /// equal to `k`. Duplicate mapping keys are last-wins, so a later entry
    /// shadows an earlier one with the same key. Non-string keys are skipped,
    /// never matched. The single string-key lookup shared by path traversal
    /// (`get`) and typed decoding.
    pub fn mapGet(entries: []const Entry, k: []const u8) ?Value {
        var i = entries.len;
        while (i > 0) {
            i -= 1;
            const e = entries[i];
            if (e.key == .string and std.mem.eql(u8, e.key.string, k)) return e.value;
        }
        return null;
    }

    /// Deep structural equality over two Value trees. Scalars compare by
    /// value, sequences element-by-element, mappings entry-by-entry
    /// POSITIONALLY (two maps holding the same pairs in different order
    /// compare unequal). Floats compare numerically with two exceptions
    /// that make this a proper equivalence relation over parsed data: any
    /// two NaNs are equal, and +0.0 equals -0.0. Callers that must
    /// distinguish float bit patterns (e.g. emit-fidelity checks) need
    /// their own comparator.
    pub fn eql(self: Value, other: Value) bool {
        return switch (self) {
            .null => other == .null,
            .bool => |av| other == .bool and other.bool == av,
            .int => |av| other == .int and other.int == av,
            .float => |av| other == .float and blk: {
                if (std.math.isNan(av) and std.math.isNan(other.float)) break :blk true;
                break :blk av == other.float;
            },
            .string => |av| other == .string and std.mem.eql(u8, av, other.string),
            .seq => |av| other == .seq and av.len == other.seq.len and blk: {
                for (av, other.seq) |ai, bi| if (!ai.eql(bi)) break :blk false;
                break :blk true;
            },
            .map => |av| other == .map and av.len == other.map.len and blk: {
                for (av, other.map) |ai, bi| {
                    if (!ai.key.eql(bi.key)) break :blk false;
                    if (!ai.value.eql(bi.value)) break :blk false;
                }
                break :blk true;
            },
        };
    }

    /// Paired result of `locate`: the value at `path` plus its source span.
    pub const Located = struct {
        value: Value,
        span: Span,
    };

    /// Look up a value at `path` AND its source span in one call. Returns
    /// null if the path is missing OR if the span map doesn't carry an
    /// entry for this path. Avoids typing the path twice when you need
    /// both pieces. Spans are populated when `parse` was called with
    /// `ParseOptions.spans` set.
    pub fn locate(self: Value, spans: Spans, path: []const u8) ?Located {
        const v = self.get(path) orelse return null;
        const span = spans.get(path) orelse return null;
        return .{ .value = v, .span = span };
    }

    /// Look up + decode to T in one step. Returns null on missing OR on
    /// type mismatch. Supported T: bool, integer types (overflow returns
    /// null), float types (an `.int` value coerces), `[]const u8`,
    /// `Value` (passthrough).
    pub fn getT(self: Value, comptime T: type, path: []const u8) ?T {
        const v = self.get(path) orelse return null;
        if (T == Value) return v;
        return switch (@typeInfo(T)) {
            .bool => if (v == .bool) v.bool else null,
            .int => if (v == .int) std.math.cast(T, v.int) else null,
            .float => switch (v) {
                .float => |f| blk: {
                    const r: T = @floatCast(f);
                    // Finite source narrowing to inf means the f64 value exceeds floatMax(T).
                    if (!std.math.isInf(f) and std.math.isInf(r)) break :blk null;
                    break :blk r;
                },
                .int => |n| blk: {
                    const r: T = @floatFromInt(n);
                    if (std.math.isInf(r)) break :blk null;
                    break :blk r;
                },
                else => null,
            },
            .pointer => |p| if (p.size == .slice and p.child == u8 and p.is_const)
                (if (v == .string) v.string else null)
            else
                @compileError("Value.getT: only []const u8 slices supported, got " ++ @typeName(T)),
            else => @compileError("Value.getT: unsupported type " ++ @typeName(T)),
        };
    }
};

test "value getT walks scalar-keyed maps and seq indices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const inner = try a.dupe(Entry, &.{.{ .key = .{ .string = "name" }, .value = .{ .string = "ada" } }});
    const elems = try a.dupe(Value, &.{.{ .map = inner }});
    const root_entries = try a.dupe(Entry, &.{.{ .key = .{ .string = "users" }, .value = .{ .seq = elems } }});
    const root: Value = .{ .map = root_entries };

    try std.testing.expectEqualStrings("ada", root.getT([]const u8, "users[0].name").?);
    try std.testing.expectEqual(@as(?u16, null), root.getT(u16, "users[0].name"));
    try std.testing.expectEqual(@as(?u16, null), root.getT(u16, "missing"));
}

test "non-scalar-keyed entries are not addressable by string path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const keyseq = try a.dupe(Value, &.{ .{ .int = 1 }, .{ .int = 2 } });
    const entries = try a.dupe(Entry, &.{.{ .key = .{ .seq = keyseq }, .value = .{ .string = "x" } }});
    const root: Value = .{ .map = entries };
    try std.testing.expectEqual(@as(?Value, null), root.get("anything"));
}

test "Value.get: dotted path traversal three maps deep" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const inner = try a.dupe(Entry, &.{.{ .key = .{ .string = "port" }, .value = .{ .int = 8080 } }});
    const server = try a.dupe(Entry, &.{.{ .key = .{ .string = "listen" }, .value = .{ .map = inner } }});
    const root_entries = try a.dupe(Entry, &.{.{ .key = .{ .string = "server" }, .value = .{ .map = server } }});
    const root: Value = .{ .map = root_entries };

    try testing.expectEqual(@as(i128, 8080), root.get("server.listen.port").?.int);
    try testing.expect(root.get("server.listen.missing") == null);
    try testing.expect(root.get("server.missing.port") == null);
    try testing.expect(root.get("server.listen.port.deeper") == null); // can't traverse through scalar
    try testing.expectEqual(@as(i128, 8080), root.get("server.listen.port.").?.int); // trailing dot stripped
}

test "Value.get: adjacent seq indices (matrix[i][j] style)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const row0 = try a.dupe(Value, &.{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 } });
    const row1 = try a.dupe(Value, &.{ .{ .int = 4 }, .{ .int = 5 }, .{ .int = 6 } });
    const rows = try a.dupe(Value, &.{ .{ .seq = row0 }, .{ .seq = row1 } });
    const root_entries = try a.dupe(Entry, &.{.{ .key = .{ .string = "rows" }, .value = .{ .seq = rows } }});
    const root: Value = .{ .map = root_entries };

    try testing.expectEqual(@as(i128, 1), root.get("rows[0][0]").?.int);
    try testing.expectEqual(@as(i128, 6), root.get("rows[1][2]").?.int);
    try testing.expect(root.get("rows[2][0]") == null); // out of bounds
    try testing.expect(root.get("rows[0][3]") == null); // out of bounds
    try testing.expect(root.get("rows[0]nope") == null); // index into non-seq via key
}

test "Value.get: key containing a dot is unaddressable through a path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root_entries = try a.dupe(Entry, &.{.{ .key = .{ .string = "a.b" }, .value = .{ .int = 1 } }});
    const root: Value = .{ .map = root_entries };

    // The path splits into segments "a" then "b"; neither exists, so the
    // literal key "a.b" is reachable only by scanning the entries directly.
    try testing.expect(root.get("a.b") == null);
    try testing.expectEqual(@as(i128, 1), root.map[0].value.int);
}

test "Value.get: malformed paths return null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const elems = try a.dupe(Value, &.{ .{ .int = 10 }, .{ .int = 20 } });
    const inner = try a.dupe(Entry, &.{.{ .key = .{ .string = "k" }, .value = .{ .int = 1 } }});
    const root_entries = try a.dupe(Entry, &.{
        .{ .key = .{ .string = "a" }, .value = .{ .seq = elems } },
        .{ .key = .{ .string = "obj" }, .value = .{ .map = inner } },
    });
    const root: Value = .{ .map = root_entries };

    try testing.expect(root.get("a[") == null); // unclosed bracket
    try testing.expect(root.get("a[]") == null); // empty index
    try testing.expect(root.get("a[x]") == null); // non-numeric index
    try testing.expect(root.get("a[-1]") == null); // negative index
    try testing.expect(root.get("a[99999999999999999999]") == null); // usize overflow
    try testing.expect(root.get("a..b") == null); // empty segment
    try testing.expect(root.get(".a") == null); // leading dot
    try testing.expect(root.get("obj[0]") == null); // index into a map
}

test "Value.get: empty path returns self" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root_entries = try a.dupe(Entry, &.{.{ .key = .{ .string = "x" }, .value = .{ .int = 1 } }});
    const root: Value = .{ .map = root_entries };

    const whole = root.get("").?;
    try testing.expect(whole == .map);
    try testing.expectEqual(@as(usize, 1), whole.map.len);

    const scalar: Value = .{ .int = 7 };
    try testing.expectEqual(@as(i128, 7), scalar.get("").?.int);
}

test "Value.getT: typed access incl. range check and coercions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root_entries = try a.dupe(Entry, &.{
        .{ .key = .{ .string = "port" }, .value = .{ .int = 300 } },
        .{ .key = .{ .string = "pi" }, .value = .{ .float = 3.5 } },
        .{ .key = .{ .string = "tls" }, .value = .{ .bool = true } },
        .{ .key = .{ .string = "name" }, .value = .{ .string = "x" } },
        .{ .key = .{ .string = "nothing" }, .value = .null },
    });
    const root: Value = .{ .map = root_entries };

    try testing.expectEqual(@as(?u16, 300), root.getT(u16, "port"));
    try testing.expectEqual(@as(?u8, null), root.getT(u8, "port")); // 300 overflows u8
    try testing.expectEqual(@as(?f64, 3.5), root.getT(f64, "pi"));
    try testing.expectEqual(@as(?f64, 300.0), root.getT(f64, "port")); // float from int
    try testing.expectEqual(@as(?f32, 3.5), root.getT(f32, "pi"));
    try testing.expectEqual(@as(?bool, true), root.getT(bool, "tls"));
    try testing.expectEqualStrings("x", root.getT([]const u8, "name").?);

    // Wrong-type lookups return null, never error.
    try testing.expect(root.getT(u16, "name") == null);
    try testing.expect(root.getT(bool, "port") == null);
    try testing.expect(root.getT([]const u8, "tls") == null);
    try testing.expect(root.getT(f64, "name") == null);
    try testing.expect(root.getT(u16, "nothing") == null);

    // Value passthrough returns the union itself, any variant.
    const v = root.getT(Value, "nothing").?;
    try testing.expect(v == .null);
    try testing.expectEqual(@as(i128, 300), root.getT(Value, "port").?.int);
}

test "Value.locate: paired value + span lookup" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const server = try a.dupe(Entry, &.{.{ .key = .{ .string = "port" }, .value = .{ .int = 8080 } }});
    const root_entries = try a.dupe(Entry, &.{.{ .key = .{ .string = "server" }, .value = .{ .map = server } }});
    const root: Value = .{ .map = root_entries };

    var spans: Spans = .empty;
    try spans.put(a, "server.port", .{ .start = 20, .end = 24 });

    const located = root.locate(spans, "server.port").?;
    try testing.expectEqual(@as(i128, 8080), located.value.int);
    try testing.expectEqual(@as(u64, 20), located.span.start);
    try testing.expectEqual(@as(u64, 24), located.span.end);

    try testing.expect(root.locate(spans, "missing") == null);

    // Value present but spans wasn't tracked for it.
    const empty_spans: Spans = .empty;
    try testing.expect(root.locate(empty_spans, "server.port") == null);
}

test "Span is 16 bytes (u64 offsets, no line/col)" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(Span));
}

test "lineCol derives 1-indexed line/col from a byte offset" {
    const src = "ab\ncde\nf";
    // First byte.
    try testing.expectEqual(LineCol{ .line = 1, .col = 1 }, (Span{ .start = 0, .end = 0 }).lineCol(src));
    // Mid first line.
    try testing.expectEqual(LineCol{ .line = 1, .col = 2 }, (Span{ .start = 1, .end = 2 }).lineCol(src));
    // First byte after a newline.
    try testing.expectEqual(LineCol{ .line = 2, .col = 1 }, (Span{ .start = 3, .end = 4 }).lineCol(src));
    // Mid second line.
    try testing.expectEqual(LineCol{ .line = 2, .col = 3 }, (Span{ .start = 5, .end = 6 }).lineCol(src));
    // Start of third line.
    try testing.expectEqual(LineCol{ .line = 3, .col = 1 }, (Span{ .start = 7, .end = 8 }).lineCol(src));
    // Offset past end clamps to src length.
    try testing.expectEqual(LineCol{ .line = 3, .col = 2 }, (Span{ .start = 100, .end = 100 }).lineCol(src));
}

test "PathIterator: keys, indices, and adjacent brackets" {
    var it = PathIterator.init("a.b[2].c");
    try testing.expectEqualStrings("a", it.next().?.key);
    try testing.expectEqualStrings("b", it.next().?.key);
    try testing.expectEqual(@as(usize, 2), it.next().?.index);
    try testing.expectEqualStrings("c", it.next().?.key);
    try testing.expect(it.next() == null);

    var matrix = PathIterator.init("m[0][1]x");
    try testing.expectEqualStrings("m", matrix.next().?.key);
    try testing.expectEqual(@as(usize, 0), matrix.next().?.index);
    try testing.expectEqual(@as(usize, 1), matrix.next().?.index);
    try testing.expectEqualStrings("x", matrix.next().?.key);
    try testing.expect(matrix.next() == null);

    var empty = PathIterator.init("");
    try testing.expect(empty.next() == null);
}

test "Value.getT: f32 overflow on out-of-range float returns null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = try a.dupe(Entry, &.{
        .{ .key = .{ .string = "big" }, .value = .{ .float = 1e40 } },
        .{ .key = .{ .string = "ok" }, .value = .{ .float = 3.0 } },
    });
    const root: Value = .{ .map = entries };
    // 1e40 exceeds floatMax(f32) -> null, not silent +inf.
    try testing.expectEqual(@as(?f32, null), root.getT(f32, "big"));
    // In-range value returns the narrowed float.
    try testing.expectEqual(@as(?f32, 3.0), root.getT(f32, "ok"));
}

test "Value.eql: structural equality with NaN==NaN and +0/-0 equal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Scalars.
    try testing.expect((Value{ .int = 3 }).eql(.{ .int = 3 }));
    try testing.expect(!(Value{ .int = 3 }).eql(.{ .int = 4 }));
    try testing.expect(!(Value{ .int = 3 }).eql(.{ .string = "3" }));
    try testing.expect((Value{ .string = "x" }).eql(.{ .string = "x" }));
    try testing.expect((Value{ .null = {} }).eql(.null));

    // Float semantics: NaN equals NaN; +0.0 equals -0.0.
    const nan = std.math.nan(f64);
    try testing.expect((Value{ .float = nan }).eql(.{ .float = nan }));
    try testing.expect((Value{ .float = 0.0 }).eql(.{ .float = -0.0 }));
    try testing.expect(!(Value{ .float = 1.0 }).eql(.{ .float = 2.0 }));

    // Collections: element-wise / positional entry-wise.
    const s1 = try a.dupe(Value, &.{ .{ .int = 1 }, .{ .int = 2 } });
    const s2 = try a.dupe(Value, &.{ .{ .int = 1 }, .{ .int = 2 } });
    const s3 = try a.dupe(Value, &.{ .{ .int = 2 }, .{ .int = 1 } });
    try testing.expect((Value{ .seq = s1 }).eql(.{ .seq = s2 }));
    try testing.expect(!(Value{ .seq = s1 }).eql(.{ .seq = s3 }));

    const m1 = try a.dupe(Entry, &.{.{ .key = .{ .string = "k" }, .value = .{ .int = 1 } }});
    const m2 = try a.dupe(Entry, &.{.{ .key = .{ .string = "k" }, .value = .{ .int = 1 } }});
    const m3 = try a.dupe(Entry, &.{.{ .key = .{ .string = "k" }, .value = .{ .int = 2 } }});
    try testing.expect((Value{ .map = m1 }).eql(.{ .map = m2 }));
    try testing.expect(!(Value{ .map = m1 }).eql(.{ .map = m3 }));
}

test "PathIterator: trailing dot, empty segments, malformed brackets" {
    var trailing = PathIterator.init("a.");
    try testing.expectEqualStrings("a", trailing.next().?.key);
    try testing.expect(trailing.next() == null);

    var empties = PathIterator.init("a..b");
    try testing.expectEqualStrings("a", empties.next().?.key);
    try testing.expectEqualStrings("", empties.next().?.key);
    try testing.expectEqualStrings("b", empties.next().?.key);
    try testing.expect(empties.next() == null);

    var leading = PathIterator.init(".a");
    try testing.expectEqualStrings("", leading.next().?.key);
    try testing.expectEqualStrings("a", leading.next().?.key);
    try testing.expect(leading.next() == null);

    var unclosed = PathIterator.init("a[");
    try testing.expectEqualStrings("a", unclosed.next().?.key);
    try testing.expect(unclosed.next().? == .raw);
    try testing.expect(unclosed.next() == null);

    var bad_interior = PathIterator.init("a[x]b");
    try testing.expectEqualStrings("a", bad_interior.next().?.key);
    try testing.expect(bad_interior.next().? == .raw);
    try testing.expectEqualStrings("b", bad_interior.next().?.key);
    try testing.expect(bad_interior.next() == null);

    inline for (.{ "[]", "[-1]", "[99999999999999999999]" }) |p| {
        var it = PathIterator.init(p);
        try testing.expect(it.next().? == .raw);
        try testing.expect(it.next() == null);
    }
}
