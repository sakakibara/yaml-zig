//! Bounded random-input fuzzer.
//!
//! Mutates a set of valid YAML seed documents (byte flips, inserts,
//! deletes, truncation, splices) and also throws fully random byte strings
//! at the parser. Every iteration is bounded: inputs are capped at 64 KB,
//! `max_depth` bounds the build stack, and `max_alias_nodes` bounds alias
//! amplification, so no timeout machinery is needed.
//!
//! Checked invariants per input:
//!
//! 1. `parseStream` returns a value slice or a parse error; it never
//!    crashes, hangs, or blows memory. An errors sink is attached on a
//!    coin flip to exercise the recovery path.
//! 2. If `parseStream` succeeds, `emitStream` succeeds and re-parsing the
//!    emitted output yields a deeply equal document slice.
//! 3. `ValueStream` over a fixed in-memory reader agrees with `parseStream`
//!    on both outcome (success/failure) and per-document values, exercising
//!    the reader-backed `pull()` / framing path across 4096-byte chunk
//!    boundaries. Inputs for this arm are biased toward large block scalars,
//!    long plain-scalar sequences, and long quoted scalars so that a single
//!    document spans multiple pulls.
//!
//! Usage: `zig build fuzz -- [seed] [iterations]`. Defaults are fixed, so
//! plain `zig build fuzz` is deterministic; a reported failure prints the
//! seed and iteration needed to reproduce it.

const std = @import("std");
const yaml = @import("yaml");

const default_seed: u64 = 0x79616d6c2d7a6967; // "yaml-zig"
const default_iterations: usize = 10_000;
const max_input_bytes: usize = 64 * 1024;
const max_depth: usize = 128;
// A modest alias cap so an alias bomb (`&a [*b,*b], &b [*c,*c], ...`) hits
// the budget and errors instead of expanding into gigabytes of arena.
const max_alias_nodes: usize = 100_000;

/// Valid documents covering the surface syntax: block mappings/sequences,
/// flow collections, every scalar style, anchors/aliases, multi-document
/// streams, merge keys, tags, comments, multi-line plain scalars, and
/// explicit `? :` keys. Mutation starts from these so random edits land
/// near interesting grammar.
const seed_docs = [_][]const u8{
    \\name: agent
    \\server:
    \\  host: "::1"
    \\  port: 8443
    \\  tls:
    \\    enabled: true
    \\    paths:
    \\      - /a
    \\      - /b
    \\tags: [x, y]
    \\empty_map: {}
    \\empty_seq: []
    \\flag: null
    \\tilde: ~
    ,
    \\flow: {a: 1, b: [2, 3], c: {d: 4}}
    \\nums: [0, -1, 1.5, -2.5e-3, .inf, -.inf, .nan, 0x1f, 0o17]
    \\bools: [true, false, yes, no, on, off]
    ,
    \\single: 'it''s a test'
    \\double: "quote:\" tab:\t nl:\n uni:é emoji:\U0001F600"
    \\literal: |
    \\  line one
    \\    indented
    \\  line three
    \\folded: >
    \\  folded text
    \\  wraps to space
    \\
    \\  new paragraph
    ,
    \\anchored: &base
    \\  host: localhost
    \\  port: 80
    \\alias: *base
    \\merged:
    \\  <<: *base
    \\  port: 8080
    ,
    \\---
    \\doc: one
    \\tagged: !!str 123
    \\explicitint: !!int 7
    \\local: !mytag value
    \\verbatim: !<tag:example.com,2024:thing> v
    \\...
    \\---
    \\doc: two
    \\? [composite, key]
    \\: composite value
    \\? plain key
    \\: plain value
    ,
    \\# leading comment
    \\multi line plain
    \\  scalar that folds
    \\  across three lines
    ,
    \\matrix:
    \\  - [1, 2, 3]
    \\  - [4, 5, 6]
    \\nested:
    \\  deep:
    \\    deeper:
    \\      - a
    \\      - b: c
    \\        d: e
};

const Random = std.Random;

var input_buf: [max_input_bytes]u8 = undefined;
var splice_buf: [max_input_bytes]u8 = undefined;
// Separate buffer for stream-arm inputs so both arms coexist in one iteration.
var stream_buf: [max_input_bytes]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var seed: u64 = default_seed;
    var iterations: usize = default_iterations;
    if (argv.len > 1) seed = std.fmt.parseInt(u64, argv[1], 0) catch {
        std.debug.print("fuzz: bad seed '{s}' (want integer)\n", .{argv[1]});
        std.process.exit(2);
    };
    if (argv.len > 2) iterations = std.fmt.parseInt(usize, argv[2], 0) catch {
        std.debug.print("fuzz: bad iteration count '{s}' (want integer)\n", .{argv[2]});
        std.process.exit(2);
    };

    var prng = Random.DefaultPrng.init(seed);
    const random = prng.random();

    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();

    var iter: usize = 0;
    while (iter < iterations) : (iter += 1) {
        defer _ = arena_state.reset(.retain_capacity);
        const input = generateInput(random);
        checkInput(arena_state.allocator(), random, input) catch |err| {
            std.debug.print(
                "\nfuzz FAILURE: {t}\n  seed: 0x{x}\n  iteration: {d}\n  input ({d} bytes): ",
                .{ err, seed, iter, input.len },
            );
            printEscaped(input);
            std.debug.print("\n", .{});
            std.process.exit(1);
        };

        const stream_input = generateStreamInput(random);
        checkStreamArm(arena_state.allocator(), stream_input) catch |err| {
            std.debug.print(
                "\nfuzz FAILURE (stream arm): {t}\n  seed: 0x{x}\n  iteration: {d}\n  input ({d} bytes): ",
                .{ err, seed, iter, stream_input.len },
            );
            printEscaped(stream_input);
            std.debug.print("\n", .{});
            std.process.exit(1);
        };
    }

    std.debug.print("fuzz: {d} iterations OK (seed 0x{x})\n", .{ iterations, seed });
}

/// Build one input in `input_buf`: either fully random bytes or a seed
/// document put through 1..8 random mutations.
fn generateInput(random: Random) []const u8 {
    if (random.uintLessThan(u8, 8) == 0) {
        // Fully random bytes; mostly short, occasionally multi-KB.
        const len = if (random.boolean())
            random.uintAtMost(usize, 64)
        else
            random.uintAtMost(usize, 4096);
        random.bytes(input_buf[0..len]);
        return input_buf[0..len];
    }

    const doc = seed_docs[random.uintLessThan(usize, seed_docs.len)];
    @memcpy(input_buf[0..doc.len], doc);
    var len = doc.len;

    const mutations = 1 + random.uintLessThan(usize, 8);
    var m: usize = 0;
    while (m < mutations) : (m += 1) {
        len = mutate(random, len);
        if (len == 0) break;
    }
    return input_buf[0..len];
}

/// Apply one random mutation to `input_buf[0..len]`; returns the new length.
fn mutate(random: Random, len: usize) usize {
    switch (random.uintLessThan(u8, 5)) {
        // flip one byte
        0 => {
            if (len == 0) return len;
            const pos = random.uintLessThan(usize, len);
            input_buf[pos] ^= @as(u8, 1) << random.int(u3);
            return len;
        },
        // insert a random byte
        1 => {
            if (len >= max_input_bytes) return len;
            const pos = random.uintAtMost(usize, len);
            std.mem.copyBackwards(u8, input_buf[pos + 1 .. len + 1], input_buf[pos..len]);
            input_buf[pos] = random.int(u8);
            return len + 1;
        },
        // delete one byte
        2 => {
            if (len == 0) return len;
            const pos = random.uintLessThan(usize, len);
            std.mem.copyForwards(u8, input_buf[pos .. len - 1], input_buf[pos + 1 .. len]);
            return len - 1;
        },
        // truncate
        3 => return random.uintAtMost(usize, len),
        // splice a random slice of a seed document into a random position
        4 => {
            const doc = seed_docs[random.uintLessThan(usize, seed_docs.len)];
            const start = random.uintAtMost(usize, doc.len);
            var n = random.uintAtMost(usize, doc.len - start);
            if (len + n > max_input_bytes) n = max_input_bytes - len;
            const pos = random.uintAtMost(usize, len);
            @memcpy(splice_buf[0 .. len - pos], input_buf[pos..len]);
            @memcpy(input_buf[pos .. pos + n], doc[start .. start + n]);
            @memcpy(input_buf[pos + n .. len + n], splice_buf[0 .. len - pos]);
            return len + n;
        },
        else => unreachable,
    }
}

const Failure = error{
    TypedDivergence,
    EmitFailed,
    ReparseFailed,
    RoundTripMismatch,
    SortNotStable,
    OutOfMemory,
};

fn checkInput(a: std.mem.Allocator, random: Random, input: []const u8) Failure!void {
    var diags: std.ArrayList(yaml.Diagnostic) = .empty;
    const errors_sink: ?*std.ArrayList(yaml.Diagnostic) =
        if (random.boolean()) &diags else null;

    const docs: ?[]yaml.Value = yaml.parseStream(a, input, .{
        .errors = errors_sink,
        .max_depth = max_depth,
        .max_alias_nodes = max_alias_nodes,
    }) catch |err| switch (err) {
        error.YamlParseError, error.NestingTooDeep, error.AliasBudgetExceeded => null,
        error.OutOfMemory => return error.OutOfMemory,
    };

    if (docs) |values| try checkRoundTrip(a, values);
    if (docs) |values| try checkSortStable(a, values);
    try checkTypedStream(a, input);
}

/// Typed streaming invariant: `parseInto` streams parser events for
/// eligible types and falls back to compose+decode on any error, so the
/// dangerous divergence is one-directional: the streaming pass succeeding
/// where the tree path fails, or producing a different value. Decode a
/// battery of permissive target types both ways and require agreement.
fn checkTypedStream(a: std.mem.Allocator, input: []const u8) Failure!void {
    const AllOpt = struct {
        a: ?f64 = null,
        b: ?[]const u8 = null,
        c: ?bool = null,
        tags: ?[]const []const u8 = null,
        nested: ?struct { x: ?i64 = null, y: ?[]const f64 = null } = null,
        mode: ?enum { alpha, beta } = null,
        renamed_field: ?f64 = null,
        pub const yaml_rename = .{ .renamed_field = "renamed" };
    };
    inline for (.{ AllOpt, []const AllOpt, []const f64, []const []const u8, [2]f64 }) |T| {
        const opts: yaml.ParseOptions = .{
            .ignore_unknown_fields = true,
            .max_depth = max_depth,
            .max_alias_nodes = max_alias_nodes,
        };
        const streamed_opt: ?T = yaml.parseInto(T, a, input, opts) catch |err| blk: {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            break :blk null;
        };
        const tree_opt: ?T = treeParseInto(T, a, input, opts) catch |err| blk: {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            break :blk null;
        };
        if ((streamed_opt == null) != (tree_opt == null)) return error.TypedDivergence;
        if (streamed_opt) |sv| {
            if (!eqlT(T, sv, tree_opt.?)) return error.TypedDivergence;
        }
    }
}

/// The tree path `parseInto` streams past: compose a Value, then decode.
fn treeParseInto(comptime T: type, a: std.mem.Allocator, input: []const u8, opts: yaml.ParseOptions) !T {
    const value = try yaml.parse(a, input, opts);
    return yaml.decode(T, a, value, opts);
}

/// Deep structural equality over a decoded target type.
fn eqlT(comptime T: type, x: T, y: T) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .@"enum" => x == y,
        .float => (std.math.isNan(x) and std.math.isNan(y)) or x == y,
        .optional => |o| blk: {
            if (x == null and y == null) break :blk true;
            if (x == null or y == null) break :blk false;
            break :blk eqlT(o.child, x.?, y.?);
        },
        .pointer => |p| blk: {
            if (p.child == u8 and p.is_const) break :blk std.mem.eql(u8, x, y);
            if (x.len != y.len) break :blk false;
            for (x, y) |xe, ye| {
                if (!eqlT(p.child, xe, ye)) break :blk false;
            }
            break :blk true;
        },
        .array => |arr| blk: {
            for (x, y) |xe, ye| {
                if (!eqlT(arr.child, xe, ye)) break :blk false;
            }
            break :blk true;
        },
        .@"struct" => |st| blk: {
            inline for (st.fields) |f| {
                if (!eqlT(f.type, @field(x, f.name), @field(y, f.name))) break :blk false;
            }
            break :blk true;
        },
        else => @compileError("eqlT: unsupported type " ++ @typeName(T)),
    };
}

/// Invariant 2: emit the parsed document slice, re-parse it, and require a
/// deeply equal slice back.
fn checkRoundTrip(a: std.mem.Allocator, values: []const yaml.Value) Failure!void {
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    yaml.emitStream(&aw.writer, values, .{}) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
        error.NestingTooDeep, error.UnrepresentableScalar, error.UnrepresentableInt => return error.EmitFailed,
    };

    const reparsed = yaml.parseStream(a, aw.written(), .{
        .max_depth = max_depth,
        .max_alias_nodes = max_alias_nodes,
    }) catch return error.ReparseFailed;

    if (reparsed.len != values.len) return error.RoundTripMismatch;
    for (values, reparsed) |va, vb| {
        if (!valueEql(va, vb)) return error.RoundTripMismatch;
    }
}

/// `sort_keys` invariant: emitting with it is stable. Re-parsing the
/// sorted output and re-emitting it with `sort_keys` must yield
/// byte-for-byte the same YAML, so the key order is deterministic and
/// idempotent.
fn checkSortStable(a: std.mem.Allocator, values: []const yaml.Value) Failure!void {
    var first: std.Io.Writer.Allocating = .init(a);
    defer first.deinit();
    yaml.emitStream(&first.writer, values, .{ .sort_keys = true }) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
        error.NestingTooDeep, error.UnrepresentableScalar, error.UnrepresentableInt => return error.EmitFailed,
    };

    const reparsed = yaml.parseStream(a, first.written(), .{
        .max_depth = max_depth,
        .max_alias_nodes = max_alias_nodes,
    }) catch return error.ReparseFailed;

    var second: std.Io.Writer.Allocating = .init(a);
    defer second.deinit();
    yaml.emitStream(&second.writer, reparsed, .{ .sort_keys = true }) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
        error.NestingTooDeep, error.UnrepresentableScalar, error.UnrepresentableInt => return error.EmitFailed,
    };

    if (!std.mem.eql(u8, first.written(), second.written())) return error.SortNotStable;
}

/// Deep structural equality. Floats compared bit-for-bit; mapping key
/// order significant (mirrors the conformance-suite helper; kept
/// duplicated so the fuzzer stays self-contained).
fn valueEql(a: yaml.Value, b: yaml.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    switch (a) {
        .null => return true,
        .bool => |x| return x == b.bool,
        .int => |x| return x == b.int,
        .float => |x| return @as(u64, @bitCast(x)) == @as(u64, @bitCast(b.float)),
        .string => |x| return std.mem.eql(u8, x, b.string),
        .seq => |x| {
            if (x.len != b.seq.len) return false;
            for (x, b.seq) |ea, eb| {
                if (!valueEql(ea, eb)) return false;
            }
            return true;
        },
        .map => |x| {
            if (x.len != b.map.len) return false;
            for (x, b.map) |ea, eb| {
                if (!valueEql(ea.key, eb.key)) return false;
                if (!valueEql(ea.value, eb.value)) return false;
            }
            return true;
        },
    }
}

/// Print `input` as a double-quoted string with non-printable bytes as
/// \xNN escapes, so a failing case can be pasted into a regression test.
fn printEscaped(input: []const u8) void {
    std.debug.print("\"", .{});
    for (input) |byte| {
        switch (byte) {
            '"' => std.debug.print("\\\"", .{}),
            '\\' => std.debug.print("\\\\", .{}),
            ' '...'!', '#'...'[', ']'...'~' => std.debug.print("{c}", .{byte}),
            else => std.debug.print("\\x{x:0>2}", .{byte}),
        }
    }
    std.debug.print("\"", .{});
}

// Stream arm (invariant 3)

const StreamArmError = error{
    /// ValueStream succeeded (returned documents) but parseStream failed.
    StreamSucceededBufferedFailed,
    /// ValueStream failed but parseStream succeeded.
    StreamFailedBufferedSucceeded,
    /// Both succeeded but document counts differ.
    StreamDocCountMismatch,
    /// Both succeeded and counts match but a per-document value differs.
    StreamDocValueMismatch,
    OutOfMemory,
};

/// Build one stream-arm input in `stream_buf`: 1-in-8 is a copy of a
/// regular (potentially small) input; the rest are large YAML documents
/// biased toward block scalars, long sequences, and long quoted scalars
/// whose bodies span multiple 4096-byte pull() chunks.
fn generateStreamInput(random: Random) []const u8 {
    switch (random.uintLessThan(u8, 8)) {
        0 => {
            // Small input: exercises error paths and the single-pull case.
            const small = generateInput(random);
            @memcpy(stream_buf[0..small.len], small);
            return stream_buf[0..small.len];
        },
        1, 2 => return buildDocEndStraddleInput(random),
        else => return buildLargeStreamInput(random),
    }
}

/// Build a document whose `...` end-marker (and its `...` / `... x` / `... #c`
/// line tail) straddles a pull-boundary multiple. This is the case the arm
/// previously never generated: when the pull cut falls between `...` and its
/// tail, the framer sees a buffer-end stream_end that is NOT true EOF, and a
/// premature boundary commit split the stray tail into phantom documents. The
/// pad width places the marker at and around 4096-byte scan sizes (4096, 12288,
/// 28672 are the geometric scan points; 8192 exercises full-buffer framing),
/// with a few bytes of jitter so both sides of the cut are hit.
fn buildDocEndStraddleInput(random: Random) []const u8 {
    const boundaries = [_]usize{ 4096, 8192, 12288, 28672 };
    const b = boundaries[random.uintLessThan(usize, boundaries.len)];
    const jitter: i64 = @as(i64, @intCast(random.uintAtMost(usize, 12))) - 6;

    const prefix = "---\nk: ";
    const tails = [_][]const u8{ "\n...\n", "\n... x\n", "\n... #c\n" };
    const tail = tails[random.uintLessThan(usize, tails.len)];
    const suffix = "---\nsecond: 1\n";

    // `...` ends at prefix.len + pad + len("\n...") bytes; solve so that end
    // lands near `b`, then let jitter walk it across the boundary.
    var pad: i64 = @as(i64, @intCast(b)) - @as(i64, @intCast(prefix.len)) - 4 + jitter;
    if (pad < 1) pad = 1;

    var pos: usize = 0;
    @memcpy(stream_buf[pos .. pos + prefix.len], prefix);
    pos += prefix.len;
    const room = max_input_bytes - pos - tail.len - suffix.len;
    const pad_room = @min(@as(usize, @intCast(pad)), room);
    @memset(stream_buf[pos .. pos + pad_room], 'a');
    pos += pad_room;
    @memcpy(stream_buf[pos .. pos + tail.len], tail);
    pos += tail.len;
    @memcpy(stream_buf[pos .. pos + suffix.len], suffix);
    pos += suffix.len;
    return stream_buf[0..pos];
}

/// Build an input of 8 KiB to 64 KiB in `stream_buf`. An optional seed
/// document prefix is followed by a large block scalar, plain-scalar
/// sequence, or double-quoted scalar chosen at random, ensuring multiple
/// pull() calls during framing.
fn buildLargeStreamInput(random: Random) []const u8 {
    const target: usize = 8192 + random.uintAtMost(usize, max_input_bytes - 8193);
    var pos: usize = 0;

    if (random.boolean()) {
        const doc = seed_docs[random.uintLessThan(usize, seed_docs.len)];
        @memcpy(stream_buf[pos .. pos + doc.len], doc);
        pos += doc.len;
        if (pos + 5 <= max_input_bytes) {
            @memcpy(stream_buf[pos .. pos + 5], "\n---\n");
            pos += 5;
        }
    }

    pos = switch (random.uintLessThan(u8, 4)) {
        0 => appendBlockBody(pos, target, '|'),
        1 => appendBlockBody(pos, target, '>'),
        2 => appendPlainLines(pos, target),
        3 => appendQuotedScalar(pos, target),
        else => unreachable,
    };

    return stream_buf[0..pos];
}

/// Append a block scalar header (`data: |` or `data: >`) followed by
/// indented 62-character lines of 'a' until `target` bytes are reached.
fn appendBlockBody(pos_in: usize, target: usize, style: u8) usize {
    var pos = pos_in;
    if (pos + 8 > max_input_bytes) return pos;
    @memcpy(stream_buf[pos .. pos + 6], "data: ");
    stream_buf[pos + 6] = style;
    stream_buf[pos + 7] = '\n';
    pos += 8;
    while (pos < target and pos + 64 <= max_input_bytes) {
        @memcpy(stream_buf[pos .. pos + 2], "  ");
        @memset(stream_buf[pos + 2 .. pos + 62], 'a');
        stream_buf[pos + 62] = '\n';
        pos += 63;
    }
    return pos;
}

/// Append a block sequence of 62-character 'a'-filled plain scalars until
/// `target` bytes are reached.
fn appendPlainLines(pos_in: usize, target: usize) usize {
    var pos = pos_in;
    while (pos < target and pos + 64 <= max_input_bytes) {
        @memcpy(stream_buf[pos .. pos + 2], "- ");
        @memset(stream_buf[pos + 2 .. pos + 62], 'a');
        stream_buf[pos + 62] = '\n';
        pos += 63;
    }
    return pos;
}

/// Append a double-quoted scalar of 'a' characters until `target` bytes
/// are reached, closed with `"` and a newline.
fn appendQuotedScalar(pos_in: usize, target: usize) usize {
    var pos = pos_in;
    if (pos + 3 > max_input_bytes) return pos;
    stream_buf[pos] = '"';
    pos += 1;
    while (pos < target and pos + 2 < max_input_bytes) {
        stream_buf[pos] = 'a';
        pos += 1;
    }
    stream_buf[pos] = '"';
    pos += 1;
    if (pos < max_input_bytes) {
        stream_buf[pos] = '\n';
        pos += 1;
    }
    return pos;
}

/// Invariant 3: `ValueStream` over a fixed in-memory reader must agree with
/// `parseStream` on success/failure and, when both succeed, on document count
/// and per-document deep-equal value. Divergence on any axis is a failure.
fn checkStreamArm(a: std.mem.Allocator, input: []const u8) StreamArmError!void {
    const buf_docs: ?[]yaml.Value = yaml.parseStream(a, input, .{
        .max_depth = max_depth,
        .max_alias_nodes = max_alias_nodes,
    }) catch |err| switch (err) {
        error.YamlParseError, error.NestingTooDeep, error.AliasBudgetExceeded => null,
        error.OutOfMemory => return error.OutOfMemory,
    };

    var r: std.Io.Reader = .fixed(input);
    var vs = yaml.ValueStream.fromReader(a, &r, .{
        .max_depth = max_depth,
        .max_alias_nodes = max_alias_nodes,
    });
    defer vs.deinit();

    var streamed: std.ArrayList(yaml.Value) = .empty;
    var stream_ok = true;
    while (stream_ok) {
        const v = vs.next(a) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                stream_ok = false;
                break;
            },
        };
        const val = v orelse break;
        try streamed.append(a, val);
    }

    if (stream_ok != (buf_docs != null)) {
        return if (stream_ok) error.StreamSucceededBufferedFailed else error.StreamFailedBufferedSucceeded;
    }
    if (buf_docs) |docs| {
        if (streamed.items.len != docs.len) return error.StreamDocCountMismatch;
        for (docs, streamed.items) |bv, sv| {
            if (!valueEql(bv, sv)) return error.StreamDocValueMismatch;
        }
    }
}
