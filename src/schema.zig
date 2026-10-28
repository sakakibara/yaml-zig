//! Scalar resolution schemas (YAML 1.2.2).
//!
//! Given a plain (untagged) scalar's string content, decide which core
//! type tag it carries and produce a resolved `Value`. This module owns
//! all the schema resolution predicates in one place and has no scanner
//! or parser dependency: it is testable in isolation.
//!
//! The YAML 1.2 schemas form a ladder of strictness (failsafe < json < core):
//! - `failsafe`: every scalar stays a string.
//! - `json`: the JSON data model (null/true/false/number), strict grammar.
//! - `core`: JSON plus YAML conveniences (~, Null, hex/octal, .inf/.nan,
//!   leading +). The default for most YAML 1.2 processors.
//!
//! `yaml11` is the YAML 1.1 type repository (yaml.org/type): its wider
//! booleans (`yes`, `on`, `y`...), integers in base 2, 8, 16 and 60 with
//! `_` separators, floats, timestamps, and the merge (`<<`) and value (`=`)
//! keys. Many programs still read YAML this way. Its grammar follows the
//! repository's regular expressions, reconciled with the repository's own
//! examples where the two disagree: a base-10 float's fraction may hold `_`
//! (`685.230_15e+03`), and blanks may precede a timestamp's zone
//! (`2001-12-14 21:59:43.10 -5`).
//!
//! `tagOf` names the type a schema's grammar gives a plain scalar;
//! `resolve` builds the `Value` of that type. An integer beyond i128 becomes
//! the float nearest it. A type the data model has no variant for (a 1.1
//! timestamp, merge or value key) and a 1.1 float spelling that names no
//! number (`1.2.3`, which its grammar admits) resolve to their text.
//!
//! Output lifetime: `.string` results are duped into `arena`. Zero-copy
//! is the composer's concern, not this module's.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;

pub const Schema = enum { failsafe, json, core, yaml11 };

/// The type a schema's grammar gives a plain scalar
/// (`tag:yaml.org,2002:<name>`).
pub const Tag = enum { null, bool, int, float, timestamp, merge, value, str };

pub fn tagOf(schema: Schema, plain: []const u8) Tag {
    return switch (schema) {
        .failsafe => .str,
        .json => if (isWord(plain, "null"))
            .null
        else if (isWord(plain, "true") or isWord(plain, "false"))
            .bool
        else if (isJsonIntGrammar(plain))
            .int
        else if (isJsonFloatGrammar(plain))
            .float
        else
            .str,
        .core => if (coreNull(plain))
            .null
        else if (coreBool(plain) != null)
            .bool
        else if (isCoreIntGrammar(plain))
            .int
        else if (coreInfNan(plain) != null or isCoreFloatGrammar(plain))
            .float
        else
            .str,
        .yaml11 => yaml11Tag(plain),
    };
}

pub fn resolve(schema: Schema, arena: std.mem.Allocator, plain: []const u8) std.mem.Allocator.Error!Value {
    return switch (schema) {
        .failsafe => asString(arena, plain),
        .core => resolveCore(arena, plain),
        .json => resolveJson(arena, plain),
        .yaml11 => resolveYaml11(arena, plain),
    };
}

fn asString(arena: std.mem.Allocator, plain: []const u8) std.mem.Allocator.Error!Value {
    return .{ .string = try arena.dupe(u8, plain) };
}

// Core schema (tag:yaml.org,2002:{null,bool,int,float})

fn resolveCore(arena: std.mem.Allocator, plain: []const u8) std.mem.Allocator.Error!Value {
    if (coreNull(plain)) return .null;
    if (coreBool(plain)) |b| return .{ .bool = b };
    if (isCoreIntGrammar(plain)) return coreIntValue(arena, plain);
    if (coreFloat(plain)) |f| return .{ .float = f };
    return asString(arena, plain);
}

/// tag:yaml.org,2002:null -- `~`, `null`/`Null`/`NULL`, or empty.
fn coreNull(plain: []const u8) bool {
    return plain.len == 0 or
        isWord(plain, "~") or
        isWord(plain, "null") or
        isWord(plain, "Null") or
        isWord(plain, "NULL");
}

/// tag:yaml.org,2002:bool -- exactly true|True|TRUE|false|False|FALSE.
/// 1.1-only spellings (yes/no/on/off) are deliberately NOT booleans.
fn coreBool(plain: []const u8) ?bool {
    if (isWord(plain, "true") or isWord(plain, "True") or isWord(plain, "TRUE")) return true;
    if (isWord(plain, "false") or isWord(plain, "False") or isWord(plain, "FALSE")) return false;
    return null;
}

/// tag:yaml.org,2002:int -- base-10 `[-+]?[0-9]+`, octal `0o[0-7]+`, hex
/// `0x[0-9a-fA-F]+`. No underscores, no binary (1.1 only).
fn isCoreIntGrammar(plain: []const u8) bool {
    if (plain.len > 2 and plain[0] == '0' and (plain[1] == 'x' or plain[1] == 'o')) {
        for (plain[2..]) |c| {
            if (if (plain[1] == 'x') !std.ascii.isHex(c) else (c < '0' or c > '7')) return false;
        }
        return true;
    }
    var i: usize = 0;
    if (plain.len > 0 and (plain[0] == '+' or plain[0] == '-')) i = 1;
    if (i == plain.len) return false;
    for (plain[i..]) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// The value of a core int.
fn coreIntValue(arena: std.mem.Allocator, plain: []const u8) std.mem.Allocator.Error!Value {
    if (plain.len > 2 and plain[0] == '0' and plain[1] == 'x') return wholeNumber(arena, false, 16, plain[2..]);
    if (plain.len > 2 and plain[0] == '0' and plain[1] == 'o') return wholeNumber(arena, false, 8, plain[2..]);
    return wholeNumber(arena, plain[0] == '-', 10, unsigned(plain));
}

/// A whole number written in `base` with `digits` (no sign, no separators;
/// empty is zero): an `.int` when it fits i128, else the float nearest it.
fn wholeNumber(arena: std.mem.Allocator, neg: bool, base: u8, digits: []const u8) std.mem.Allocator.Error!Value {
    const significant = std.mem.trimStart(u8, digits, "0");
    if (significant.len > 0 and pastFloatRange(@floatFromInt(significant.len - 1), base)) return infinity(neg);
    var n = try std.math.big.int.Managed.init(arena);
    if (significant.len > 0) try setDigits(&n, base, significant);
    if (neg) n.negate();
    return bigValue(n);
}

/// Whether a whole number of at least `base` to the power `exponent` is
/// past f64's range, so its nearest float is infinity: decided from its
/// length, so no arithmetic runs on digits that cannot change the result.
fn pastFloatRange(exponent: f64, base: u8) bool {
    return exponent * std.math.log2(@as(f64, @floatFromInt(base))) > 1025;
}

fn infinity(neg: bool) Value {
    return .{ .float = if (neg) -std.math.inf(f64) else std.math.inf(f64) };
}

/// Callers pass digits their grammar already checked.
fn setDigits(n: *std.math.big.int.Managed, base: u8, digits: []const u8) std.mem.Allocator.Error!void {
    n.setString(base, digits) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidBase, error.InvalidCharacter => unreachable,
    };
}

fn bigValue(n: std.math.big.int.Managed) Value {
    if (n.toInt(i128)) |i| return .{ .int = i } else |_| {}
    return .{ .float = n.toFloat(f64, .nearest_even)[0] };
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
    if (isWord(s, ".inf") or isWord(s, ".Inf") or isWord(s, ".INF")) {
        return if (neg) -std.math.inf(f64) else std.math.inf(f64);
    }
    // .nan takes no sign in the schema; only the unsigned spelling resolves.
    if (!neg and (isWord(plain, ".nan") or isWord(plain, ".NaN") or isWord(plain, ".NAN"))) {
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

// YAML 1.1 types (yaml.org/type: bool, null, int, float, timestamp,
// merge, value)

fn yaml11Tag(plain: []const u8) Tag {
    if (yaml11Null(plain)) return .null;
    if (yaml11Bool(plain) != null) return .bool;
    if (isYaml11IntGrammar(plain)) return .int;
    if (isYaml11FloatGrammar(plain)) return .float;
    if (isYaml11Timestamp(plain)) return .timestamp;
    if (isWord(plain, "<<")) return .merge;
    if (isWord(plain, "=")) return .value;
    return .str;
}

fn resolveYaml11(arena: std.mem.Allocator, plain: []const u8) std.mem.Allocator.Error!Value {
    switch (yaml11Tag(plain)) {
        .null => return .null,
        .bool => return .{ .bool = yaml11Bool(plain).? },
        .int => return yaml11IntValue(arena, plain),
        .float => if (try yaml11Float(arena, plain)) |f| return .{ .float = f },
        .timestamp, .merge, .value, .str => {},
    }
    return asString(arena, plain);
}

/// `~`, `null`/`Null`/`NULL`, or empty.
fn yaml11Null(plain: []const u8) bool {
    return coreNull(plain);
}

/// y|Y|yes|Yes|YES|true|True|TRUE|on|On|ON and their negatives.
fn yaml11Bool(plain: []const u8) ?bool {
    const yes = [_][]const u8{ "y", "Y", "yes", "Yes", "YES", "true", "True", "TRUE", "on", "On", "ON" };
    const no = [_][]const u8{ "n", "N", "no", "No", "NO", "false", "False", "FALSE", "off", "Off", "OFF" };
    inline for (yes) |w| if (isWord(plain, w)) return true;
    inline for (no) |w| if (isWord(plain, w)) return false;
    return null;
}

fn unsigned(plain: []const u8) []const u8 {
    return if (plain.len > 0 and (plain[0] == '+' or plain[0] == '-')) plain[1..] else plain;
}

fn allOf(s: []const u8, chars: []const u8) bool {
    for (s) |c| if (std.mem.findScalar(u8, chars, c) == null) return false;
    return true;
}

const decimal_chars = "0123456789";
const hex_chars = "0123456789abcdefABCDEF";

/// `[-+]?0b[0-1_]+`, `[-+]?0[0-7_]+`, `[-+]?(0|[1-9][0-9_]*)`,
/// `[-+]?0x[0-9a-fA-F_]+`, `[-+]?[1-9][0-9_]*(:[0-5]?[0-9])+`.
fn isYaml11IntGrammar(plain: []const u8) bool {
    const s = unsigned(plain);
    if (s.len == 0) return false;
    if (s.len > 2 and std.mem.startsWith(u8, s, "0b")) return allOf(s[2..], "01_");
    if (s.len > 2 and std.mem.startsWith(u8, s, "0x")) return allOf(s[2..], hex_chars ++ "_");
    if (s[0] == '0') return s.len == 1 or allOf(s[1..], "01234567_");
    if (s[0] < '1' or s[0] > '9') return false;
    const colon = std.mem.findScalar(u8, s, ':') orelse return allOf(s, decimal_chars ++ "_");
    return allOf(s[0..colon], decimal_chars ++ "_") and isSexagesimalTail(s[colon..]);
}

/// `(:[0-5]?[0-9])+`: one or more colon groups of one digit, or two with
/// the first at most 5.
fn isSexagesimalTail(tail: []const u8) bool {
    if (tail.len == 0) return false;
    var groups = std.mem.splitScalar(u8, tail[1..], ':');
    if (tail[0] != ':') return false;
    while (groups.next()) |g| {
        switch (g.len) {
            1 => if (!std.ascii.isDigit(g[0])) return false,
            2 => if (g[0] < '0' or g[0] > '5' or !std.ascii.isDigit(g[1])) return false,
            else => return false,
        }
    }
    return true;
}

/// `[-+]?([0-9][0-9_]*)?\.[0-9._]*([eE][-+][0-9]+)?` (`_` in the fraction
/// as the type's own `685.230_15e+03` writes it),
/// `[-+]?[0-9][0-9_]*(:[0-5]?[0-9])+\.[0-9_]*`, `[-+]?\.(inf|Inf|INF)`,
/// `\.(nan|NaN|NAN)`.
fn isYaml11FloatGrammar(plain: []const u8) bool {
    if (coreInfNan(plain) != null) return true;
    const s = unsigned(plain);
    const dot = std.mem.findScalar(u8, s, '.') orelse return false;
    const head = s[0..dot];
    if (std.mem.findScalar(u8, head, ':')) |colon| {
        // Base 60: the fraction takes digits and `_`.
        return head.len > 0 and std.ascii.isDigit(head[0]) and
            allOf(head[0..colon], decimal_chars ++ "_") and isSexagesimalTail(head[colon..]) and
            allOf(s[dot + 1 ..], decimal_chars ++ "_");
    }
    if (head.len > 0 and !(std.ascii.isDigit(head[0]) and allOf(head, decimal_chars ++ "_"))) return false;
    var rest = s[dot + 1 ..];
    if (std.mem.findAny(u8, rest, "eE")) |e| {
        const exp = rest[e + 1 ..];
        if (exp.len < 2 or (exp[0] != '+' and exp[0] != '-') or !allOf(exp[1..], decimal_chars)) return false;
        rest = rest[0..e];
    }
    return allOf(rest, decimal_chars ++ "._");
}

/// `[0-9]{4}-[0-9]{2}-[0-9]{2}`, or year-month-day with one- or two-digit
/// month and day, `T`, `t` or blanks, `h:mm:ss`, an optional fraction and an
/// optional zone (`Z` or `[-+]h[:mm]`), which blanks may precede.
fn isYaml11Timestamp(plain: []const u8) bool {
    var p: Cursor = .{ .s = plain };
    if (!p.digitsN(4, 4) or !p.lit('-')) return false;
    const ymd_month = p.i;
    if (p.digitsN(2, 2) and p.lit('-') and p.digitsN(2, 2) and p.end()) return true;
    p.i = ymd_month;
    if (!p.digitsN(1, 2) or !p.lit('-') or !p.digitsN(1, 2)) return false;
    if (!(p.lit('T') or p.lit('t') or p.blanks())) return false;
    if (!p.digitsN(1, 2) or !p.lit(':') or !p.digitsN(2, 2) or !p.lit(':') or !p.digitsN(2, 2)) return false;
    if (p.lit('.')) _ = p.digitsN(0, std.math.maxInt(usize));
    if (p.end()) return true;
    _ = p.blanks();
    if (p.lit('Z')) return p.end();
    if (!(p.lit('-') or p.lit('+'))) return false;
    if (!p.digitsN(1, 2)) return false;
    if (p.lit(':') and !p.digitsN(2, 2)) return false;
    return p.end();
}

const Cursor = struct {
    s: []const u8,
    i: usize = 0,

    fn end(c: *const Cursor) bool {
        return c.i == c.s.len;
    }
    fn lit(c: *Cursor, ch: u8) bool {
        if (c.i < c.s.len and c.s[c.i] == ch) {
            c.i += 1;
            return true;
        }
        return false;
    }
    fn blanks(c: *Cursor) bool {
        const start = c.i;
        while (c.i < c.s.len and (c.s[c.i] == ' ' or c.s[c.i] == '\t')) c.i += 1;
        return c.i > start;
    }
    /// Between `min` and `max` digits.
    fn digitsN(c: *Cursor, min: usize, max: usize) bool {
        const start = c.i;
        while (c.i < c.s.len and c.i - start < max and std.ascii.isDigit(c.s[c.i])) c.i += 1;
        return c.i - start >= min;
    }
};

/// The value of a 1.1 int.
fn yaml11IntValue(arena: std.mem.Allocator, plain: []const u8) std.mem.Allocator.Error!Value {
    const neg = plain.len > 0 and plain[0] == '-';
    const s = unsigned(plain);
    if (std.mem.findScalar(u8, s, ':') == null) {
        const base: u8, const body = if (std.mem.startsWith(u8, s, "0b"))
            .{ 2, s[2..] }
        else if (std.mem.startsWith(u8, s, "0x"))
            .{ 16, s[2..] }
        else if (s.len > 1 and s[0] == '0')
            .{ 8, s[1..] }
        else
            .{ 10, s };
        // The grammar lets the digits after a base prefix be all `_`.
        return wholeNumber(arena, neg, base, try withoutUnderscores(arena, body));
    }
    // At least its first group times 60 per further group.
    const first = try withoutUnderscores(arena, s[0..std.mem.findScalar(u8, s, ':').?]);
    const bits = @as(f64, @floatFromInt(first.len - 1)) * std.math.log2(10.0) +
        @as(f64, @floatFromInt(std.mem.count(u8, s, ":"))) * std.math.log2(60.0);
    if (bits > 1025) return infinity(neg);
    var n = try std.math.big.int.Managed.init(arena);
    var sixty = try std.math.big.int.Managed.initSet(arena, 60);
    var group = try std.math.big.int.Managed.init(arena);
    var groups = std.mem.splitScalar(u8, s, ':');
    while (groups.next()) |g| {
        try setDigits(&group, 10, try withoutUnderscores(arena, g));
        try n.mul(&n, &sixty);
        try n.add(&n, &group);
    }
    if (neg) n.negate();
    return bigValue(n);
}

/// The value of a 1.1 float spelling, or null when it names no number.
fn yaml11Float(arena: std.mem.Allocator, plain: []const u8) std.mem.Allocator.Error!?f64 {
    if (coreInfNan(plain)) |f| return f;
    const neg = plain.len > 0 and plain[0] == '-';
    const s = unsigned(plain);
    const v: f64 = if (std.mem.findScalar(u8, s, ':')) |_| blk: {
        const dot = std.mem.findScalar(u8, s, '.') orelse s.len;
        var total: f64 = 0;
        var groups = std.mem.splitScalar(u8, s[0..dot], ':');
        while (groups.next()) |g| {
            const part = std.fmt.parseFloat(f64, try withoutUnderscores(arena, g)) catch return null;
            total = total * 60 + part;
        }
        const frac = try withoutUnderscores(arena, s[dot..]);
        if (frac.len > 1) total += std.fmt.parseFloat(f64, try std.mem.concat(arena, u8, &.{ "0", frac })) catch return null;
        break :blk total;
    } else std.fmt.parseFloat(f64, try withoutUnderscores(arena, s)) catch return null;
    return if (neg) -v else v;
}

fn withoutUnderscores(arena: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]const u8 {
    if (std.mem.findScalar(u8, s, '_') == null) return s;
    return std.mem.replaceOwned(u8, arena, s, "_", "");
}

// JSON schema (the JSON data model, strict grammar)

fn resolveJson(arena: std.mem.Allocator, plain: []const u8) std.mem.Allocator.Error!Value {
    if (isWord(plain, "null")) return .null;
    if (isWord(plain, "true")) return .{ .bool = true };
    if (isWord(plain, "false")) return .{ .bool = false };
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

test "core gives a whole number beyond i128 as the float nearest it, in every base" {
    try expectResolve(.core, "0x" ++ &@as([33]u8, @splat('f')), .{ .float = 0x1p132 });
    try expectResolve(.core, "0o" ++ &@as([50]u8, @splat('7')), .{ .float = 0x1p150 });
    try expectResolve(.core, "-170141183460469231731687303715884105728", .{ .int = std.math.minInt(i128) });
    try expectResolve(.core, "170141183460469231731687303715884105728", .{ .float = 0x1p127 });
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

test "yaml11 resolves its wider booleans, integers in every base, floats and nulls" {
    try expectResolve(.yaml11, "y", .{ .bool = true });
    try expectResolve(.yaml11, "Yes", .{ .bool = true });
    try expectResolve(.yaml11, "ON", .{ .bool = true });
    try expectResolve(.yaml11, "n", .{ .bool = false });
    try expectResolve(.yaml11, "off", .{ .bool = false });
    try expectResolve(.yaml11, "~", .{ .null = {} });
    try expectResolve(.yaml11, "0b1_01", .{ .int = 5 });
    try expectResolve(.yaml11, "017", .{ .int = 15 });
    try expectResolve(.yaml11, "-0x_1F", .{ .int = -31 });
    try expectResolve(.yaml11, "1_000", .{ .int = 1000 });
    try expectResolve(.yaml11, "0", .{ .int = 0 });
    try expectResolve(.yaml11, "0_", .{ .int = 0 });
    try expectResolve(.yaml11, "-0b_", .{ .int = 0 });
    try expectResolve(.yaml11, "0x__", .{ .int = 0 });
    try expectResolve(.yaml11, "190:20:30", .{ .int = 685230 });
    try expectResolve(.yaml11, "-1:30", .{ .int = -90 });
    try expectResolve(.yaml11, "1_0.5", .{ .float = 10.5 });
    try expectResolve(.yaml11, "1.5e+3", .{ .float = 1500.0 });
    try expectResolve(.yaml11, "685.230_15e+03", .{ .float = 685230.15 });
    try expectResolve(.yaml11, "1.0_0", .{ .float = 1.0 });
    try expectResolve(.yaml11, "-170141183460469231731687303715884105728", .{ .int = std.math.minInt(i128) });
    try expectResolve(.yaml11, "-0x80000000000000000000000000000000", .{ .int = std.math.minInt(i128) });
    try expectResolve(.yaml11, "0" ++ &@as([50]u8, @splat('7')), .{ .float = 0x1p150 - 1 });
    try expectResolve(.yaml11, "0b" ++ &@as([130]u8, @splat('1')), .{ .float = 0x1p130 });
    try expectResolve(.yaml11, ".5", .{ .float = 0.5 });
    try expectResolve(.yaml11, "190:20:30.15", .{ .float = 685230.15 });
    try expectResolve(.yaml11, "-.Inf", .{ .float = -std.math.inf(f64) });
    try expectResolve(.yaml11, "99999999999999999999999999999999999999999999", .{ .float = 1e44 });
    try expectResolveString(.yaml11, "yES");
    try expectResolveString(.yaml11, "08");
    try expectResolveString(.yaml11, "1:60");
    try expectResolveString(.yaml11, "1e3"); // a 1.1 exponent takes a sign
    try expectResolveString(.yaml11, "1.2.3"); // a float spelling naming no number
    try expectResolveString(.yaml11, "2001-12-14"); // no timestamp in the data model
    try expectResolveString(.yaml11, "<<");
}

test "tagOf names the type each schema's grammar gives a plain scalar" {
    const cases = [_]struct { schema: Schema, plain: []const u8, tag: Tag }{
        .{ .schema = .failsafe, .plain = "true", .tag = .str },
        .{ .schema = .json, .plain = "01", .tag = .str },
        .{ .schema = .json, .plain = "-1.5e3", .tag = .float },
        .{ .schema = .core, .plain = "yes", .tag = .str },
        .{ .schema = .core, .plain = "1e3", .tag = .float },
        .{ .schema = .core, .plain = "0o17", .tag = .int },
        .{ .schema = .core, .plain = "99999999999999999999999999999999999999999999", .tag = .int },
        .{ .schema = .core, .plain = "<<", .tag = .str },
        .{ .schema = .yaml11, .plain = "685.230_15e+03", .tag = .float },
        .{ .schema = .yaml11, .plain = "y", .tag = .bool },
        .{ .schema = .yaml11, .plain = "0b101", .tag = .int },
        .{ .schema = .yaml11, .plain = "1:20", .tag = .int },
        .{ .schema = .yaml11, .plain = "1.2.3", .tag = .float },
        .{ .schema = .yaml11, .plain = "0.0.0.0", .tag = .float },
        .{ .schema = .yaml11, .plain = ".", .tag = .float },
        .{ .schema = .yaml11, .plain = "2001-12-14", .tag = .timestamp },
        .{ .schema = .yaml11, .plain = "2001-12-14t21:59:43.10-05:00", .tag = .timestamp },
        .{ .schema = .yaml11, .plain = "2001-12-14 21:59:43.10 -5", .tag = .timestamp },
        .{ .schema = .yaml11, .plain = "2001-12-14T21:59:43Z", .tag = .timestamp },
        .{ .schema = .yaml11, .plain = "2001-1-2", .tag = .str },
        .{ .schema = .yaml11, .plain = "2001-12-14 21:59", .tag = .str },
        .{ .schema = .yaml11, .plain = "<<", .tag = .merge },
        .{ .schema = .yaml11, .plain = "=", .tag = .value },
        .{ .schema = .yaml11, .plain = "en_US.UTF-8", .tag = .str },
        .{ .schema = .yaml11, .plain = "v1.2.3", .tag = .str },
        .{ .schema = .yaml11, .plain = "yesterday", .tag = .str },
    };
    for (cases) |c| {
        std.testing.expectEqual(c.tag, tagOf(c.schema, c.plain)) catch |e| {
            std.debug.print("{s} {s}\n", .{ @tagName(c.schema), c.plain });
            return e;
        };
    }
}

/// Whether `plain` is exactly `word`, compared inline: it runs for each
/// plain scalar resolved and each mapping key checked against a field
/// name or the merge key.
pub fn isWord(plain: []const u8, comptime word: []const u8) bool {
    if (plain.len != word.len) return false;
    inline for (word, 0..) |c, i| if (plain[i] != c) return false;
    return true;
}
