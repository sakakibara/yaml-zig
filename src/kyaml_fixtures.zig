//! Byte-for-byte check of tests/kyaml against sigs.k8s.io/yaml/kyaml v1.6.0.
//! The .kyaml and .compact.kyaml files are produced by tools/kyaml-golden.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const yaml = @import("yaml.zig");
const opts = @import("kyaml_fixture_options");

test "kyaml fixtures match v1.6.0 byte for byte and round-trip" {
    const io = testing.io;
    var dir = try Io.Dir.openDirAbsolute(io, opts.fixtures_path, .{ .iterate = true });
    defer dir.close(io);

    var seen: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |ent| {
        if (ent.kind != .file) continue;
        if (!std.mem.endsWith(u8, ent.name, ".yaml")) continue;
        seen += 1;
        try one(io, dir, ent.name);
    }
    try testing.expect(seen > 0);
}

fn one(io: Io, dir: Io.Dir, name: []const u8) !void {
    const a = testing.allocator;
    const src = try dir.readFileAlloc(io, name, a, .limited(1 << 20));
    defer a.free(src);
    const base = name[0 .. name.len - ".yaml".len];
    const regular_name = try std.fmt.allocPrint(a, "{s}.kyaml", .{base});
    defer a.free(regular_name);
    const compact_name = try std.fmt.allocPrint(a, "{s}.compact.kyaml", .{base});
    defer a.free(compact_name);
    const want = try dir.readFileAlloc(io, regular_name, a, .limited(1 << 20));
    defer a.free(want);
    const want_compact = try dir.readFileAlloc(io, compact_name, a, .limited(1 << 20));
    defer a.free(want_compact);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();
    const stream = std.mem.endsWith(u8, name, ".stream.yaml");

    var regular: Io.Writer.Allocating = .init(al);
    var compact: Io.Writer.Allocating = .init(al);
    if (stream) {
        const docs = try yaml.parseStream(al, src, .{});
        try yaml.emitKyamlStream(&regular.writer, docs, .{});
        try yaml.emitKyamlStream(&compact.writer, docs, .{ .compact = true });
        const back = try yaml.parseStream(al, regular.written(), .{});
        try testing.expectEqual(docs.len, back.len);
        for (docs, back) |doc, got| try testing.expect(doc.eql(got));
    } else {
        const v = try yaml.parse(al, src, .{});
        try yaml.emitKyaml(&regular.writer, v, .{});
        try yaml.emitKyaml(&compact.writer, v, .{ .compact = true });
        const back = try yaml.parse(al, regular.written(), .{});
        try testing.expect(v.eql(back));
    }
    try expectEqual(name, want, regular.written());
    try expectEqual(compact_name, want_compact, compact.written());
}

fn expectEqual(name: []const u8, want: []const u8, got: []const u8) !void {
    if (std.mem.eql(u8, want, got)) return;
    std.debug.print("{s}\n--- want ---\n{s}--- got ---\n{s}", .{ name, want, got });
    return error.Mismatch;
}
