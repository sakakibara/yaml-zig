//! Scalar resolution schemas (YAML 1.2.2).
//!
//! Given a plain (untagged) scalar's string content, decide which core
//! type tag it carries and produce a resolved `Value`. This module owns
//! all the schema resolution predicates in one place and has no scanner
//! or parser dependency: it is testable in isolation.
//!
//! The three schemas form a ladder of strictness (failsafe < json < core):
//! - `failsafe`: every scalar stays a string.
//! - `json`: the JSON data model (null/true/false/number), strict grammar.
//! - `core`: JSON plus YAML conveniences (~, Null, hex/octal, .inf/.nan,
//!   leading +). The default for most YAML 1.2 processors.
//!
//! Output lifetime: `.string` results are duped into `arena`. Zero-copy
//! is the composer's concern, not this module's.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;

pub const Schema = enum { failsafe, json, core };

pub fn resolve(schema: Schema, arena: std.mem.Allocator, plain: []const u8) std.mem.Allocator.Error!Value {
    return switch (schema) {
        .failsafe => asString(arena, plain),
        .core => resolveCore(arena, plain),
        .json => resolveJson(arena, plain),
    };
}

fn asString(arena: std.mem.Allocator, plain: []const u8) std.mem.Allocator.Error!Value {
    return .{ .string = try arena.dupe(u8, plain) };
}

// Core schema (tag:yaml.org,2002:{null,bool,int,float})

fn resolveCore(arena: std.mem.Allocator, plain: []const u8) std.mem.Allocator.Error!Value {
    if (coreNull(plain)) return .null;
    if (coreBool(plain)) |b| return .{ .bool = b };
    if (coreInt(plain)) |i| return .{ .int = i };
    if (coreFloat(plain)) |f| return .{ .float = f };
    return asString(arena, plain);
}

/// tag:yaml.org,2002:null -- `~`, `null`/`Null`/`NULL`, or empty.
fn coreNull(plain: []const u8) bool {
    return plain.len == 0 or
        std.mem.eql(u8, plain, "~") or
        std.mem.eql(u8, plain, "null") or
        std.mem.eql(u8, plain, "Null") or
        std.mem.eql(u8, plain, "NULL");
}

/// tag:yaml.org,2002:bool -- exactly true|True|TRUE|false|False|FALSE.
/// 1.1-only spellings (yes/no/on/off) are deliberately NOT booleans.
fn coreBool(plain: []const u8) ?bool {
    if (std.mem.eql(u8, plain, "true") or std.mem.eql(u8, plain, "True") or std.mem.eql(u8, plain, "TRUE")) return true;
    if (std.mem.eql(u8, plain, "false") or std.mem.eql(u8, plain, "False") or std.mem.eql(u8, plain, "FALSE")) return false;
    return null;
}

/// tag:yaml.org,2002:int -- base-10 `[-+]?[0-9]+`, octal `0o[0-7]+`, hex
/// `0x[0-9a-fA-F]+`. No underscores, no binary (1.1 only). Overflow of
/// i128 returns null so float/string resolution can take over.
fn coreInt(plain: []const u8) ?i128 {
    if (plain.len == 0) return null;

    // Hex and octal have no sign and a fixed lowercase prefix (1.2 Core
    // is `0x`/`0o` only; uppercase prefixes are not part of the schema).
    if (plain.len > 2 and plain[0] == '0' and plain[1] == 'x') {
        const digits = plain[2..];
        for (digits) |c| if (!std.ascii.isHex(c)) return null;
        return std.fmt.parseInt(i128, digits, 16) catch null;
    }
    if (plain.len > 2 and plain[0] == '0' and plain[1] == 'o') {
        const digits = plain[2..];
        for (digits) |c| if (c < '0' or c > '7') return null;
        return std.fmt.parseInt(i128, digits, 8) catch null;
    }

    var i: usize = 0;
    if (plain[0] == '+' or plain[0] == '-') i = 1;
    if (i == plain.len) return null;
    for (plain[i..]) |c| if (c < '0' or c > '9') return null;
    return std.fmt.parseInt(i128, plain, 10) catch null;
}

/// tag:yaml.org,2002:float -- `[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?`,
/// plus `[-+]?\.(inf|Inf|INF)` and `\.(nan|NaN|NAN)`. inf/nan are built
/// explicitly; the numeric forms go through std.fmt.parseFloat after the
/// grammar is validated (parseFloat is more permissive than YAML alone).
fn coreFloat(plain: []const u8) ?f64 {
    if (coreInfNan(plain)) |f| return f;
    if (!isCoreFloatGrammar(plain)) return null;
    return std.fmt.parseFloat(f64, plain) catch null;
}

fn coreInfNan(plain: []const u8) ?f64 {
    var s = plain;
    var neg = false;
    if (s.len > 0 and (s[0] == '+' or s[0] == '-')) {
        neg = s[0] == '-';
        s = s[1..];
    }
    if (std.mem.eql(u8, s, ".inf") or std.mem.eql(u8, s, ".Inf") or std.mem.eql(u8, s, ".INF")) {
        return if (neg) -std.math.inf(f64) else std.math.inf(f64);
    }
    // .nan takes no sign in the schema; only the unsigned spelling resolves.
    if (!neg and (std.mem.eql(u8, plain, ".nan") or std.mem.eql(u8, plain, ".NaN") or std.mem.eql(u8, plain, ".NAN"))) {
        return std.math.nan(f64);
    }
    return null;
}

/// Validate the numeric float grammar by hand so we don't accept forms
/// parseFloat would (hex floats, `inf`, underscores). Accepts `3.14`,
/// `.5`, `1.`, `1e3`, `-1.5e3`; requires at least one digit overall.
fn isCoreFloatGrammar(plain: []const u8) bool {
    var i: usize = 0;
    if (i < plain.len and (plain[i] == '+' or plain[i] == '-')) i += 1;

    var saw_digit = false;
    while (i < plain.len and plain[i] >= '0' and plain[i] <= '9') : (i += 1) saw_digit = true;
    if (i < plain.len and plain[i] == '.') {
        i += 1;
        while (i < plain.len and plain[i] >= '0' and plain[i] <= '9') : (i += 1) saw_digit = true;
    }
    if (!saw_digit) return false;

    if (i < plain.len and (plain[i] == 'e' or plain[i] == 'E')) {
        i += 1;
        if (i < plain.len and (plain[i] == '+' or plain[i] == '-')) i += 1;
        var saw_exp = false;
        while (i < plain.len and plain[i] >= '0' and plain[i] <= '9') : (i += 1) saw_exp = true;
        if (!saw_exp) return false;
    }
    return i == plain.len;
}

// JSON schema (the JSON data model, strict grammar)

fn resolveJson(arena: std.mem.Allocator, plain: []const u8) std.mem.Allocator.Error!Value {
    if (std.mem.eql(u8, plain, "null")) return .null;
    if (std.mem.eql(u8, plain, "true")) return .{ .bool = true };
    if (std.mem.eql(u8, plain, "false")) return .{ .bool = false };
    if (jsonInt(plain)) |i| return .{ .int = i };
    if (jsonFloat(plain)) |f| return .{ .float = f };
    return asString(arena, plain);
}

/// JSON int: `-?(0|[1-9][0-9]*)`. No leading `+`, no leading zeros, no
/// hex/octal. Overflow beyond i128 returns null to fall through to float/string.
fn jsonInt(plain: []const u8) ?i128 {
    if (!isJsonIntGrammar(plain)) return null;
    return std.fmt.parseInt(i128, plain, 10) catch null;
}

fn isJsonIntGrammar(plain: []const u8) bool {
    var i: usize = 0;
    if (i < plain.len and plain[i] == '-') i += 1;
    return parseJsonDigits(plain, &i) and i == plain.len;
}

/// JSON number: `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?`. The int
/// part forbids leading zeros; fraction and exponent each require digits.
fn jsonFloat(plain: []const u8) ?f64 {
    if (!isJsonFloatGrammar(plain)) return null;
    return std.fmt.parseFloat(f64, plain) catch null;
}

fn isJsonFloatGrammar(plain: []const u8) bool {
    var i: usize = 0;
    if (i < plain.len and plain[i] == '-') i += 1;
    if (!parseJsonDigits(plain, &i)) return false;

    if (i < plain.len and plain[i] == '.') {
        i += 1;
        var saw = false;
        while (i < plain.len and plain[i] >= '0' and plain[i] <= '9') : (i += 1) saw = true;
        if (!saw) return false;
    }
    if (i < plain.len and (plain[i] == 'e' or plain[i] == 'E')) {
        i += 1;
        if (i < plain.len and (plain[i] == '+' or plain[i] == '-')) i += 1;
        var saw = false;
        while (i < plain.len and plain[i] >= '0' and plain[i] <= '9') : (i += 1) saw = true;
        if (!saw) return false;
    }
    return i == plain.len;
}

/// Consume a JSON int part `0|[1-9][0-9]*` at `i.*`, advancing `i`.
/// Returns false (leaving `i` advanced) if no valid int part is present.
fn parseJsonDigits(plain: []const u8, i: *usize) bool {
    if (i.* >= plain.len) return false;
    if (plain[i.*] == '0') {
        i.* += 1;
        return true; // lone zero; a following digit makes it a leading zero
    }
    if (plain[i.*] < '1' or plain[i.*] > '9') return false;
    while (i.* < plain.len and plain[i.*] >= '0' and plain[i.*] <= '9') : (i.* += 1) {}
    return true;
}

// Tests

fn expectResolve(schema: Schema, plain: []const u8, expected: Value) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try resolve(schema, arena.allocator(), plain);
    try std.testing.expect(std.meta.activeTag(v) == std.meta.activeTag(expected));
    switch (expected) {
        .null => {},
        .bool => |b| try std.testing.expectEqual(b, v.bool),
        .int => |i| try std.testing.expectEqual(i, v.int),
        .float => |f| try std.testing.expectEqual(f, v.float),
        else => unreachable,
    }
}
fn expectResolveString(schema: Schema, plain: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try resolve(schema, arena.allocator(), plain);
    try std.testing.expect(v == .string);
    try std.testing.expectEqualStrings(plain, v.string);
}

test "core schema resolves nulls bools ints floats" {
    try expectResolve(.core, "null", .{ .null = {} });
    try expectResolve(.core, "~", .{ .null = {} });
    try expectResolve(.core, "", .{ .null = {} });
    try expectResolve(.core, "Null", .{ .null = {} });
    try expectResolve(.core, "NULL", .{ .null = {} });
    try expectResolve(.core, "true", .{ .bool = true });
    try expectResolve(.core, "True", .{ .bool = true });
    try expectResolve(.core, "FALSE", .{ .bool = false });
    try expectResolve(.core, "0x1A", .{ .int = 26 });
    try expectResolve(.core, "0o17", .{ .int = 15 });
    try expectResolve(.core, "-42", .{ .int = -42 });
    try expectResolve(.core, "+42", .{ .int = 42 });
    try expectResolve(.core, "3.14", .{ .float = 3.14 });
    try expectResolve(.core, ".inf", .{ .float = std.math.inf(f64) });
    try expectResolve(.core, "-.inf", .{ .float = -std.math.inf(f64) });
    try expectResolveString(.core, "hello");
    try expectResolveString(.core, "yes"); // NOT 1.2 core bool (1.1 only)
    try expectResolveString(.core, "on"); // 1.1 only
    try expectResolveString(.core, "0b101"); // binary not in 1.2 core
    try expectResolveString(.core, "1_000"); // underscores not in 1.2 core
}

test "nan resolves and is detected by bit pattern" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try resolve(.core, arena.allocator(), ".nan");
    try std.testing.expect(v == .float and std.math.isNan(v.float));
}

test "failsafe leaves everything a string" {
    try expectResolveString(.failsafe, "true");
    try expectResolveString(.failsafe, "123");
    try expectResolveString(.failsafe, "null");
    try expectResolveString(.failsafe, "");
}

test "json schema is stricter than core" {
    try expectResolve(.json, "true", .{ .bool = true });
    try expectResolve(.json, "123", .{ .int = 123 });
    try expectResolve(.json, "-1.5e3", .{ .float = -1500.0 });
    try expectResolveString(.json, "~");
    try expectResolveString(.json, ".inf");
    try expectResolveString(.json, "0x1A");
    try expectResolveString(.json, "+42"); // json has no leading +
    try expectResolveString(.json, "01"); // json has no leading zeros
}
