// Typed decode: parseInto with defaults, optionals, and yaml_rename.
//
// Demonstrates: yaml.parseInto, struct defaults for missing fields,
// optional fields becoming null, and the yaml_rename annotation for
// a YAML key whose name differs from the Zig field name.

const std = @import("std");
const yaml = @import("yaml");

const Config = struct {
    name: []const u8,
    // Optional -- absent in the input below; becomes null.
    description: ?[]const u8 = null,
    port: u16 = 8080,
    debug: bool = false,
    server: Server,

    const Server = struct {
        host: []const u8,
        // "max-connections" is not a valid Zig identifier, so rename it.
        max_connections: u32 = 100,

        pub const yaml_rename = .{ .max_connections = "max-connections" };
    };
};

const src =
    \\name: demo
    \\port: 9000
    \\server:
    \\  host: 0.0.0.0
    \\  max-connections: 256
;

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();

    const cfg = try yaml.parseInto(Config, arena.allocator(), src, .{});

    std.debug.print("name:        {s}\n", .{cfg.name});
    std.debug.print("description: {?s}\n", .{cfg.description});
    std.debug.print("port:        {d}\n", .{cfg.port});
    std.debug.print("debug:       {}\n", .{cfg.debug});
    std.debug.print("host:        {s}\n", .{cfg.server.host});
    std.debug.print("max-conn:    {d}\n", .{cfg.server.max_connections});
}
