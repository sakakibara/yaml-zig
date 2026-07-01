// Emit a Value as block YAML; demonstrate round-trip-safe quoting.
//
// Demonstrates: yaml.parse, yaml.emit, yaml.emitStream, and the emitter's
// quoting behavior -- the string "true" stays double-quoted so it
// round-trips as a string, not the boolean true.

const std = @import("std");
const yaml = @import("yaml");

const src =
    \\title: config
    \\enabled: true
    \\# "true" as a string must be quoted to survive a round-trip.
    \\flag_word: "true"
    \\count: 42
    \\tags:
    \\  - alpha
    \\  - beta
;

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v = try yaml.parse(a, src, .{});

    // Emit the parsed value back to YAML.
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();

    try yaml.emit(&aw.writer, v, .{});
    std.debug.print("--- emitted ---\n{s}", .{aw.written()});

    // Round-trip check: re-parse the emitted output and verify flag_word
    // is still the string "true", not the boolean true.
    const emitted = aw.written();
    const v2 = try yaml.parse(a, emitted, .{});
    const flag = v2.getT([]const u8, "flag_word").?;
    std.debug.print("flag_word after round-trip: \"{s}\" (string, not bool)\n", .{flag});
}
