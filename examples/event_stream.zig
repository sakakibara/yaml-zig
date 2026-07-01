// Reader-backed streaming: EventReader, ValueStream, and materialize.
//
// Demonstrates the three streaming entry points over in-program multi-document
// buffers, using std.Io.Reader.fixed so no file I/O is needed:
//
//   (a) EventReader walking a multi-document stream, printing event kinds and
//       scalar values as they arrive.
//   (b) ValueStream iterating documents with a per-item arena reset between
//       them, printing one field per document.
//   (c) materialize: calling EventReader.materialize() at document_start to
//       compose the whole current document into a Value without stepping
//       through its individual events.

const std = @import("std");
const yaml = @import("yaml");

// Three-document multi-document stream.
const multi_doc =
    \\name: alice
    \\role: admin
    \\---
    \\name: bob
    \\role: editor
    \\---
    \\name: carol
    \\role: viewer
;

// Five small documents for the ValueStream demo.
const value_stream_src =
    \\host: alpha
    \\---
    \\host: beta
    \\---
    \\host: gamma
    \\---
    \\host: delta
    \\---
    \\host: epsilon
;

// Two-document stream for the materialize demo.
const materialize_src =
    \\---
    \\service: frontend
    \\port: 8080
    \\---
    \\service: backend
    \\port: 9090
;

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    try demoEventReader(gpa);
    try demoValueStream(gpa);
    try demomaterialize(gpa);
}

// (a) EventReader: walk a multi-document stream event by event.
fn demoEventReader(gpa: std.mem.Allocator) !void {
    std.debug.print("--- EventReader: walk multi-document stream ---\n", .{});

    var r: std.Io.Reader = .fixed(multi_doc);
    var er = yaml.EventReader.fromReader(gpa, &r, .{});
    defer er.deinit();

    while (try er.next()) |ev| {
        switch (ev.kind) {
            .stream_start, .stream_end => {},
            .document_start => std.debug.print("document_start (explicit={})\n", .{ev.explicit}),
            .document_end => std.debug.print("document_end\n", .{}),
            .mapping_start => std.debug.print("  mapping_start\n", .{}),
            .mapping_end => std.debug.print("  mapping_end\n", .{}),
            .scalar => std.debug.print("  scalar: {s}\n", .{ev.value}),
            else => {},
        }
    }
    std.debug.print("\n", .{});
}

// (b) ValueStream: compose one Value per document, resetting a per-item arena.
fn demoValueStream(gpa: std.mem.Allocator) !void {
    std.debug.print("--- ValueStream: per-document arena reset ---\n", .{});

    var r: std.Io.Reader = .fixed(value_stream_src);
    var vs = yaml.ValueStream.fromReader(gpa, &r, .{});
    defer vs.deinit();

    // A per-item arena: reset between documents to bound memory to one doc.
    var item_arena: std.heap.ArenaAllocator = .init(gpa);
    defer item_arena.deinit();

    var i: usize = 0;
    while (try vs.next(item_arena.allocator())) |v| {
        const host = v.getT([]const u8, "host") orelse "?";
        std.debug.print("doc[{d}]: host={s}\n", .{ i, host });
        i += 1;
        _ = item_arena.reset(.retain_capacity);
    }
    std.debug.print("\n", .{});
}

// (c) materialize: at document_start, compose the whole document via
//     EventReader.materialize() without stepping through its events.
fn demomaterialize(gpa: std.mem.Allocator) !void {
    std.debug.print("--- materialize: compose at document_start ---\n", .{});

    var r: std.Io.Reader = .fixed(materialize_src);
    var er = yaml.EventReader.fromReader(gpa, &r, .{});
    defer er.deinit();

    var item_arena: std.heap.ArenaAllocator = .init(gpa);
    defer item_arena.deinit();

    var doc_idx: usize = 0;
    while (try er.next()) |ev| {
        if (ev.kind != .document_start) continue;

        // At document_start: materialize() composes the whole document and
        // advances the reader past it, so the next next() call sees the
        // following document's stream framing.
        const v = try er.materialize(item_arena.allocator());
        const svc = v.getT([]const u8, "service") orelse "?";
        const port = v.getT(i64, "port") orelse 0;
        std.debug.print("doc[{d}]: service={s} port={d}\n", .{ doc_idx, svc, port });
        doc_idx += 1;
        _ = item_arena.reset(.retain_capacity);
    }
}
