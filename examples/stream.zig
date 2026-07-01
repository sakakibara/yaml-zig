// Multi-document stream: parseStream over ---separated documents.
//
// Demonstrates: yaml.parseStream, iterating the returned slice, and
// reading a field from each document via getT.

const std = @import("std");
const yaml = @import("yaml");

const src =
    \\name: alice
    \\role: admin
    \\---
    \\name: bob
    \\role: editor
    \\---
    \\name: carol
    \\role: viewer
;

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();

    const docs = try yaml.parseStream(arena.allocator(), src, .{});

    std.debug.print("{d} documents\n", .{docs.len});
    for (docs, 0..) |doc, i| {
        const name = doc.getT([]const u8, "name").?;
        const role = doc.getT([]const u8, "role").?;
        std.debug.print("doc[{d}]: {s} ({s})\n", .{ i, name, role });
    }
}
