// Lossless document editing: parse commented YAML, read, modify, emit.
//
// Demonstrates: Document.parse, Document.getT, Document.set,
// Document.setLiteral, Document.setTrailingComment, Document.remove, and
// Document.emit. The emitted document differs from the input only where
// edits were applied; all other bytes (comments, indentation, quoting,
// blank lines) are preserved exactly.

const std = @import("std");
const yaml = @import("yaml");

// A config with a header comment, a trailing comment, a nested map, and a
// list -- all of which survive editing untouched where we do not edit.
const src =
    \\# service configuration
    \\name: app
    \\server:
    \\  host: localhost
    \\  port: 8080   # listen port
    \\tags:
    \\  - alpha
    \\  - beta
    \\debug: true
;

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try yaml.Document.parse(a, src, .{});

    std.debug.print("--- before ---\n{s}\n", .{src});

    // Read through the document before editing.
    const port_before = doc.getT(u16, "server.port").?;
    std.debug.print("\nserver.port before: {d}\n\n", .{port_before});

    // set: replace an existing value in place. The trailing comment and the
    // surrounding bytes are untouched.
    try doc.set("server.port", @as(u16, 9443));

    // setLiteral: splice a verbatim flow value (no scalar normalization).
    try doc.setLiteral("tags", "[alpha, beta, gamma]");

    // setTrailingComment: add a trailing comment to a line that had none.
    try doc.setTrailingComment("name", "the service name");

    // remove: delete a key (and its whole line).
    try doc.remove("debug");

    // emit: write the edited document. Header comment, the kept trailing
    // comment, indentation, and quoting are all preserved.
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try doc.emit(&aw.writer);

    std.debug.print("--- after ---\n{s}\n", .{aw.written()});
}
