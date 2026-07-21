//! Deterministic property/round-trip battery for `Document`'s lossless
//! editor. Generates random valid YAML documents plus edit targets from a
//! fixed seed and checks the invariants a human reviewer would check by
//! hand: an edit either succeeds cleanly or leaves the document byte-
//! unchanged, a successful edit re-parses, the edited leaf reads back
//! exactly, every other leaf and every comment survives, re-applying the
//! same edit is a no-op, and removing an existing path drops it while
//! preserving its siblings. This is where the sequence-fabrication and
//! key-quoting bugs (see CHANGELOG 0.3.0) lived, so the generator leans on
//! adversarial key/value content the same way.
//!
//! Deterministic: `base_seed` plus the case index seeds each case's own
//! PRNG, so a failure is reproducible from the printed seed alone. `K`
//! (`case_count`) is fixed and small enough that the whole battery runs in
//! a few seconds; generated nesting depth and per-mapping fan-out are both
//! capped so no case can run away.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const yaml = @import("yaml.zig");
const Value = yaml.Value;
const Document = yaml.Document;

const base_seed: u64 = 0x59_414d_4c00_0001;
const case_count: usize = 3000;
const max_depth: usize = 4;
const max_fanout: usize = 4;

// Key/value content pools
//
// Fixture pools build the INITIAL generated document; new-* pools name
// segments a case creates during the edit. The two families are disjoint by
// construction so a "new" segment can never accidentally collide with one
// already present in the fixture.

const bare_keys = [_][]const u8{ "abc", "k1", "foo_bar", "name", "host", "alpha", "z9", "q" };

const adv_fixture_keys = [_][]const u8{
    "- x",        "true",        "false",    "null",
    "123",        "3.14",        "a.b.c",    "with space",
    "emb\"quote", "back\\slash", "? lead",   ": lead",
    "mid: colon", "mid #hash",   "#leading", "",
};

const new_bare_keys = [_][]const u8{ "new1", "added", "freshKey", "zzznew" };

const new_adv_keys = [_][]const u8{
    "- y",   "TRUE",       "999",         "9.5",
    "x.y.z", "has space2", "emb\"quote2", "back\\slash2",
    "? p2",  ": w2",       "p: q2",       "r #s2",
    "#c2",
};

const bare_strings = [_][]const u8{ "hello", "world", "value1", "plain text" };

const adv_fixture_strings = [_][]const u8{
    "true",        "false",        "null",         "123",
    "-5",          "3.14",         "- dash value", "emb\"quote",
    "back\\slash", "line1\nline2", "trail space ", " lead space",
    "a: b",        "c #d",         "",
};

const fixed_floats = [_]f64{ 0.0, -0.0, 1.5, -2.5, 100.0, 0.001, 42.25, 1e10, 1e-10 };

const sample_seq_values = [_]Value{ .{ .int = 1 }, .{ .int = 2 } };
const sample_map_entries = [_]yaml.Entry{.{ .key = .{ .string = "x" }, .value = .{ .int = 1 } }};

// Generator

const Span2 = struct { start: usize, end: usize };

const GenLeaf = struct { path: []const []const u8, value: Value, span: Span2 };

const GenDocument = struct {
    source: []const u8,
    leaves: []const GenLeaf,
    containers: []const []const []const u8,
    comments: []const []const u8,
    /// Every blank line and full-line comment, in the exact order they were
    /// generated: a blank line is the sentinel `""`, a comment is its exact
    /// text (e.g. `"# note 3"`). Checked as an in-order subsequence of the
    /// edited output's lines -- see invariant 5 in `runCase`.
    trivia: []const []const u8,
};

const GenCtx = struct {
    arena: Allocator,
    rng: std.Random,
    buf: std.ArrayList(u8) = .empty,
    leaves: std.ArrayList(GenLeaf) = .empty,
    containers: std.ArrayList([]const []const u8) = .empty,
    comments: std.ArrayList([]const u8) = .empty,
    trivia: std.ArrayList([]const u8) = .empty,
    comment_counter: usize = 0,
    fallback_counter: usize = 0,
    indent_step: usize,
};

/// Render a scalar `Value` to its YAML token text (no trailing newline), via
/// the library's own top-level `emit` -- the same plain/quote decision a
/// created key or value gets, so a fixture's spelling is guaranteed valid.
fn renderTok(arena: Allocator, v: Value) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    defer aw.deinit();
    try yaml.emit(&aw.writer, v, .{});
    const s = aw.written();
    return arena.dupe(u8, if (s.len > 0 and s[s.len - 1] == '\n') s[0 .. s.len - 1] else s);
}

fn appendSeg(arena: Allocator, prefix: []const []const u8, key: []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, prefix.len + 1);
    @memcpy(out[0..prefix.len], prefix);
    out[prefix.len] = key;
    return out;
}

/// A blank line, a full-line comment, or (usually) nothing, inserted before
/// the next member. Comment text is recorded so the battery can later assert
/// it survived an edit untouched; both blank lines and comments are also
/// recorded, in generation order, into `ctx.trivia` so invariant 5 can check
/// them positionally rather than as independent counts.
fn maybeTrivia(ctx: *GenCtx) !void {
    switch (ctx.rng.uintLessThan(u8, 6)) {
        0 => {
            try ctx.buf.append(ctx.arena, '\n');
            try ctx.trivia.append(ctx.arena, "");
        },
        1 => {
            const line = try std.fmt.allocPrint(ctx.arena, "# note {d}\n", .{ctx.comment_counter});
            ctx.comment_counter += 1;
            try ctx.buf.appendSlice(ctx.arena, line);
            const text = line[0 .. line.len - 1];
            try ctx.comments.append(ctx.arena, text);
            try ctx.trivia.append(ctx.arena, text);
        },
        else => {},
    }
}

fn genFixtureKey(ctx: *GenCtx, used: *std.ArrayList([]const u8)) ![]const u8 {
    var attempt: usize = 0;
    while (attempt < 20) : (attempt += 1) {
        const pool = if (ctx.rng.uintLessThan(u8, 3) == 0) &adv_fixture_keys else &bare_keys;
        const k = pool[ctx.rng.uintLessThan(usize, pool.len)];
        var dup = false;
        for (used.items) |u| {
            if (std.mem.eql(u8, u, k)) {
                dup = true;
                break;
            }
        }
        if (!dup) return k;
    }
    const k = try std.fmt.allocPrint(ctx.arena, "gen{d}", .{ctx.fallback_counter});
    ctx.fallback_counter += 1;
    return k;
}

fn genScalarValue(rng: std.Random) Value {
    return switch (rng.uintLessThan(u8, 8)) {
        0 => .null,
        1 => .{ .bool = true },
        2 => .{ .bool = false },
        3 => .{ .int = @as(i128, rng.intRangeAtMost(i64, -100000, 100000)) },
        4 => .{ .float = fixed_floats[rng.uintLessThan(usize, fixed_floats.len)] },
        5 => .{ .string = bare_strings[rng.uintLessThan(usize, bare_strings.len)] },
        else => .{ .string = adv_fixture_strings[rng.uintLessThan(usize, adv_fixture_strings.len)] },
    };
}

/// One nesting level of the generated fixture: `prefix` is registered as a
/// container (root uses the empty path), then 1..max_fanout members are
/// written, each either a scalar leaf (recorded in `ctx.leaves` with its
/// exact value-token byte span) or a nested mapping (recursed into, capped
/// at `max_depth`).
fn genMapping(ctx: *GenCtx, depth: usize, indent: usize, prefix: []const []const u8) !void {
    try ctx.containers.append(ctx.arena, prefix);
    const n = 1 + ctx.rng.uintLessThan(usize, max_fanout);
    var used: std.ArrayList([]const u8) = .empty;
    for (0..n) |_| {
        try maybeTrivia(ctx);
        const key = try genFixtureKey(ctx, &used);
        try used.append(ctx.arena, key);
        const child_path = try appendSeg(ctx.arena, prefix, key);
        const nest = depth < max_depth - 1 and ctx.rng.uintLessThan(u8, 4) == 0;

        try ctx.buf.appendNTimes(ctx.arena, ' ', indent);
        const key_text = try renderTok(ctx.arena, .{ .string = key });
        try ctx.buf.appendSlice(ctx.arena, key_text);

        if (nest) {
            try ctx.buf.appendSlice(ctx.arena, ":\n");
            try genMapping(ctx, depth + 1, indent + ctx.indent_step, child_path);
        } else {
            const val = genScalarValue(ctx.rng);
            const val_text = try renderTok(ctx.arena, val);
            try ctx.buf.appendSlice(ctx.arena, ": ");
            const start = ctx.buf.items.len;
            try ctx.buf.appendSlice(ctx.arena, val_text);
            const end = ctx.buf.items.len;
            try ctx.buf.append(ctx.arena, '\n');
            try ctx.leaves.append(ctx.arena, .{ .path = child_path, .value = val, .span = .{ .start = start, .end = end } });
        }
    }
}

fn genDocument(arena: Allocator, rng: std.Random) !GenDocument {
    var ctx: GenCtx = .{ .arena = arena, .rng = rng, .indent_step = 2 + rng.uintLessThan(usize, 3) };
    try genMapping(&ctx, 0, 0, &.{});
    return .{
        .source = try ctx.buf.toOwnedSlice(arena),
        .leaves = try ctx.leaves.toOwnedSlice(arena),
        .containers = try ctx.containers.toOwnedSlice(arena),
        .comments = try ctx.comments.toOwnedSlice(arena),
        .trivia = try ctx.trivia.toOwnedSlice(arena),
    };
}

// Edit targets

const TargetKind = enum { replace_existing, append_new, create_chain, index_missing_tail };

const Target = struct {
    kind: TargetKind,
    segments: []const []const u8 = &.{},
    dotted: []const u8 = "",
    value: Value,
    orig_span: ?Span2 = null,
    path_display: []const u8,
};

fn pickNewKey(rng: std.Random) []const u8 {
    if (rng.uintLessThan(u8, 3) == 0) return new_adv_keys[rng.uintLessThan(usize, new_adv_keys.len)];
    return new_bare_keys[rng.uintLessThan(usize, new_bare_keys.len)];
}

fn pickNewBareKey(rng: std.Random) []const u8 {
    return new_bare_keys[rng.uintLessThan(usize, new_bare_keys.len)];
}

fn genTargetValue(rng: std.Random) Value {
    return switch (rng.uintLessThan(u8, 14)) {
        0 => .{ .map = &.{} },
        1 => .{ .map = @constCast(&sample_map_entries) },
        2 => .{ .seq = &.{} },
        3 => .{ .seq = @constCast(&sample_seq_values) },
        else => genScalarValue(rng),
    };
}

fn joinDisplay(arena: Allocator, segments: []const []const u8) ![]const u8 {
    return std.mem.join(arena, "|", segments);
}

/// Pick one of the four documented edit-target shapes, weighted so the
/// common cases (replace, append) dominate but creation and the array-
/// index-in-a-missing-tail error path both get exercised. `index_missing_tail`
/// is the one shape that cannot be expressed via the segment API at all (a
/// segment is always a literal key, never re-split into an index), so it
/// alone uses the dotted string path API (`Document.setValue`) with a `[N]`
/// component -- exclusively fresh, bare-safe names disjoint from the
/// fixture's own keys, so the dotted reconstruction is never ambiguous.
fn genTarget(arena: Allocator, rng: std.Random, gen: *const GenDocument) !Target {
    const r = rng.uintLessThan(u8, 10);
    if (r < 4) {
        const leaf = gen.leaves[rng.uintLessThan(usize, gen.leaves.len)];
        return .{
            .kind = .replace_existing,
            .segments = leaf.path,
            .value = genTargetValue(rng),
            .orig_span = leaf.span,
            .path_display = try joinDisplay(arena, leaf.path),
        };
    } else if (r < 7) {
        const container = gen.containers[rng.uintLessThan(usize, gen.containers.len)];
        const segs = try appendSeg(arena, container, pickNewKey(rng));
        return .{
            .kind = .append_new,
            .segments = segs,
            .value = genTargetValue(rng),
            .path_display = try joinDisplay(arena, segs),
        };
    } else if (r < 9) {
        const container = gen.containers[rng.uintLessThan(usize, gen.containers.len)];
        const extra = 2 + rng.uintLessThan(usize, 2);
        var segs: std.ArrayList([]const u8) = .empty;
        try segs.appendSlice(arena, container);
        for (0..extra) |_| try segs.append(arena, pickNewKey(rng));
        const final = try segs.toOwnedSlice(arena);
        return .{
            .kind = .create_chain,
            .segments = final,
            .value = genTargetValue(rng),
            .path_display = try joinDisplay(arena, final),
        };
    } else {
        // A scalar value only: a container value would fail value
        // rendering before path resolution even runs (a different
        // invariant-1 case, already covered by genTargetValue elsewhere),
        // which would mask the PathNotFound this branch targets.
        const leaf_is_index = rng.boolean();
        const dotted = if (leaf_is_index)
            try std.fmt.allocPrint(arena, "{s}[{d}]", .{ pickNewBareKey(rng), rng.uintLessThan(u8, 4) })
        else
            try std.fmt.allocPrint(arena, "{s}[{d}].{s}", .{ pickNewBareKey(rng), rng.uintLessThan(u8, 4), pickNewBareKey(rng) });
        return .{
            .kind = .index_missing_tail,
            .dotted = dotted,
            .value = genScalarValue(rng),
            .path_display = dotted,
        };
    }
}

// Invariant checks

fn resolveBySegments(v: Value, segments: []const []const u8) ?Value {
    var cur = v;
    for (segments) |seg| {
        if (cur != .map) return null;
        var found: ?Value = null;
        for (cur.map) |e| {
            if (e.key == .string and std.mem.eql(u8, e.key.string, seg)) found = e.value;
        }
        cur = found orelse return null;
    }
    return cur;
}

fn segmentsEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

/// True iff `trivia` (the source's blank lines and full-line comments, in
/// generation order -- a blank is `""`, a comment is its exact text) occurs
/// as an in-order subsequence of `output`'s lines, matched WHOLE-LINE (never
/// substring) and greedily left-to-right. This is strictly stronger than a
/// global count:
///   - a dropped comment can't hide behind another comment whose text
///     happens to contain it (e.g. a lost "# note 1" masked by a surviving
///     "# note 10"), since only an EXACT line match advances the subsequence;
///   - a lost blank line can't be papered over by an unrelated blank added
///     elsewhere, since any trivia item still due AFTER the lost one (another
///     blank or a comment) would then have to match past where it actually
///     sits in `output`, which fails.
/// The trailing empty split segment produced by `output`'s own final newline
/// is dropped first so it can't stand in as a free extra blank-line match.
fn triviaIsSubsequence(arena: Allocator, trivia: []const []const u8, output: []const u8) !bool {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| try lines.append(arena, line);
    if (lines.items.len > 0 and output.len > 0 and output[output.len - 1] == '\n') {
        _ = lines.pop();
    }

    var j: usize = 0;
    for (trivia) |t| {
        var matched = false;
        while (j < lines.items.len) : (j += 1) {
            if (std.mem.eql(u8, lines.items[j], t)) {
                j += 1;
                matched = true;
                break;
            }
        }
        if (!matched) return false;
    }
    return true;
}

fn dumpCase(i: usize, seed: u64, source: []const u8, target: Target, output: []const u8) void {
    std.debug.print(
        "\n--- document_property failure ---\ncase: {d}\nseed: 0x{x}\nkind: {t}\nsource:\n{s}\npath: {s}\nvalue: {any}\noutput:\n{s}\n----------------------------------\n",
        .{ i, seed, target.kind, source, target.path_display, target.value, output },
    );
}

/// For an EXISTING leaf, `removeSegments` on a fresh parse of `gen.source`
/// must drop it while every other original leaf and comment survives. For a
/// leaf a case just created via `append_new`/`create_chain`, the same check
/// runs on the already-edited document instead, verifying the newly created
/// path can be cleanly removed too.
fn checkRemoveRoundTrip(arena: Allocator, gen: *const GenDocument, target: Target, edited_output: []const u8) !void {
    const base_source = switch (target.kind) {
        .replace_existing => gen.source,
        .append_new, .create_chain => edited_output,
        .index_missing_tail => unreachable,
    };
    var doc = try Document.parse(arena, base_source, .{});
    try doc.removeSegments(target.segments);
    var aw: Io.Writer.Allocating = .init(arena);
    try doc.emit(&aw.writer);
    const out = aw.written();
    const reparsed = try Document.parse(arena, out, .{});
    if (reparsed.docs.len == 0) return error.RemoveReparseEmpty;
    if (resolveBySegments(reparsed.docs[0], target.segments) != null) return error.RemovedPathStillPresent;

    for (gen.leaves) |leaf| {
        if (segmentsEqual(leaf.path, target.segments)) continue;
        const v = resolveBySegments(reparsed.docs[0], leaf.path) orelse return error.RemoveSiblingMissing;
        if (!v.eql(leaf.value)) return error.RemoveSiblingMismatch;
    }
    if (target.kind == .replace_existing) {
        for (gen.comments) |c| {
            if (std.mem.indexOf(u8, out, c) == null) return error.RemoveCommentLost;
        }
    }
}

fn runCase(gpa: Allocator, i: usize) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const seed = base_seed +% i;
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    const gen = try genDocument(arena, rng);
    if (gen.leaves.len == 0) return;
    const target = try genTarget(arena, rng, &gen);

    var last_output: []const u8 = "(not yet emitted)";
    errdefer dumpCase(i, seed, gen.source, target, last_output);

    if (target.kind == .index_missing_tail) {
        var doc = try Document.parse(arena, gen.source, .{});
        if (doc.setValue(target.dotted, target.value)) |_| {
            return error.ExpectedIndexInMissingTailToError;
        } else |err| {
            if (err != error.PathNotFound) return err;
            try testing.expectEqualStrings(gen.source, doc.source);
        }
        return;
    }

    var doc = try Document.parse(arena, gen.source, .{});
    if (doc.setValueSegments(target.segments, target.value)) |_| {} else |err| {
        if (err == error.OutOfMemory) return err;
        // Invariant 1: a clean error leaves the document byte-unchanged;
        // invariants 2-6 do not apply to this case.
        try testing.expectEqualStrings(gen.source, doc.source);
        return;
    }

    // Invariant 2: reparse-clean.
    var aw: Io.Writer.Allocating = .init(arena);
    try doc.emit(&aw.writer);
    last_output = aw.written();
    const reparsed = Document.parse(arena, last_output, .{}) catch return error.ReparseFailed;
    if (reparsed.docs.len == 0) return error.ReparseEmpty;

    // Invariant 3: read-back exact.
    const got = resolveBySegments(reparsed.docs[0], target.segments) orelse return error.ReadBackMissing;
    if (!got.eql(target.value)) return error.ReadBackMismatch;

    // Invariant 4: every other original leaf still resolves to its
    // original value.
    for (gen.leaves) |leaf| {
        if (segmentsEqual(leaf.path, target.segments)) continue;
        const v = resolveBySegments(reparsed.docs[0], leaf.path) orelse return error.SiblingMissing;
        if (!v.eql(leaf.value)) return error.SiblingMismatch;
    }

    // Invariant 5: every original comment and blank line survives, in the
    // same relative order, as an exact output line -- a positional loss
    // can't be masked by an unrelated blank added elsewhere, and a dropped
    // comment can't hide behind another comment's text containing it. A
    // pure value-replace on an existing leaf is additionally byte-exact
    // outside the replaced value token.
    if (!try triviaIsSubsequence(arena, gen.trivia, last_output)) return error.TriviaLost;

    if (target.kind == .replace_existing) {
        if (target.orig_span) |sp| {
            const prefix = gen.source[0..sp.start];
            const suffix = gen.source[sp.end..];
            if (last_output.len < prefix.len + suffix.len) return error.ByteExactShrunk;
            if (!std.mem.eql(u8, last_output[0..prefix.len], prefix)) return error.PrefixChanged;
            if (!std.mem.eql(u8, last_output[last_output.len - suffix.len ..], suffix)) return error.SuffixChanged;
        }
    }

    // Invariant 6: idempotence -- re-applying the same edit to the edited
    // document is a byte-identical no-op.
    var doc2 = try Document.parse(arena, last_output, .{});
    try doc2.setValueSegments(target.segments, target.value);
    var aw2: Io.Writer.Allocating = .init(arena);
    try doc2.emit(&aw2.writer);
    if (!std.mem.eql(u8, last_output, aw2.written())) return error.NotIdempotent;

    // Invariant 7: remove round-trip.
    try checkRemoveRoundTrip(arena, &gen, target, last_output);
}

test "document editor property battery: 7 invariants over randomly generated documents" {
    var i: usize = 0;
    while (i < case_count) : (i += 1) try runCase(testing.allocator, i);
}
