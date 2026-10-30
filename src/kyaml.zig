//! KYAML emitter.
//!
//! KYAML (KEP-5295) is flow-style YAML with a `---` header on every
//! document, `{}` and `[]` for every collection, a comma after every
//! entry, and double quotes around every string. Brackets of a list
//! whose items are themselves collections sit on the same line. A
//! multi-line string uses YAML's flow fold: a trailing `\` drops the
//! break and the indent on the next line, `\n` keeps a newline, and a
//! `\` before a space keeps that space. The `\` goes only before a
//! space written as itself.
//!
//! Keys are plain only when `isPlainSafe` says a flow implicit key
//! reads back as that string. A key longer than 1024 code points, and
//! a list or mapping used as a key, return `error.UnrepresentableScalar`.
//! Bytes that are not UTF-8 return `error.InvalidUtf8`, as `emit` does.
//!
//! `Value` has no comments, tags, or anchors. Aliases and merge keys
//! are already expanded. Numbers, booleans, and null use `emit`'s
//! spelling; when one of those is a key it is written as text, so it
//! reads back as a string.

const std = @import("std");
const Io = std.Io;

const emitter = @import("emitter.zig");
const value_mod = @import("value.zig");

pub const Value = value_mod.Value;
pub const Entry = value_mod.Entry;

const EmitError = emitter.EmitError;

/// Same cap as the block emitter. A hand-built tree deeper than this
/// returns `error.NestingTooDeep`.
const max_depth = 128;

/// Fold body sits at these columns. KEP-5295's examples use four spaces
/// of indent, plus one space YAML strips, on a line that does not open
/// with a space.
const fold_indent = 4;

pub const KyamlOptions = struct {
    /// One line. Entries are separated by `, `, with no trailing comma
    /// and no folded strings.
    compact: bool = false,
};

pub fn emitKyaml(w: *Io.Writer, value: Value, options: KyamlOptions) EmitError!void {
    try w.writeAll("---\n");
    try writeValue(w, value, 0, 0, options.compact);
    try w.writeByte('\n');
}

pub fn emitKyamlStream(w: *Io.Writer, values: []const Value, options: KyamlOptions) EmitError!void {
    for (values) |value| try emitKyaml(w, value, options);
}

pub fn emitKyamlTyped(w: *Io.Writer, value: anytype, arena: std.mem.Allocator, options: KyamlOptions) EmitError!void {
    const built = try emitter.reflectValue(value, arena);
    try emitKyaml(w, built, options);
}

fn writeValue(w: *Io.Writer, v: Value, indent: usize, depth: usize, compact: bool) EmitError!void {
    switch (v) {
        .null, .bool, .int, .float => try emitter.writeDataScalar(w, v),
        .string => |s| try writeString(w, s, !compact),
        .seq => |items| try writeSeq(w, items, indent, depth, compact),
        .map => |entries| try writeMap(w, entries, indent, depth, compact),
    }
}

fn writeSeq(w: *Io.Writer, items: []const Value, indent: usize, depth: usize, compact: bool) EmitError!void {
    if (depth > max_depth) return error.NestingTooDeep;
    if (items.len == 0) return w.writeAll("[]");
    if (compact or cuddled(items)) {
        try w.writeByte('[');
        for (items, 0..) |item, i| {
            if (i > 0) try w.writeAll(", ");
            try writeValue(w, item, indent, depth + 1, compact);
        }
        try w.writeByte(']');
        return;
    }
    try w.writeAll("[\n");
    for (items) |item| {
        try w.splatByteAll(' ', indent + 2);
        try writeValue(w, item, indent + 2, depth + 1, false);
        try w.writeAll(",\n");
    }
    try w.splatByteAll(' ', indent);
    try w.writeByte(']');
}

fn writeMap(w: *Io.Writer, entries: []const Entry, indent: usize, depth: usize, compact: bool) EmitError!void {
    if (depth > max_depth) return error.NestingTooDeep;
    if (entries.len == 0) return w.writeAll("{}");
    if (compact) {
        try w.writeByte('{');
        for (entries, 0..) |entry, i| {
            if (i > 0) try w.writeAll(", ");
            try writeKey(w, entry.key);
            try w.writeAll(": ");
            try writeValue(w, entry.value, indent, depth + 1, true);
        }
        try w.writeByte('}');
        return;
    }
    try w.writeAll("{\n");
    for (entries) |entry| {
        try w.splatByteAll(' ', indent + 2);
        try writeKey(w, entry.key);
        try w.writeAll(": ");
        try writeValue(w, entry.value, indent + 2, depth + 1, false);
        try w.writeAll(",\n");
    }
    try w.splatByteAll(' ', indent);
    try w.writeByte('}');
}

/// A list of collections keeps its brackets on the item's line. Comments
/// would break that, and `Value` has none.
fn cuddled(items: []const Value) bool {
    for (items) |item| {
        switch (item) {
            .seq, .map => {},
            else => return false,
        }
    }
    return items.len > 0;
}

fn writeKey(w: *Io.Writer, key: Value) EmitError!void {
    switch (key) {
        .string => |s| try writeKeyText(w, s),
        .seq, .map => return error.UnrepresentableScalar,
        else => {
            var buf: [256]u8 = undefined;
            var fw = Io.Writer.fixed(&buf);
            try emitter.writeDataScalar(&fw, key);
            try writeKeyText(w, fw.buffered());
        },
    }
}

fn writeKeyText(w: *Io.Writer, s: []const u8) EmitError!void {
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
    const n = std.unicode.utf8CountCodepoints(s) catch return error.InvalidUtf8;
    if (n > emitter.max_implicit_key_chars) return error.UnrepresentableScalar;
    if (emitter.isPlainSafe(s, .{ .flow = true, .key = true })) {
        try w.writeAll(s);
    } else {
        try writeString(w, s, false);
    }
}

fn writeString(w: *Io.Writer, s: []const u8, fold: bool) EmitError!void {
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
    if (fold and std.mem.indexOfScalar(u8, s, '\n') != null) return writeFolded(w, s);
    try w.writeByte('"');
    try writeEscaped(w, s);
    try w.writeByte('"');
}

/// Flow-fold a string that contains `\n`. Each content line ends with
/// `\`, which drops the following break and the indent. A line that
/// opens with a space writes `\` and then that space, so the space is
/// content. Any other line writes one space for alignment; YAML drops
/// it. A carriage return, vertical tab, form feed, or other space-like
/// character is escaped and does not take that prefix.
fn writeFolded(w: *Io.Writer, s: []const u8) EmitError!void {
    try w.writeAll("\"\\\n");
    var rest = s;
    while (true) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const line = if (nl) |i| rest[0..i] else rest;
        const spaces = leadingSpaces(line);
        try w.splatByteAll(' ', fold_indent);
        if (spaces > 0) {
            try w.writeByte('\\');
            try w.writeAll(line[0..spaces]);
            try writeEscaped(w, line[spaces..]);
        } else {
            try w.writeByte(' ');
            try writeEscaped(w, line);
        }
        if (nl != null) try w.writeAll("\\n");
        try w.writeAll("\\\n");
        if (nl == null) break;
        rest = rest[nl.? + 1 ..];
    }
    try w.splatByteAll(' ', fold_indent);
    try w.writeByte('"');
}

fn leadingSpaces(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len and s[i] == ' ') : (i += 1) {}
    return i;
}

fn writeEscaped(w: *Io.Writer, s: []const u8) EmitError!void {
    var it: std.unicode.Utf8Iterator = .{ .bytes = s, .i = 0 };
    while (it.nextCodepointSlice()) |bytes| {
        const cp = std.unicode.utf8Decode(bytes) catch return error.InvalidUtf8;
        switch (cp) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            0x08 => try w.writeAll("\\b"),
            0x09 => try w.writeAll("\\t"),
            0x0A => try w.writeAll("\\n"),
            0x0D => try w.writeAll("\\r"),
            0x85 => try w.writeAll("\\N"),
            0x2028 => try w.writeAll("\\L"),
            0x2029 => try w.writeAll("\\P"),
            else => if (spaceLike(cp) or cp == 0xFEFF or !printable(cp)) {
                if (cp <= 0xFF) try w.print("\\x{X:0>2}", .{cp}) else try w.print("\\u{X:0>4}", .{cp});
            } else {
                try w.writeAll(bytes);
            },
        }
    }
}

/// Space-like characters other than space and tab. They are escaped so
/// a folded line does not treat them as indent, and so they are not
/// given a `\` prefix on top of the escape.
fn spaceLike(cp: u21) bool {
    return cp == 0xA0 or (cp >= 0x2000 and cp <= 0x200A);
}

/// YAML `c-printable`, the set the block emitter uses.
fn printable(cp: u21) bool {
    return (cp >= 0x20 and cp <= 0x7E) or cp == 0x85 or (cp >= 0xA0 and cp <= 0xD7FF) or
        (cp >= 0xE000 and cp <= 0xFFFD) or cp >= 0x10000;
}

// Tests

const parse = @import("composer.zig").parse;

fn expectEmit(v: Value, compact: bool, want: []const u8) !void {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try emitKyaml(&aw.writer, v, .{ .compact = compact });
    try std.testing.expectEqualStrings(want, aw.written());
}

test "folded string keeps a newline and a leading space" {
    try expectEmit(.{ .string = "a\nb" }, false,
        \\---
        \\"\
        \\     a\n\
        \\     b\
        \\    "
    ++ "\n");
    try expectEmit(.{ .string = "a\n  b" }, false,
        \\---
        \\"\
        \\     a\n\
        \\    \  b\
        \\    "
    ++ "\n");
}

test "a folded line escapes a carriage return without a backslash prefix" {
    const text = "a\r\n\r\nb";
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try emitKyaml(&aw.writer, .{ .string = text }, .{});
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\\\\r") == null);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const back = try parse(arena.allocator(), aw.written(), .{});
    try std.testing.expectEqualStrings(text, back.string);
}

test "a folded line escapes a non-breaking space without a backslash prefix" {
    const text = "a\n\u{a0}b";
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try emitKyaml(&aw.writer, .{ .string = text }, .{});
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\\\\xA0") == null);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const back = try parse(arena.allocator(), aw.written(), .{});
    try std.testing.expectEqualStrings(text, back.string);
}

test "bytes that are not UTF-8 are an error" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try std.testing.expectError(error.InvalidUtf8, emitKyaml(&aw.writer, .{ .string = "a\xffb" }, .{}));
}

test "keys longer than 1024 code points are an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fit = try a.alloc(u8, emitter.max_implicit_key_chars);
    @memset(fit, 'k');
    const over = try a.alloc(u8, emitter.max_implicit_key_chars + 1);
    @memset(over, 'k');

    const ok_entries = try a.dupe(Entry, &.{.{ .key = .{ .string = fit }, .value = .{ .int = 1 } }});
    const bad_entries = try a.dupe(Entry, &.{.{ .key = .{ .string = over }, .value = .{ .int = 1 } }});

    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try emitKyaml(&aw.writer, .{ .map = ok_entries }, .{});
    try std.testing.expectError(error.UnrepresentableScalar, emitKyaml(&aw.writer, .{ .map = bad_entries }, .{}));
}

test "0x_ and 0b_ keys are quoted, plain words are not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = try a.dupe(Entry, &.{
        .{ .key = .{ .string = "hello" }, .value = .{ .int = 1 } },
        .{ .key = .{ .string = "0x_" }, .value = .{ .int = 2 } },
        .{ .key = .{ .string = "0b_" }, .value = .{ .int = 3 } },
        .{ .key = .{ .string = "yes" }, .value = .{ .int = 4 } },
    });
    try expectEmit(.{ .map = entries }, true, "---\n{hello: 1, \"0x_\": 2, \"0b_\": 3, \"yes\": 4}\n");
}

test "a list or mapping key is an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key_items = try a.dupe(Value, &.{.{ .int = 1 }});
    const entries = try a.dupe(Entry, &.{.{ .key = .{ .seq = key_items }, .value = .{ .int = 2 } }});
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try std.testing.expectError(error.UnrepresentableScalar, emitKyaml(&aw.writer, .{ .map = entries }, .{}));
}

test "emitKyamlTyped round-trips a struct" {
    const Row = struct { name: []const u8, n: u32 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var aw: Io.Writer.Allocating = .init(arena.allocator());
    try emitKyamlTyped(&aw.writer, Row{ .name = "web", .n = 2 }, arena.allocator(), .{});
    const back = try parse(arena.allocator(), aw.written(), .{});
    try std.testing.expectEqualStrings("web", back.getT([]const u8, "name").?);
    try std.testing.expectEqual(@as(u32, 2), back.getT(u32, "n").?);
}
