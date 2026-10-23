//! KYAML emitter.
//!
//! KYAML is a strict subset of YAML: flow collections, double-quoted
//! strings, keys quoted only when they are ambiguous, and a `---` header
//! on every document. Layout matches `sigs.k8s.io/yaml/kyaml` v1.6.0
//! (MIT). The block emitter is not used for this output.
//!
//! `Value` does not keep a scalar's original spelling, so numbers,
//! booleans, and null are written the way `emit` writes them (`null`,
//! `true`, `1`, `1.0`, `.nan`). A list or mapping used as a key returns
//! `error.UnrepresentableScalar`. Comments are not represented on
//! `Value`, so none are written. Invalid UTF-8 bytes are `\xNN`, which
//! is what the reference encoder writes.

const std = @import("std");
const Io = std.Io;

const emitter = @import("emitter.zig");
const unicode = @import("kyaml_unicode.zig");
const value_mod = @import("value.zig");

pub const Value = value_mod.Value;
pub const Entry = value_mod.Entry;

const max_depth = 128;
const indent_spaces = 2;

pub const KyamlOptions = struct {
    /// One line, `, ` between entries, no trailing comma, no folded strings.
    compact: bool = false,
};

const StringFlags = struct {
    lazy_quote: bool = false,
    compact: bool = false,
};

/// One document: `---`, the body, and a trailing newline.
pub fn emitKyaml(w: *Io.Writer, value: Value, options: KyamlOptions) emitter.EmitError!void {
    try w.writeAll("---\n");
    try renderValue(w, value, 0, 0, options.compact);
    try w.writeByte('\n');
}

/// A header before every document, including the first.
pub fn emitKyamlStream(w: *Io.Writer, values: []const Value, options: KyamlOptions) emitter.EmitError!void {
    for (values) |v| try emitKyaml(w, v, options);
}

/// Typed values take the same conversion as `emitTyped`, then KYAML layout.
pub fn emitKyamlTyped(w: *Io.Writer, value: anytype, arena: std.mem.Allocator, options: KyamlOptions) emitter.EmitError!void {
    const built = try emitter.reflectValue(value, arena);
    try emitKyaml(w, built, options);
}

fn renderValue(w: *Io.Writer, v: Value, indent: usize, depth: usize, compact: bool) emitter.EmitError!void {
    switch (v) {
        .seq => |items| {
            if (depth > max_depth) return error.NestingTooDeep;
            try renderSequence(w, items, indent, depth, compact);
        },
        .map => |entries| {
            if (depth > max_depth) return error.NestingTooDeep;
            try renderMapping(w, entries, indent, depth, compact);
        },
        .string => |s| try renderString(w, s, indent + 1, .{ .compact = compact }),
        else => try emitter.writeDataScalar(w, v),
    }
}

fn renderSequence(w: *Io.Writer, items: []const Value, indent: usize, depth: usize, compact: bool) emitter.EmitError!void {
    if (items.len == 0) return w.writeAll("[]");
    if (compact) {
        try w.writeByte('[');
        for (items, 0..) |child, i| {
            if (i > 0) try w.writeAll(", ");
            try renderValue(w, child, 0, depth + 1, true);
        }
        return w.writeByte(']');
    }
    if (cuddled(items)) {
        try w.writeByte('[');
        for (items, 0..) |child, i| {
            if (i > 0) try w.writeAll(", ");
            try renderValue(w, child, indent, depth + 1, false);
        }
        return w.writeByte(']');
    }
    try w.writeAll("[\n");
    try writeIndent(w, indent);
    for (items) |child| {
        try writeIndent(w, 1);
        try renderValue(w, child, indent + 1, depth + 1, false);
        try w.writeAll(",\n");
        try writeIndent(w, indent);
    }
    try w.writeByte(']');
}

fn cuddled(items: []const Value) bool {
    for (items) |child| switch (child) {
        .seq, .map => {},
        else => return false,
    };
    return true;
}

fn renderMapping(w: *Io.Writer, entries: []const Entry, indent: usize, depth: usize, compact: bool) emitter.EmitError!void {
    if (entries.len == 0) return w.writeAll("{}");
    if (compact) {
        try w.writeByte('{');
        for (entries, 0..) |e, i| {
            if (i > 0) try w.writeAll(", ");
            try renderKey(w, e.key, 0);
            try w.writeAll(": ");
            try renderValue(w, e.value, 0, depth + 1, true);
        }
        return w.writeByte('}');
    }
    try w.writeAll("{\n");
    for (entries) |e| {
        try writeIndent(w, indent + 1);
        try renderKey(w, e.key, indent + 1);
        try w.writeAll(": ");
        try renderValue(w, e.value, indent + 1, depth + 1, false);
        try w.writeAll(",\n");
    }
    try writeIndent(w, indent);
    try w.writeByte('}');
}

fn renderKey(w: *Io.Writer, key: Value, indent: usize) emitter.EmitError!void {
    switch (key) {
        .seq, .map => return error.UnrepresentableScalar,
        .string => |s| try renderString(w, s, indent, .{ .lazy_quote = true, .compact = true }),
        else => {
            var buf: [128]u8 = undefined;
            var fw = Io.Writer.fixed(&buf);
            try emitter.writeDataScalar(&fw, key);
            try renderString(w, fw.buffered(), indent, .{ .lazy_quote = true, .compact = true });
        },
    }
}

fn writeIndent(w: *Io.Writer, level: usize) emitter.EmitError!void {
    try w.splatByteAll(' ', indent_spaces * level);
}

fn renderString(w: *Io.Writer, val: []const u8, indent: usize, flags: StringFlags) emitter.EmitError!void {
    const multi = std.mem.indexOfScalar(u8, val, '\n') != null;
    if (!multi and flags.lazy_quote and !needsQuotes(val)) return w.writeAll(val);

    var after_newline = false;
    try w.writeByte('"');
    if (multi and !flags.compact) {
        try w.writeAll("\\\n");
        after_newline = true;
    }

    var i: usize = 0;
    while (i < val.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(val[i]) catch {
            try writeHexByte(w, &after_newline, val[i]);
            i += 1;
            continue;
        };
        if (i + seq_len > val.len) {
            try writeHexByte(w, &after_newline, val[i]);
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(val[i..][0..seq_len]) catch {
            try writeHexByte(w, &after_newline, val[i]);
            i += 1;
            continue;
        };
        try appendEscaped(w, &after_newline, cp, indent, flags.compact);
        i += seq_len;
    }

    if (multi and !flags.compact) {
        if (!after_newline) try w.writeAll("\\\n");
        try writeIndent(w, indent);
    }
    try w.writeByte('"');
}

fn writeHexByte(w: *Io.Writer, after_newline: *bool, b: u8) emitter.EmitError!void {
    const hex = "0123456789abcdef";
    try w.writeAll("\\x");
    try w.writeByte(hex[b >> 4]);
    try w.writeByte(hex[b & 0xf]);
    after_newline.* = false;
}

fn appendEscaped(w: *Io.Writer, after_newline: *bool, r: u21, indent: usize, compact: bool) emitter.EmitError!void {
    if (after_newline.*) {
        try writeIndent(w, indent);
        if (unicode.isSpace(r) and r != '\n') {
            try w.writeByte('\\');
        } else {
            try w.writeByte(' ');
        }
        after_newline.* = false;
    }
    if (r == '\n') {
        if (compact) return writeTracked(w, after_newline, "\\n");
        return writeTracked(w, after_newline, "\\n\\\n");
    }
    if (r == '\t') {
        if (compact) return writeTracked(w, after_newline, "\\t");
        return writeTracked(w, after_newline, "\t");
    }
    if (r == '"' or r == '\\') {
        try w.writeByte('\\');
        try w.writeByte(@intCast(r));
        after_newline.* = false;
        return;
    }
    if (unicode.isPrint(r)) {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(r, &buf) catch unreachable;
        return writeTracked(w, after_newline, buf[0..n]);
    }
    const named: ?[]const u8 = switch (r) {
        0x07 => "\\a",
        0x08 => "\\b",
        0x0c => "\\f",
        '\r' => "\\r",
        0x0b => "\\v",
        0x00 => "\\0",
        0x1b => "\\e",
        0x85 => "\\N",
        0xa0 => "\\_",
        0x2028 => "\\L",
        0x2029 => "\\P",
        else => null,
    };
    if (named) |text| return writeTracked(w, after_newline, text);
    if (r < ' ' or r == 0x7f) {
        var buf: [4]u8 = undefined;
        buf[0] = '\\';
        buf[1] = 'x';
        const hex = "0123456789abcdef";
        buf[2] = hex[@as(u8, @intCast(r)) >> 4];
        buf[3] = hex[@as(u8, @intCast(r)) & 0xf];
        return writeTracked(w, after_newline, &buf);
    }
    if (r < 0x10000) {
        var buf: [6]u8 = undefined;
        buf[0] = '\\';
        buf[1] = 'u';
        writeHexDigits(buf[2..6], r, 4);
        return writeTracked(w, after_newline, &buf);
    }
    var buf: [10]u8 = undefined;
    buf[0] = '\\';
    buf[1] = 'U';
    writeHexDigits(buf[2..10], r, 8);
    return writeTracked(w, after_newline, &buf);
}

fn writeHexDigits(dest: []u8, r: u21, digits: usize) void {
    const hex = "0123456789abcdef";
    var i = digits;
    var v: u32 = r;
    while (i > 0) {
        i -= 1;
        dest[i] = hex[@as(u4, @intCast(v & 0xf))];
        v >>= 4;
    }
}

fn writeTracked(w: *Io.Writer, after_newline: *bool, bytes: []const u8) emitter.EmitError!void {
    if (bytes.len == 0) return;
    try w.writeAll(bytes);
    after_newline.* = bytes[bytes.len - 1] == '\n';
}

fn needsQuotes(s: []const u8) bool {
    if (s.len == 0) return true;
    if (isTypeAmbiguous(s)) return true;
    const runes = countRunes(s) orelse return true;
    var i: usize = 0;
    var rune_i: usize = 0;
    while (i < s.len) {
        const r = nextRune(s, &i) orelse return true;
        if (unicode.isLetter(r) or unicode.isNumber(r) or r == '_') {
            rune_i += 1;
            continue;
        }
        if (rune_i > 0 and rune_i + 1 < runes and (r == '-' or r == '.' or r == '/')) {
            rune_i += 1;
            continue;
        }
        return true;
    }
    return false;
}

fn countRunes(s: []const u8) ?usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) {
        _ = nextRune(s, &i) orelse return null;
        n += 1;
    }
    return n;
}

fn nextRune(s: []const u8, i: *usize) ?u21 {
    if (i.* >= s.len) return null;
    const seq_len = std.unicode.utf8ByteSequenceLength(s[i.*]) catch return null;
    if (i.* + seq_len > s.len) return null;
    const cp = std.unicode.utf8Decode(s[i.*..][0..seq_len]) catch return null;
    i.* += seq_len;
    return cp;
}

fn isTypeAmbiguous(s: []const u8) bool {
    if (s.len <= 5) {
        if (eqlFold(s, "null") or std.mem.eql(u8, s, "~") or s.len == 0) return true;
    }
    if (parseBool(s)) return true;
    if (s.len <= 5) {
        if (eqlFold(s, "true") or eqlFold(s, "y") or eqlFold(s, "yes") or eqlFold(s, "on") or
            eqlFold(s, "false") or eqlFold(s, "n") or eqlFold(s, "no") or eqlFold(s, "off"))
            return true;
    }

    var scratch: [8192]u8 = undefined;
    const stripped = stripUnderscores(s, &scratch) orelse return true;
    if (goIntOk(stripped)) return true;
    if (goFloatOk(stripped)) return true;
    if (sexagesimal(s)) return true;
    if (s.len <= 5) {
        if (eqlFold(s, ".inf") or eqlFold(s, "-.inf") or eqlFold(s, "+.inf") or eqlFold(s, ".nan")) return true;
    }
    return parseTimestamp(s);
}

fn eqlFold(s: []const u8, literal: []const u8) bool {
    return std.ascii.eqlIgnoreCase(s, literal);
}

fn stripUnderscores(s: []const u8, buf: []u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, s, '_') == null) return s;
    if (s.len > buf.len) return null;
    var n: usize = 0;
    for (s) |c| {
        if (c == '_') continue;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

fn parseBool(s: []const u8) bool {
    const words = [_][]const u8{ "1", "t", "T", "true", "TRUE", "True", "0", "f", "F", "false", "FALSE", "False" };
    for (words) |w| if (std.mem.eql(u8, s, w)) return true;
    return false;
}

/// True when `strconv.ParseInt(s, 0, 64)` would succeed. `s` has already
/// had every `_` removed.
fn goIntOk(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    var neg = false;
    if (s[0] == '+' or s[0] == '-') {
        neg = s[0] == '-';
        i = 1;
        if (i == s.len) return false;
    }
    var rest = s[i..];
    var base: u8 = 10;
    if (rest.len >= 2 and rest[0] == '0') {
        switch (rest[1]) {
            'x', 'X' => {
                base = 16;
                rest = rest[2..];
            },
            'b', 'B' => {
                base = 2;
                rest = rest[2..];
            },
            'o', 'O' => {
                base = 8;
                rest = rest[2..];
            },
            '0'...'7' => base = 8,
            '8', '9' => return false,
            else => {},
        }
    }
    if (rest.len == 0) return false;
    const mag = std.fmt.parseInt(u64, rest, base) catch return false;
    if (neg) return mag <= (@as(u64, 1) << 63);
    return mag <= std.math.maxInt(i64);
}

fn goFloatOk(s: []const u8) bool {
    if (s.len == 0) return false;
    var t = s;
    if (t[0] == '+' or t[0] == '-') {
        t = t[1..];
        if (t.len == 0) return false;
    }
    if (eqlFold(t, "inf") or eqlFold(t, "infinity") or eqlFold(t, "nan")) return true;
    _ = std.fmt.parseFloat(f64, s) catch return false;
    return true;
}

fn sexagesimal(s: []const u8) bool {
    var i: usize = 0;
    if (s.len > 0 and (s[0] == '+' or s[0] == '-')) i = 1;
    if (i >= s.len or s[i] < '1' or s[i] > '9') return false;
    i += 1;
    while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '_')) i += 1;
    var groups: usize = 0;
    while (i < s.len and s[i] == ':') {
        i += 1;
        if (i >= s.len or !std.ascii.isDigit(s[i])) return false;
        if (s[i] >= '0' and s[i] <= '5' and i + 1 < s.len and std.ascii.isDigit(s[i + 1])) {
            i += 2;
        } else {
            i += 1;
        }
        groups += 1;
    }
    if (groups == 0) return false;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '_')) i += 1;
    }
    return i == s.len;
}

const Ts = struct {
    s: []const u8,
    i: usize = 0,

    fn done(self: Ts) bool {
        return self.i == self.s.len;
    }

    fn eat(self: *Ts, c: u8) bool {
        if (self.i < self.s.len and self.s[self.i] == c) {
            self.i += 1;
            return true;
        }
        return false;
    }

    fn number(self: *Ts, min_digits: usize, max_digits: usize, min_v: u32, max_v: u32) bool {
        const start = self.i;
        var v: u32 = 0;
        var n: usize = 0;
        while (n < max_digits and self.i < self.s.len and std.ascii.isDigit(self.s[self.i])) {
            v = v * 10 + (self.s[self.i] - '0');
            self.i += 1;
            n += 1;
        }
        if (n < min_digits or v < min_v or v > max_v) {
            self.i = start;
            return false;
        }
        return true;
    }
};

fn parseTimestamp(s: []const u8) bool {
    if (s.len < 8 or s[4] != '-') return false;
    var y: usize = 0;
    while (y < 4) : (y += 1) if (!std.ascii.isDigit(s[y])) return false;
    return timestampDate(s) or timestampClock(s, 'T', true) or timestampClock(s, 't', true) or timestampClock(s, ' ', false);
}

fn timestampDate(s: []const u8) bool {
    var p: Ts = .{ .s = s };
    return p.number(4, 4, 0, 9999) and p.eat('-') and p.number(1, 2, 1, 12) and p.eat('-') and p.number(1, 2, 1, 31) and p.done();
}

fn timestampClock(s: []const u8, sep: u8, zone: bool) bool {
    var p: Ts = .{ .s = s };
    if (!(p.number(4, 4, 0, 9999) and p.eat('-') and p.number(1, 2, 1, 12) and p.eat('-') and p.number(1, 2, 1, 31))) return false;
    if (!p.eat(sep)) return false;
    if (!(p.number(2, 2, 0, 23) and p.eat(':') and p.number(1, 2, 0, 59) and p.eat(':') and p.number(1, 2, 0, 59))) return false;
    if (!p.eat('.')) return false;
    if (!p.number(1, 9, 0, 999999999)) return false;
    if (!zone) return p.done();
    if (p.eat('Z') or p.eat('z')) return p.done();
    if (!(p.eat('+') or p.eat('-'))) return false;
    if (!p.number(2, 2, 0, 23)) return false;
    if (p.done()) return true;
    if (p.eat(':')) return p.number(2, 2, 0, 59) and p.done();
    return p.number(2, 2, 0, 59) and p.done();
}

// Tests. Quoting and escape cases are the ones in kyaml v1.6.0
// (kyaml_test.go, MIT).

const parse = @import("composer.zig").parse;

fn expectRendered(s: []const u8, indent: usize, flags: StringFlags, want: []const u8) !void {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try renderString(&aw.writer, s, indent, flags);
    try std.testing.expectEqualStrings(want, aw.written());
}

test "ambiguous strings match kyaml v1.6.0" {
    const cases = [_]struct { []const u8, bool }{
        .{ "regular", false },
        .{ "abc123", false },
        .{ "hello_world", false },
        .{ "hello-world", false },
        .{ "yes", true },
        .{ "YES", true },
        .{ "y", true },
        .{ "Y", true },
        .{ "no", true },
        .{ "NO", true },
        .{ "n", true },
        .{ "N", true },
        .{ "on", true },
        .{ "ON", true },
        .{ "off", true },
        .{ "OFF", true },
        .{ "1234", true },
        .{ "_1_2_3_4_", true },
        .{ "0123", true },
        .{ "+123", true },
        .{ "-123", true },
        .{ "123456789012345678901234567890", true },
        .{ "0777", true },
        .{ "0o777", true },
        .{ "0xff", true },
        .{ "0xFF", true },
        .{ ".inf", true },
        .{ "-.inf", true },
        .{ "+.inf", true },
        .{ ".nan", true },
        .{ ".INF", true },
        .{ ".NAN", true },
        .{ "1e10", true },
        .{ "1E10", true },
        .{ "2006", true },
        .{ "2006-1-2", true },
        .{ "2006-1-2T15:4:5.999999999-08:00", true },
        .{ "2006-1-2t15:4:5.999999999-08:00", true },
        .{ "2006-1-2 14:4:5.999999999", true },
        .{ "1:00", true },
        .{ "12345:59", true },
        .{ "1:60", false },
        .{ "1:2:3:4:5:00:00:01", true },
        .{ "1:00.0", true },
        .{ "12345:59.59", true },
        .{ "12345:60.00", false },
        .{ "1:2:3:4:5:00:00:01.02", true },
        .{ "null", true },
        .{ "Null", true },
        .{ "NULL", true },
        .{ "~", true },
    };
    for (cases) |c| try std.testing.expectEqual(c[1], isTypeAmbiguous(c[0]));
}

test "string escapes match kyaml v1.6.0" {
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "\\", "\"\\\\\"", "\"\\\\\"" },
        .{ "\"", "\"\\\"\"", "\"\\\"\"" },
        .{ "\x07", "\"\\a\"", "\"\\a\"" },
        .{ "\x08", "\"\\b\"", "\"\\b\"" },
        .{ "\x0c", "\"\\f\"", "\"\\f\"" },
        .{ "\n", "\"\\\n \\n\\\n\"", "\"\\n\"" },
        .{ "\r", "\"\\r\"", "\"\\r\"" },
        .{ "\t", "\"\t\"", "\"\\t\"" },
        .{ "\x0b", "\"\\v\"", "\"\\v\"" },
        .{ "\x00", "\"\\0\"", "\"\\0\"" },
        .{ "\x1b", "\"\\e\"", "\"\\e\"" },
        .{ "\u{85}", "\"\\N\"", "\"\\N\"" },
        .{ "\u{a0}", "\"\\_\"", "\"\\_\"" },
        .{ "\u{2028}", "\"\\L\"", "\"\\L\"" },
        .{ "\u{2029}", "\"\\P\"", "\"\\P\"" },
        .{ "\x01", "\"\\x01\"", "\"\\x01\"" },
        .{ "\u{ffff}", "\"\\uffff\"", "\"\\uffff\"" },
        .{ "\u{10ffff}", "\"\\U0010ffff\"", "\"\\U0010ffff\"" },
    };
    for (cases) |c| {
        try expectRendered(c[0], 0, .{}, c[1]);
        try expectRendered(c[0], 0, .{ .compact = true }, c[2]);
    }
}

test "kyaml document frames a value and round-trips" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "name: web\ncount: 2\n", .{});
    var aw: Io.Writer.Allocating = .init(a);
    try emitKyaml(&aw.writer, v, .{});
    const text = aw.written();
    try std.testing.expect(std.mem.startsWith(u8, text, "---\n"));
    try std.testing.expect(std.mem.endsWith(u8, text, "\n"));
    const back = try parse(a, text, .{});
    try std.testing.expect(v.eql(back));
}

test "kyaml stream headers every document" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const docs = [_]Value{
        .{ .string = "one" },
        .{ .int = 2 },
    };
    var aw: Io.Writer.Allocating = .init(a);
    try emitKyamlStream(&aw.writer, &docs, .{});
    try std.testing.expectEqualStrings("---\n\"one\"\n---\n2\n", aw.written());
}

test "collection key is rejected" {
    var key_items = [_]Value{.{ .int = 1 }};
    var entries = [_]Entry{.{ .key = .{ .seq = &key_items }, .value = .{ .int = 2 } }};
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try std.testing.expectError(error.UnrepresentableScalar, emitKyaml(&aw.writer, .{ .map = &entries }, .{}));
}

test "emitKyamlTyped uses the typed conversion" {
    const Cfg = struct { name: []const u8, n: u32 };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: Io.Writer.Allocating = .init(a);
    const orig: Cfg = .{ .name = "web", .n = 2 };
    try emitKyamlTyped(&aw.writer, orig, a, .{});
    const back = try @import("decode.zig").parseInto(Cfg, a, aw.written(), .{});
    try std.testing.expectEqualStrings("web", back.name);
    try std.testing.expectEqual(@as(u32, 2), back.n);
}
