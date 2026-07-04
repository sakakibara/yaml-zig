// Source spans + rich diagnostic rendering.
//
// Demonstrates: ParseOptions.spans, Value.locate for paired value+span
// access, the line/col and byte-offset fields of Span, and
// Diagnostic.renderRich for a rustc-style error excerpt from a
// deliberately malformed input.

const std = @import("std");
const yaml = @import("yaml");

const src =
    \\server:
    \\  host: localhost
    \\  port: 8080
    \\tags:
    \\  - a
    \\  - b
    \\  - c
;

// Intentionally invalid -- an unclosed flow sequence.
const bad_src = "port: [unclosed";

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // --- spans demo ---
    var spans: yaml.Spans = .empty;
    const v = try yaml.parse(a, src, .{ .spans = &spans });

    // locate returns both the value and its byte span in one call.
    const port = v.locate(spans, "server.port").?;
    std.debug.print("server.port value: {d}\n", .{port.value.int});
    // Spans store byte offsets only; derive 1-indexed line/col on demand.
    const lc = port.span.lineCol(src);
    std.debug.print("server.port span:  bytes {d}-{d}  line {d} col {d}\n", .{
        port.span.start, port.span.end, lc.line, lc.col,
    });
    std.debug.print("server.port raw:   {s}\n", .{src[@intCast(port.span.start)..@intCast(port.span.end)]});

    const tag1 = v.locate(spans, "tags[1]").?;
    std.debug.print("tags[1] raw:       {s}\n", .{src[@intCast(tag1.span.start)..@intCast(tag1.span.end)]});

    // --- diagnostic rendering demo ---
    std.debug.print("\n--- parse error in bad input ---\n", .{});

    var errs: std.ArrayList(yaml.Diagnostic) = .empty;
    defer errs.deinit(a);

    _ = yaml.parse(a, bad_src, .{ .errors = &errs }) catch {};

    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();

    for (errs.items) |d| {
        aw.clearRetainingCapacity();
        try d.renderRich(&aw.writer, bad_src);
        std.debug.print("{s}", .{aw.written()});
    }
}
