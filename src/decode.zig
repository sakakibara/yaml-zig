//! Typed decoding from `Value` into native Zig types.
//!
//! Maps a parsed YAML `Value` tree onto a target struct via comptime
//! reflection, the way `serde::Deserialize` does in Rust. Strings and slices
//! are zero-copy where possible; everything else lives in the caller's arena.
//!
//! ```zig
//! const Config = struct {
//!     title: []const u8,
//!     port: u16 = 8080,
//!     tags: []const []const u8,
//!     server: struct {
//!         host: []const u8,
//!         tls: bool = false,
//!     },
//! };
//!
//! const cfg = try yaml.parseInto(Config, arena, src, .{});
//! ```
//!
//! Field defaults satisfy missing-field cases. Optional fields (`?T`) become
//! `null` when absent or explicitly `null`. Unknown YAML keys are an error by
//! default; opt out with `ParseOptions{ .ignore_unknown_fields = true }`.
//!
//! YAML mappings are ordered `[]Entry` lists keyed by any `Value`, not a
//! string-keyed hashmap. Struct-field lookup linear-scans the entry list for
//! a string key equal to the wire name. A non-string map key never matches a
//! field, so a required field whose only candidate key is non-string is just
//! a missing field, and a non-string key is never reported as "unknown".

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing = std.testing;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Entry = value_mod.Entry;
const composer = @import("composer.zig");
const lev = @import("levenshtein.zig");

pub const DecodeError = error{
    TypeMismatch,
    MissingField,
    UnknownField,
    InvalidEnumValue,
    Overflow,
    OutOfMemory,
};

/// Decode diagnostics have no source location (the value tree carries none),
/// so every entry gets a zero span and the dotted path is folded into the
/// message text instead.
const no_span: value_mod.Span = .{ .start = 0, .end = 0 };

fn appendDiag(list: *std.ArrayList(composer.Diagnostic), arena: Allocator, path: *const PathBuilder, msg: []const u8, suggestion: ?[]const u8) Allocator.Error!void {
    const full = if (path.slice().len > 0)
        try std.fmt.allocPrint(arena, "{s} (at {s})", .{ msg, path.slice() })
    else
        msg;
    try list.append(arena, .{ .message = full, .span = no_span, .suggestion = suggestion });
}

const PathBuilder = struct {
    buf: std.ArrayList(u8),

    pub fn pushSegment(self: *PathBuilder, arena: Allocator, segment: []const u8) Allocator.Error!usize {
        const prev = self.buf.items.len;
        if (prev > 0) try self.buf.append(arena, '.');
        try self.buf.appendSlice(arena, segment);
        return prev;
    }

    pub fn pushIndex(self: *PathBuilder, arena: Allocator, idx: usize) Allocator.Error!usize {
        const prev = self.buf.items.len;
        var tmp: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "[{d}]", .{idx}) catch unreachable;
        try self.buf.appendSlice(arena, s);
        return prev;
    }

    pub fn restore(self: *PathBuilder, prev_len: usize) void {
        self.buf.shrinkRetainingCapacity(prev_len);
    }

    pub fn slice(self: *const PathBuilder) []const u8 {
        return self.buf.items;
    }
};

/// String-key lookup over a mapping's entries: last entry wins on duplicate
/// keys, non-string keys never match. Shared with `Value.get`'s traversal.
const mapGet = Value.mapGet;

/// Comptime check that every annotation entry on `T` names a real field
/// (struct) or variant (union): `yaml_rename` keys, `yaml_skip` entries,
/// and `yaml_flatten` entries. A typo'd annotation fails the build with
/// `@compileError` instead of silently never applying. Runs at the top of
/// struct and tagged-union decoding (and typed encoding). Compile errors
/// cannot be asserted from the test suite.
pub fn validateAnnotations(comptime T: type) void {
    comptime {
        const kind = if (@typeInfo(T) == .@"union") "variant" else "field";
        if (@hasDecl(T, "yaml_rename")) {
            for (@typeInfo(@TypeOf(T.yaml_rename)).@"struct".fields) |rf| {
                if (!@hasField(T, rf.name)) {
                    @compileError("yaml_rename entry `" ++ rf.name ++ "` does not match any " ++ kind ++ " of " ++ @typeName(T));
                }
            }
        }
        if (@hasDecl(T, "yaml_skip")) {
            for (T.yaml_skip) |name| {
                if (!@hasField(T, name)) {
                    @compileError("yaml_skip entry `" ++ name ++ "` does not match any " ++ kind ++ " of " ++ @typeName(T));
                }
            }
        }
        if (@hasDecl(T, "yaml_flatten")) {
            for (T.yaml_flatten) |name| {
                if (!@hasField(T, name)) {
                    @compileError("yaml_flatten entry `" ++ name ++ "` does not match any " ++ kind ++ " of " ++ @typeName(T));
                }
            }
        }
    }
}

/// Returns the effective YAML key for `field_name` on type `T`,
/// consulting `T.yaml_rename` if present.
pub fn renamedKey(comptime T: type, comptime field_name: []const u8) []const u8 {
    if (!@hasDecl(T, "yaml_rename")) return field_name;
    const renames = T.yaml_rename;
    if (@hasField(@TypeOf(renames), field_name)) {
        return @field(renames, field_name);
    }
    return field_name;
}

/// Returns true if `field_name` on type `T` is listed in `T.yaml_skip`.
pub fn isSkipped(comptime T: type, comptime field_name: []const u8) bool {
    if (!@hasDecl(T, "yaml_skip")) return false;
    const skip = T.yaml_skip;
    inline for (skip) |name| {
        if (comptime std.mem.eql(u8, name, field_name)) return true;
    }
    return false;
}

/// Returns true if `field_name` on type `T` is listed in `T.yaml_flatten`.
pub fn isFlattened(comptime T: type, comptime field_name: []const u8) bool {
    if (!@hasDecl(T, "yaml_flatten")) return false;
    const flat = T.yaml_flatten;
    inline for (flat) |name| {
        if (comptime std.mem.eql(u8, name, field_name)) return true;
    }
    return false;
}

/// Returns the full set of YAML keys that decoding `T` expects to see
/// at the mapping's level -- i.e., renamed names for non-flattened fields,
/// plus the expectedKeys of each flattened field's type (recursive).
fn expectedKeys(comptime T: type) []const []const u8 {
    comptime {
        const s = @typeInfo(T).@"struct";
        var keys: []const []const u8 = &.{};
        for (s.fields) |field| {
            if (isSkipped(T, field.name)) continue;
            if (isFlattened(T, field.name)) {
                const inner = expectedKeys(field.type);
                keys = keys ++ inner;
            } else {
                keys = keys ++ &[_][]const u8{renamedKey(T, field.name)};
            }
        }
        return keys;
    }
}

/// Decode a `Value` into an instance of `T`.
///
/// Number policy: float targets accept `.int` values (converted via
/// `@floatFromInt`), but integer targets do NOT accept `.float` values --
/// `1e2` resolves as `.float` and stays one, so it never decodes into an
/// integer field. Integer scalars in the range [-2^127, 2^127-1] parse as
/// `.int`; values outside that range resolve as `.float` and cannot decode
/// into an integer field. YAML `null` decodes only into optional targets;
/// for any other target it errors like an absent field
/// (`error.MissingField`).
pub fn decode(comptime T: type, arena: Allocator, value: Value, options: composer.ParseOptions) DecodeError!T {
    var path: PathBuilder = .{ .buf = .empty };
    return decodeInner(T, arena, value, options, &path);
}

/// Parse + decode in one call. See `decode` for the decoding rules.
///
/// Fast path: types without `Value` fields, `fromYaml` hooks, or tagged
/// unions decode in a single streaming pass over parser events with no
/// intermediate `Value` tree, provided the document uses no anchors,
/// aliases, or merge keys (those need retained node values and fall back
/// to the tree). On any error the input is re-decoded through the tree
/// path, so diagnostics and error selection are always the canonical
/// ones. Callers requesting `options.spans` use the tree path.
pub fn parseInto(comptime T: type, arena: Allocator, src: []const u8, options: composer.ParseOptions) (composer.Error || DecodeError)!T {
    if (comptime needsTree(T)) return parseIntoTree(T, arena, src, options);
    if (options.spans != null) return parseIntoTree(T, arena, src, options);
    return streamParseInto(T, arena, src, options) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => parseIntoTree(T, arena, src, options),
    };
}

fn parseIntoTree(comptime T: type, arena: Allocator, src: []const u8, options: composer.ParseOptions) (composer.Error || DecodeError)!T {
    const value = try composer.parse(arena, src, options);
    return decode(T, arena, value, options);
}

/// Reader-input variant of `parseInto`: drains the reader into arena
/// memory, then decodes the slice (streaming when the type allows).
pub fn parseIntoReader(comptime T: type, arena: Allocator, reader: *std.Io.Reader, options: composer.ParseOptions) (composer.ReaderError || DecodeError)!T {
    const input = try reader.allocRemaining(arena, .unlimited);
    return parseInto(T, arena, input, options);
}

fn decodeInner(comptime T: type, arena: Allocator, value: Value, options: composer.ParseOptions, path: *PathBuilder) DecodeError!T {
    if (T == Value) return value;

    // Custom fromYaml hook short-circuit.
    if (comptime (@typeInfo(T) == .@"struct" and @hasDecl(T, "fromYaml"))) {
        comptime {
            const fn_info = @typeInfo(@TypeOf(T.fromYaml)).@"fn";
            if (fn_info.params.len != 3) {
                @compileError(@typeName(T) ++ ".fromYaml must take exactly 3 params: (Allocator, Value, ParseOptions)");
            }
        }
        return T.fromYaml(arena, value, options);
    }

    // YAML `null` satisfies optionals only (handled in decodeOptional). For
    // any other target the field is effectively absent, so the error matches
    // the missing-field case.
    if (comptime @typeInfo(T) != .optional) {
        if (value == .null) {
            if (options.errors) |list| {
                const msg = try std.fmt.allocPrint(arena, "expected {s}, got null", .{@typeName(T)});
                try appendDiag(list, arena, path, msg, null);
            }
            return error.MissingField;
        }
    }

    // Tagged-union dispatch.
    if (comptime (@typeInfo(T) == .@"union" and @hasDecl(T, "yaml_tag"))) {
        return decodeTaggedUnion(T, arena, value, options, path);
    }

    return switch (@typeInfo(T)) {
        .bool => decodeBool(value, arena, options, path),
        .int => decodeInt(T, value, arena, options, path),
        .float => decodeFloat(T, value, arena, options, path),
        .pointer => |p| decodePointer(T, p, arena, value, options, path),
        .array => |a| decodeArray(T, a, arena, value, options, path),
        .optional => |o| decodeOptional(o.child, arena, value, options, path),
        .@"struct" => |s| decodeStruct(T, s, arena, value, options, path),
        .@"enum" => decodeEnum(T, value, arena, options, path),
        else => @compileError("yaml decode: unsupported type " ++ @typeName(T)),
    };
}

fn decodeBool(value: Value, arena: Allocator, options: composer.ParseOptions, path: *PathBuilder) DecodeError!bool {
    if (value != .bool) {
        if (options.errors) |list| {
            const msg = try std.fmt.allocPrint(arena, "expected boolean, got {s}", .{@tagName(value)});
            try appendDiag(list, arena, path, msg, null);
        }
        return error.TypeMismatch;
    }
    return value.bool;
}

fn decodeInt(comptime T: type, value: Value, arena: Allocator, options: composer.ParseOptions, path: *PathBuilder) DecodeError!T {
    if (value != .int) {
        if (options.errors) |list| {
            const msg = try std.fmt.allocPrint(arena, "expected integer, got {s}", .{@tagName(value)});
            try appendDiag(list, arena, path, msg, null);
        }
        return error.TypeMismatch;
    }
    if (std.math.cast(T, value.int)) |v| return v;
    if (options.errors) |list| {
        const msg = try std.fmt.allocPrint(arena, "integer {d} out of range for {s}", .{ value.int, @typeName(T) });
        try appendDiag(list, arena, path, msg, null);
    }
    return error.Overflow;
}

fn decodeFloat(comptime T: type, value: Value, arena: Allocator, options: composer.ParseOptions, path: *PathBuilder) DecodeError!T {
    return switch (value) {
        .float => |f| blk: {
            const r: T = @floatCast(f);
            // Finite source narrowing to inf means the f64 value exceeds floatMax(T).
            if (!std.math.isInf(f) and std.math.isInf(r)) return error.Overflow;
            break :blk r;
        },
        .int => |n| blk: {
            const r: T = @floatFromInt(n);
            if (std.math.isInf(r)) return error.Overflow;
            break :blk r;
        },
        else => {
            if (options.errors) |list| {
                const msg = try std.fmt.allocPrint(arena, "expected float, got {s}", .{@tagName(value)});
                try appendDiag(list, arena, path, msg, null);
            }
            return error.TypeMismatch;
        },
    };
}

fn decodePointer(comptime T: type, comptime p: std.builtin.Type.Pointer, arena: Allocator, value: Value, options: composer.ParseOptions, path: *PathBuilder) DecodeError!T {
    if (p.size != .slice) @compileError("yaml decode: only slice pointers supported, got " ++ @typeName(T));
    if (p.child == u8 and p.is_const) {
        if (value != .string) {
            if (options.errors) |list| {
                const msg = try std.fmt.allocPrint(arena, "expected string, got {s}", .{@tagName(value)});
                try appendDiag(list, arena, path, msg, null);
            }
            return error.TypeMismatch;
        }
        return value.string;
    }
    if (value != .seq) {
        if (options.errors) |list| {
            const msg = try std.fmt.allocPrint(arena, "expected sequence, got {s}", .{@tagName(value)});
            try appendDiag(list, arena, path, msg, null);
        }
        return error.TypeMismatch;
    }
    const items = value.seq;
    const out = try arena.alloc(p.child, items.len);
    for (items, 0..) |item, i| {
        const prev = try path.pushIndex(arena, i);
        defer path.restore(prev);
        out[i] = try decodeInner(p.child, arena, item, options, path);
    }
    return out;
}

fn decodeArray(comptime T: type, comptime a: std.builtin.Type.Array, arena: Allocator, value: Value, options: composer.ParseOptions, path: *PathBuilder) DecodeError!T {
    if (value != .seq) {
        if (options.errors) |list| {
            const msg = try std.fmt.allocPrint(arena, "expected sequence, got {s}", .{@tagName(value)});
            try appendDiag(list, arena, path, msg, null);
        }
        return error.TypeMismatch;
    }
    if (value.seq.len != a.len) {
        if (options.errors) |list| {
            const msg = try std.fmt.allocPrint(arena, "sequence length mismatch: expected {d}, got {d}", .{ a.len, value.seq.len });
            try appendDiag(list, arena, path, msg, null);
        }
        return error.TypeMismatch;
    }
    var out: T = undefined;
    // Zero-length array: no elements to fill; indexing would be a compile error.
    if (comptime a.len == 0) return out;
    for (value.seq, 0..) |item, i| {
        const prev = try path.pushIndex(arena, i);
        defer path.restore(prev);
        out[i] = try decodeInner(a.child, arena, item, options, path);
    }
    return out;
}

fn decodeOptional(comptime Child: type, arena: Allocator, value: Value, options: composer.ParseOptions, path: *PathBuilder) DecodeError!?Child {
    if (value == .null) return null;
    return try decodeInner(Child, arena, value, options, path);
}

fn decodeStruct(comptime T: type, comptime s: std.builtin.Type.Struct, arena: Allocator, value: Value, options: composer.ParseOptions, path: *PathBuilder) DecodeError!T {
    comptime validateAnnotations(T);
    if (value != .map) {
        if (options.errors) |list| {
            const msg = try std.fmt.allocPrint(arena, "expected mapping, got {s}", .{@tagName(value)});
            try appendDiag(list, arena, path, msg, null);
        }
        return error.TypeMismatch;
    }
    const entries = value.map;

    // Unknown-field check runs before field assignment so that an
    // unrecognized key is reported as UnknownField rather than being
    // shadowed by a subsequent MissingField on a required field. Only
    // string-keyed entries are addressable as fields; a non-string key is
    // never an "unknown field" (it simply cannot name one).
    if (!options.ignore_unknown_fields) {
        outer: for (entries) |entry| {
            if (entry.key != .string) continue;
            const key = entry.key.string;
            inline for (comptime expectedKeys(T)) |expected| {
                if (std.mem.eql(u8, key, expected)) continue :outer;
            }
            // Unknown key. Try a suggestion.
            const suggestion = lev.closestMatch(key, comptime expectedKeys(T), lev.suggestionThreshold(key.len));

            if (options.errors) |list| {
                const msg = try std.fmt.allocPrint(arena, "unknown field `{s}`", .{key});
                const suggestion_owned: ?[]const u8 = if (suggestion) |s_str| try arena.dupe(u8, s_str) else null;
                try appendDiag(list, arena, path, msg, suggestion_owned);
            }
            return error.UnknownField;
        }
    }

    var out: T = undefined;

    inline for (s.fields) |field| {
        if (comptime isSkipped(T, field.name)) {
            const dv = comptime field.defaultValue() orelse
                @compileError("yaml_skip field `" ++ field.name ++ "` on " ++ @typeName(T) ++ " has no default value");
            @field(out, field.name) = dv;
        } else if (comptime isFlattened(T, field.name)) {
            // Decode the inner struct from the SAME parent value (no key lookup).
            // The parent's expectedKeys already validated all keys, so suppress
            // unknown-field errors in the inner struct to avoid false positives
            // on sibling fields the inner type doesn't know about.
            const prev = try path.pushSegment(arena, field.name);
            defer path.restore(prev);
            var flat_opts = options;
            flat_opts.ignore_unknown_fields = true;
            @field(out, field.name) = try decodeInner(field.type, arena, value, flat_opts, path);
        } else {
            const eff_key = comptime renamedKey(T, field.name);
            if (mapGet(entries, eff_key)) |fv| {
                const prev = try path.pushSegment(arena, eff_key);
                defer path.restore(prev);
                @field(out, field.name) = try decodeInner(field.type, arena, fv, options, path);
            } else if (field.defaultValue()) |dv| {
                @field(out, field.name) = dv;
            } else if (@typeInfo(field.type) == .optional) {
                @field(out, field.name) = null;
            } else {
                if (options.errors) |list| {
                    const msg = try std.fmt.allocPrint(arena, "missing required field `{s}`", .{eff_key});
                    try appendDiag(list, arena, path, msg, null);
                }
                return error.MissingField;
            }
        }
    }

    return out;
}

/// Effective (renamed) wire names of every variant of union `T`.
fn variantNames(comptime T: type) []const []const u8 {
    comptime {
        var names: []const []const u8 = &.{};
        for (@typeInfo(T).@"union".fields) |field| {
            names = names ++ &[_][]const u8{renamedKey(T, field.name)};
        }
        return names;
    }
}

fn decodeTaggedUnion(comptime T: type, arena: Allocator, value: Value, options: composer.ParseOptions, path: *PathBuilder) DecodeError!T {
    comptime validateAnnotations(T);
    if (value != .map) {
        if (options.errors) |list| {
            const msg = try std.fmt.allocPrint(arena, "expected mapping for {s}, got {s}", .{ @typeName(T), @tagName(value) });
            try appendDiag(list, arena, path, msg, null);
        }
        return error.TypeMismatch;
    }
    const entries = value.map;
    const tag_field = T.yaml_tag;
    const tag_value = mapGet(entries, tag_field) orelse {
        if (options.errors) |list| {
            const msg = try std.fmt.allocPrint(arena, "missing discriminator field `{s}` for {s}", .{ tag_field, @typeName(T) });
            try appendDiag(list, arena, path, msg, null);
        }
        return error.MissingField;
    };
    if (tag_value != .string) {
        if (options.errors) |list| {
            const msg = try std.fmt.allocPrint(arena, "expected string for discriminator `{s}`, got {s}", .{ tag_field, @tagName(tag_value) });
            try appendDiag(list, arena, path, msg, null);
        }
        return error.TypeMismatch;
    }

    inline for (@typeInfo(T).@"union".fields) |union_field| {
        const variant_name = union_field.name;
        const effective_name = comptime renamedKey(T, variant_name);
        if (std.mem.eql(u8, tag_value.string, effective_name)) {
            const PayloadType = union_field.type;

            if (PayloadType == void) {
                return @unionInit(T, variant_name, {});
            }

            // Build a filtered mapping view that drops the discriminator entry.
            var filtered: std.ArrayList(Entry) = .empty;
            for (entries) |entry| {
                if (entry.key == .string and std.mem.eql(u8, entry.key.string, tag_field)) continue;
                try filtered.append(arena, entry);
            }
            const filtered_value = Value{ .map = filtered.items };
            const payload = try decodeInner(PayloadType, arena, filtered_value, options, path);
            return @unionInit(T, variant_name, payload);
        }
    }
    if (options.errors) |list| {
        const tag = tag_value.string;
        const suggestion = lev.closestMatch(tag, comptime variantNames(T), lev.suggestionThreshold(tag.len));
        const msg = try std.fmt.allocPrint(arena, "unknown variant `{s}` for {s}", .{ tag, @typeName(T) });
        const suggestion_owned: ?[]const u8 = if (suggestion) |s_str| try arena.dupe(u8, s_str) else null;
        try appendDiag(list, arena, path, msg, suggestion_owned);
    }
    return error.InvalidEnumValue;
}

fn decodeEnum(comptime T: type, value: Value, arena: Allocator, options: composer.ParseOptions, path: *PathBuilder) DecodeError!T {
    switch (value) {
        .string => |s| {
            if (std.meta.stringToEnum(T, s)) |v| return v;
            if (options.errors) |list| {
                const msg = try std.fmt.allocPrint(arena, "invalid enum value `{s}` for {s}", .{ s, @typeName(T) });
                try appendDiag(list, arena, path, msg, null);
            }
            return error.InvalidEnumValue;
        },
        .int => |n| {
            if (std.enums.fromInt(T, n)) |v| return v;
            if (options.errors) |list| {
                const msg = try std.fmt.allocPrint(arena, "integer {d} is not a valid value of {s}", .{ n, @typeName(T) });
                try appendDiag(list, arena, path, msg, null);
            }
            return error.InvalidEnumValue;
        },
        else => {
            if (options.errors) |list| {
                const msg = try std.fmt.allocPrint(arena, "expected string or integer for enum {s}, got {s}", .{ @typeName(T), @tagName(value) });
                try appendDiag(list, arena, path, msg, null);
            }
            return error.TypeMismatch;
        },
    }
}

// --- Tests ----------------------------------------------------------------

const parse = composer.parse;

test "decode struct with defaults optionals seqs enums nested" {
    const Config = struct {
        title: []const u8,
        port: u16 = 8080,
        nick: ?[]const u8,
        ratio: f64,
        tags: []const []const u8,
        mode: enum { fast, slow },
        server: struct { host: []const u8, tls: bool = false },
    };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const cfg = try parseInto(Config, ar.allocator(),
        \\title: t
        \\nick: ~
        \\ratio: 1.5
        \\tags: [a]
        \\mode: fast
        \\server:
        \\  host: h
    , .{});
    try std.testing.expectEqual(@as(u16, 8080), cfg.port);
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.nick);
    try std.testing.expectEqual(false, cfg.server.tls);
    try std.testing.expectEqualStrings("t", cfg.title);
    try std.testing.expectEqual(@as(f64, 1.5), cfg.ratio);
    try std.testing.expectEqualStrings("a", cfg.tags[0]);
}

test "unknown field errors with did-you-mean; opt-out flag" {
    const C = struct { port: u16 = 1 };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try std.testing.expectError(error.UnknownField, parseInto(C, a, "prot: 2\n", .{}));
    const c = try parseInto(C, a, "prot: 2\n", .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(u16, 1), c.port);
}

test "int overflow checked" {
    const C = struct { n: u8 };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    try std.testing.expectError(error.Overflow, parseInto(C, ar.allocator(), "n: 256\n", .{}));
}

test "yaml_rename yaml_skip yaml_flatten" {
    const C = struct {
        pub const yaml_rename = .{ .listen_addr = "listen-addr" };
        pub const yaml_skip = .{"runtime"};
        pub const yaml_flatten = .{"common"};
        listen_addr: []const u8,
        runtime: u32 = 7,
        common: struct { verbose: bool = false },
    };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const c = try parseInto(C, ar.allocator(), "listen-addr: x\nverbose: true\n", .{});
    try std.testing.expectEqualStrings("x", c.listen_addr);
    try std.testing.expectEqual(@as(u32, 7), c.runtime);
    try std.testing.expectEqual(true, c.common.verbose);
}

test "yaml_tag tagged union" {
    const Plugin = union(enum) {
        pub const yaml_tag = "kind";
        http: struct { port: u16 },
        exec: struct { cmd: []const u8 },
    };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const v = try parseInto(Plugin, ar.allocator(), "kind: http\nport: 80\n", .{});
    try std.testing.expectEqual(@as(u16, 80), v.http.port);
}

test "fromYaml hook and embedded Value" {
    const Wrapped = struct {
        n: i64,
        pub fn fromYaml(arena_: std.mem.Allocator, val: Value, options: composer.ParseOptions) DecodeError!@This() {
            _ = arena_;
            _ = options;
            return .{ .n = @intCast(val.int * 2) };
        }
    };
    const C = struct { w: Wrapped, raw: Value };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const c = try parseInto(C, ar.allocator(), "w: 21\nraw: {any: 1}\n", .{});
    try std.testing.expectEqual(@as(i64, 42), c.w.n);
    try std.testing.expectEqual(@as(i64, 1), c.raw.getT(i64, "any").?);
}

test "non-scalar map key into a struct target is just a missing field" {
    const C = struct { a: i64 = 99 };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    // a mapping whose only key is a sequence; struct field `a` is absent -> default used
    const c = try parseInto(C, ar.allocator(), "{[1, 2]: 3}\n", .{});
    try std.testing.expectEqual(@as(i64, 99), c.a);
}

test "decoding a non-map into a struct errors" {
    const C = struct { a: i64 };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    try std.testing.expectError(error.TypeMismatch, parseInto(C, ar.allocator(), "[1, 2, 3]\n", .{}));
}

test "parseIntoReader decodes from a reader" {
    const C = struct { port: u16 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var r: std.Io.Reader = .fixed("port: 8080\n");
    const c = try parseIntoReader(C, ar.allocator(), &r, .{});
    try testing.expectEqual(@as(u16, 8080), c.port);
}

test "decode null into non-optional field is MissingField" {
    const C = struct { n: u32 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectError(error.MissingField, parseInto(C, ar.allocator(), "n: ~\n", .{}));
}

test "decode null/optional matrix" {
    const C = struct {
        a: ?u32, // present as null
        b: ?u32, // absent
        c: ?u32, // present with value
        d: u32 = 5, // absent, has default
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const c = try parseInto(C, ar.allocator(), "a: ~\nc: 3\n", .{});
    try testing.expectEqual(@as(?u32, null), c.a);
    try testing.expectEqual(@as(?u32, null), c.b);
    try testing.expectEqual(@as(?u32, 3), c.c);
    try testing.expectEqual(@as(u32, 5), c.d);
}

test "decode float field accepts integer value" {
    const C = struct { x: f32, y: f64 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const c = try parseInto(C, ar.allocator(), "x: 3\ny: -7\n", .{});
    try testing.expectEqual(@as(f32, 3.0), c.x);
    try testing.expectEqual(@as(f64, -7.0), c.y);
}

test "decode int field rejects float value" {
    const C = struct { n: u32 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expectError(error.TypeMismatch, parseInto(C, a, "n: 1.5\n", .{}));
    // 1e2 resolves as .float and stays one; it never decodes into an int.
    try testing.expectError(error.TypeMismatch, parseInto(C, a, "n: 1e2\n", .{}));
}

test "decode enum from integer tag" {
    const Level = enum(u8) { debug = 0, info = 1, warn = 2, err = 3 };
    const C = struct { level: Level };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const c = try parseInto(C, ar.allocator(), "level: 2\n", .{});
    try testing.expectEqual(Level.warn, c.level);
}

test "decode enum from out-of-range integer is error" {
    const Level = enum(u8) { debug = 0, info = 1 };
    const C = struct { level: Level };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectError(error.InvalidEnumValue, parseInto(C, ar.allocator(), "level: 99\n", .{}));
}

test "decode enum from invalid string is error" {
    const C = struct { mode: enum { fast, slow } };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectError(error.InvalidEnumValue, parseInto(C, ar.allocator(), "mode: warp\n", .{}));
}

test "decode missing required field is error" {
    const C = struct { required: []const u8 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectError(error.MissingField, parseInto(C, ar.allocator(), "{}\n", .{}));
}

test "decode fixed-size array and length mismatch" {
    const C = struct { rgb: [3]u8 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const c = try parseInto(C, a, "rgb: [1, 2, 3]\n", .{});
    try testing.expectEqual(@as(u8, 1), c.rgb[0]);
    try testing.expectEqual(@as(u8, 3), c.rgb[2]);
    try testing.expectError(error.TypeMismatch, parseInto(C, a, "rgb: [1, 2]\n", .{}));
}

test "decode nested struct three levels deep" {
    const C = struct {
        a: struct {
            b: struct {
                c: struct { n: u32 },
            },
        },
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const c = try parseInto(C, ar.allocator(), "a:\n  b:\n    c:\n      n: 42\n", .{});
    try testing.expectEqual(@as(u32, 42), c.a.b.c.n);
}

test "decode slice of structs" {
    const User = struct { name: []const u8, age: u32 };
    const C = struct { users: []const User };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const c = try parseInto(C, ar.allocator(),
        \\users:
        \\  - name: alice
        \\    age: 30
        \\  - name: bob
        \\    age: 25
    , .{});
    try testing.expectEqual(@as(usize, 2), c.users.len);
    try testing.expectEqualStrings("alice", c.users[0].name);
    try testing.expectEqual(@as(u32, 25), c.users[1].age);
}

test "decode embedded Value field keeps dynamic subtree" {
    const C = struct { meta: Value, n: u32 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const c = try parseInto(C, ar.allocator(), "meta:\n  a: [1, 2]\nn: 5\n", .{});
    try testing.expectEqual(@as(u32, 5), c.n);
    try testing.expect(c.meta == .map);
    try testing.expectEqual(@as(i64, 2), c.meta.getT(i64, "a[1]").?);
}

test "decode raw Value passthrough at any variant" {
    const C = struct { anything: Value };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const c = try parseInto(C, a, "anything: goes\n", .{});
    try testing.expectEqualStrings("goes", c.anything.string);
    // `null` is a Value variant, so it passes through rather than erroring.
    const c2 = try parseInto(C, a, "anything: ~\n", .{});
    try testing.expect(c2.anything == .null);
}

test "decode: fromYaml hook short-circuits built-in dispatch" {
    const SemVer = struct {
        major: u32,
        minor: u32,
        patch: u32,

        pub fn fromYaml(arena: std.mem.Allocator, value: Value, _: composer.ParseOptions) DecodeError!@This() {
            _ = arena;
            if (value != .string) return error.TypeMismatch;
            var it = std.mem.tokenizeAny(u8, value.string, ".");
            const maj_s = it.next() orelse return error.TypeMismatch;
            const min_s = it.next() orelse return error.TypeMismatch;
            const pat_s = it.next() orelse return error.TypeMismatch;
            const maj = std.fmt.parseInt(u32, maj_s, 10) catch return error.TypeMismatch;
            const min = std.fmt.parseInt(u32, min_s, 10) catch return error.TypeMismatch;
            const pat = std.fmt.parseInt(u32, pat_s, 10) catch return error.TypeMismatch;
            return .{ .major = maj, .minor = min, .patch = pat };
        }
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const C = struct { v: SemVer };
    const c = try parseInto(C, ar.allocator(), "v: \"1.2.3\"\n", .{});
    try testing.expectEqual(@as(u32, 1), c.v.major);
    try testing.expectEqual(@as(u32, 2), c.v.minor);
    try testing.expectEqual(@as(u32, 3), c.v.patch);
}

test "decode: yaml_rename unknown-field check uses renamed name" {
    const C = struct {
        pub const yaml_rename = .{ .listen_addr = "listen-addr" };
        listen_addr: []const u8,
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    // Original snake_case key -- should error since renamed key is expected.
    try testing.expectError(error.UnknownField, parseInto(C, ar.allocator(), "listen_addr: 0.0.0.0\n", .{}));
}

test "decode: yaml_skip rejects skipped key in strict mode" {
    const C = struct {
        pub const yaml_skip = .{"internal"};
        name: []const u8,
        internal: u32 = 7,
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    // Skipped fields are excluded from the expected-keys set,
    // so a YAML key matching a skipped field is "unknown".
    try testing.expectError(error.UnknownField, parseInto(C, ar.allocator(), "name: foo\ninternal: 99\n", .{}));
}

test "decode: yaml_flatten inner yaml_rename expands into expected keys" {
    const Inner = struct {
        pub const yaml_rename = .{ .log_level = "log-level" };
        log_level: []const u8 = "info",
    };
    const Outer = struct {
        pub const yaml_rename = .{ .listen_addr = "listen-addr" };
        pub const yaml_flatten = .{"inner"};
        listen_addr: []const u8,
        inner: Inner,
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const c = try parseInto(Outer, ar.allocator(), "listen-addr: x\nlog-level: debug\n", .{});
    try testing.expectEqualStrings("x", c.listen_addr);
    try testing.expectEqualStrings("debug", c.inner.log_level);
}

test "decode: yaml_flatten unknown-field check expands flattened keys" {
    const Inner = struct { x: u32 };
    const Outer = struct {
        pub const yaml_flatten = .{"inner"};
        name: []const u8,
        inner: Inner,
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectError(error.UnknownField, parseInto(Outer, ar.allocator(),
        "name: foo\nx: 42\nunexpected: true\n", .{}));
}

test "decode: tagged union missing discriminator -> MissingField" {
    const Plugin = union(enum) {
        pub const yaml_tag = "kind";
        http: struct { host: []const u8 },
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectError(error.MissingField, parseInto(Plugin, ar.allocator(), "host: localhost\n", .{}));
}

test "decode: tagged union unknown discriminator -> InvalidEnumValue" {
    const Plugin = union(enum) {
        pub const yaml_tag = "kind";
        http: struct { host: []const u8 },
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectError(error.InvalidEnumValue, parseInto(Plugin, ar.allocator(),
        "kind: xyz\nhost: localhost\n", .{}));
}

test "decode: tagged union unknown variant diagnostic suggests closest match" {
    const Plugin = union(enum) {
        pub const yaml_tag = "kind";
        http: struct { port: u16 = 0 },
        exec: struct { cmd: []const u8 = "" },
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(composer.Diagnostic) = .empty;
    defer errs.deinit(a);

    _ = parseInto(Plugin, a, "kind: htpp\n", .{ .errors = &errs }) catch {};
    try testing.expect(errs.items.len == 1);
    try testing.expect(std.mem.indexOf(u8, errs.items[0].message, "unknown variant `htpp`") != null);
    try testing.expectEqualStrings("http", errs.items[0].suggestion.?);
}

test "decode: tagged union missing discriminator diagnostic names tag field" {
    const Plugin = union(enum) {
        pub const yaml_tag = "kind";
        http: struct { port: u16 = 0 },
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(composer.Diagnostic) = .empty;
    defer errs.deinit(a);

    _ = parseInto(Plugin, a, "port: 80\n", .{ .errors = &errs }) catch {};
    try testing.expect(errs.items.len == 1);
    try testing.expect(std.mem.indexOf(u8, errs.items[0].message, "missing discriminator field `kind`") != null);
}

test "decode: missing-field diagnostic reports the YAML wire key" {
    const C = struct {
        pub const yaml_rename = .{ .listen_addr = "listen-addr" };
        listen_addr: []const u8,
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(composer.Diagnostic) = .empty;
    defer errs.deinit(a);

    _ = parseInto(C, a, "{}\n", .{ .errors = &errs }) catch {};
    try testing.expect(errs.items.len == 1);
    try testing.expect(std.mem.indexOf(u8, errs.items[0].message, "`listen-addr`") != null);
    try testing.expect(std.mem.indexOf(u8, errs.items[0].message, "listen_addr") == null);
}

test "decode: tagged union void variant" {
    const Plugin = union(enum) {
        pub const yaml_tag = "kind";
        none,
        http: struct { port: u16 },
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const p_ = try parseInto(Plugin, ar.allocator(), "kind: none\n", .{});
    try testing.expect(p_ == .none);
}

test "decode: unknown field suggests closest match" {
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(composer.Diagnostic) = .empty;
    defer errs.deinit(a);

    // `prt` is a typo for `port`; `port` is also present so the required
    // field is satisfied and the unknown-field check runs.
    const C = struct { port: u16 };
    _ = parseInto(C, a, "port: 8080\nprt: 9090\n", .{ .errors = &errs }) catch {};

    try testing.expect(errs.items.len == 1);
    try testing.expect(errs.items[0].suggestion != null);
    try testing.expectEqualStrings("port", errs.items[0].suggestion.?);
}

test "decode: nested type mismatch reports dotted path in message" {
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var errs: std.ArrayList(composer.Diagnostic) = .empty;
    defer errs.deinit(a);

    const C = struct {
        server: struct { port: u16 },
    };
    _ = parseInto(C, a, "server:\n  port: \"8080\"\n", .{ .errors = &errs }) catch {};

    try testing.expect(errs.items.len == 1);
    try testing.expect(std.mem.indexOf(u8, errs.items[0].message, "server.port") != null);
}

test "PathBuilder: push/restore symmetry" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var path: PathBuilder = .{ .buf = .empty };

    const p1 = try path.pushSegment(arena.allocator(), "server");
    try testing.expectEqualStrings("server", path.slice());

    const p2 = try path.pushSegment(arena.allocator(), "port");
    try testing.expectEqualStrings("server.port", path.slice());

    path.restore(p2);
    try testing.expectEqualStrings("server", path.slice());

    const p3 = try path.pushIndex(arena.allocator(), 7);
    try testing.expectEqualStrings("server[7]", path.slice());

    path.restore(p3);
    path.restore(p1);
    try testing.expectEqualStrings("", path.slice());
}

test "decode: duplicate-key mapping into struct is last-wins" {
    // `a: 1\na: 2\n` decoded into a struct must yield a==2 (last-wins),
    // consistent with getT("a")==2 from value.zig.
    const C = struct { a: i64 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const c = try parseInto(C, ar.allocator(), "a: 1\na: 2\n", .{});
    try testing.expectEqual(@as(i64, 2), c.a);
}

test "decode operates on an already-parsed Value" {
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "title: yaml\nport: 8080\nenabled: true\n", .{});
    const Config = struct {
        title: []const u8,
        port: u16,
        enabled: bool,
    };
    const cfg = try decode(Config, a, v, .{});
    try testing.expectEqualStrings("yaml", cfg.title);
    try testing.expectEqual(@as(u16, 8080), cfg.port);
    try testing.expectEqual(true, cfg.enabled);
}

test "decodeFloat: f32 overflow from out-of-range f64 value" {
    const C = struct { x: f32 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectError(error.Overflow, parseInto(C, ar.allocator(), "x: 1e40\n", .{}));
}

test "decodeFloat: f16 overflow from out-of-range f64 value" {
    const C = struct { x: f16 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectError(error.Overflow, parseInto(C, ar.allocator(), "x: 1e5\n", .{}));
}

test "decodeFloat: in-range f32 succeeds" {
    const C = struct { x: f32 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const c = try parseInto(C, ar.allocator(), "x: 3.0e38\n", .{});
    try testing.expect(!std.math.isInf(c.x));
}

test "decodeFloat: f64 field with large value succeeds (no narrowing)" {
    const C = struct { x: f64 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const c = try parseInto(C, ar.allocator(), "x: 1e40\n", .{});
    try testing.expect(!std.math.isInf(c.x));
}

test "decodeFloat: .inf YAML source passes through to f32 inf" {
    const C = struct { x: f32 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const c = try parseInto(C, ar.allocator(), "x: .inf\n", .{});
    try testing.expect(std.math.isInf(c.x) and c.x > 0);
}

test "decodeArray: zero-length array field compiles and decodes empty seq" {
    const C = struct { a: [0]u8 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const c = try parseInto(C, ar.allocator(), "a: []\n", .{});
    try testing.expectEqual(@as(usize, 0), c.a.len);
}

test "decodeArray: non-empty seq into zero-length array is TypeMismatch" {
    const C = struct { a: [0]u8 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectError(error.TypeMismatch, parseInto(C, ar.allocator(), "a: [1]\n", .{}));
}


// ----- streaming typed decode (no Value tree) -----

const parser_mod = @import("parser.zig");
const diagnostic_mod = @import("diagnostic.zig");
const Event = parser_mod.Event;

const StreamError = composer.Error || DecodeError;

/// Comptime: true when decoding `T` requires a materialized `Value` (or a
/// whole-mapping view) somewhere in its type closure: `Value` targets,
/// `fromYaml` hooks, unions (the `yaml_tag` discriminator may follow the
/// payload), flattened non-struct fields, and effective-key collisions
/// between a struct and its flattened fields. Those decode through the
/// tree path; everything else streams event-to-field.
fn needsTree(comptime T: type) bool {
    return comptime needsTreeImpl(T, &.{});
}

fn needsTreeImpl(comptime T: type, comptime seen: []const type) bool {
    comptime {
        for (seen) |S| if (S == T) return false;
        if (T == Value) return true;
        const seen2 = seen ++ &[_]type{T};
        return switch (@typeInfo(T)) {
            .@"struct" => |s| blk: {
                if (@hasDecl(T, "fromYaml")) break :blk true;
                for (s.fields) |f| {
                    if (isFlattened(T, f.name) and @typeInfo(f.type) != .@"struct") break :blk true;
                }
                if (hasKeyCollisions(T)) break :blk true;
                for (s.fields) |f| {
                    if (needsTreeImpl(f.type, seen2)) break :blk true;
                }
                break :blk false;
            },
            .@"union" => true,
            .pointer => |p| p.size == .slice and !(p.child == u8 and p.is_const) and needsTreeImpl(p.child, seen2),
            .array => |a| needsTreeImpl(a.child, seen2),
            .optional => |o| needsTreeImpl(o.child, seen2),
            else => false,
        };
    }
}

/// One streamable destination: the effective wire key, the field path
/// from the outer struct (flattened fields contribute nested paths),
/// and the leaf type.
const EffField = struct {
    key: []const u8,
    path: []const []const u8,
    Type: type,
};

/// Effective field list of `T` with flattened inner structs expanded,
/// skipped fields excluded. Mirrors `expectedKeys` exactly.
fn effFieldsOf(comptime T: type, comptime prefix: []const []const u8) []const EffField {
    comptime {
        var out: []const EffField = &.{};
        for (@typeInfo(T).@"struct".fields) |f| {
            if (isSkipped(T, f.name)) continue;
            const p2 = prefix ++ &[_][]const u8{f.name};
            if (isFlattened(T, f.name)) {
                out = out ++ effFieldsOf(f.type, p2);
            } else {
                out = out ++ &[_]EffField{.{ .key = renamedKey(T, f.name), .path = p2, .Type = f.type }};
            }
        }
        return out;
    }
}

/// Two effective fields sharing one wire key (an outer field colliding
/// with a flattened inner one). The tree path decodes such a key into
/// every destination; a single event stream cannot, so collide -> tree.
fn hasKeyCollisions(comptime T: type) bool {
    comptime {
        const fs = effFieldsOf(T, &.{});
        for (fs, 0..) |a, i| {
            for (fs[i + 1 ..]) |b| {
                if (std.mem.eql(u8, a.key, b.key)) return true;
            }
        }
        return false;
    }
}

fn PathType(comptime T: type, comptime path: []const []const u8) type {
    comptime {
        var C = T;
        for (path) |seg| C = @FieldType(C, seg);
        return C;
    }
}

fn pathPtr(comptime T: type, comptime path: []const []const u8, base: *T) *PathType(T, path) {
    if (comptime path.len == 0) return base;
    return pathPtr(@FieldType(T, path[0]), path[1..], &@field(base.*, path[0]));
}

/// Assign defaults to every `yaml_skip` field of `T`, recursing through
/// flattened inner structs. Mirrors the skip branch of `decodeStruct`.
fn assignSkippedDefaults(comptime T: type, comptime prefix: []const []const u8, comptime Outer: type, out: *Outer) void {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (comptime isSkipped(T, f.name)) {
            const dv = comptime f.defaultValue() orelse
                @compileError("yaml_skip field `" ++ f.name ++ "` on " ++ @typeName(T) ++ " has no default value");
            pathPtr(Outer, prefix ++ &[_][]const u8{f.name}, out).* = dv;
        } else if (comptime isFlattened(T, f.name)) {
            assignSkippedDefaults(f.type, prefix ++ &[_][]const u8{f.name}, Outer, out);
        }
    }
}

/// Streaming `parseInto`: one parser-event pass decoding directly into
/// `T`. Success semantics match compose-then-decode exactly: scalars go
/// through the composer's own cook + schema-resolve (`composeScalar`) and
/// the existing scalar decoders, and skipped subtrees still cook every
/// scalar so validation is identical. Anything the pass cannot reproduce
/// faithfully -- anchors, aliases, merge keys, collection tags, multiple
/// documents -- returns an error, and the caller reruns the tree path,
/// whose error selection and diagnostics are canonical.
fn streamParseInto(comptime T: type, arena: Allocator, src: []const u8, options: composer.ParseOptions) StreamError!T {
    var stream_options = options;
    stream_options.errors = null;
    stream_options.spans = null;
    var p = parser_mod.Parser.init(arena, src);
    defer p.deinit();
    // Scalar-cooking context reusing the composer's pipeline. Only
    // composeScalar is called on it, which never touches the parser
    // field, so that field stays undefined.
    var cook = composer.Composer{
        .arena = arena,
        .options = stream_options,
        .p = undefined,
        .sink = diagnostic_mod.Sink.init(arena, null),
    };

    const first = (try p.next()) orelse return error.YamlParseError;
    if (first.kind != .stream_start) return error.YamlParseError;
    const ds = (try p.next()) orelse return error.YamlParseError;
    if (ds.kind != .document_start) return error.YamlParseError;

    const root_ev = (try p.next()) orelse return error.YamlParseError;
    var out: T = undefined;
    if (root_ev.kind == .document_end) {
        // Empty document: the composer yields null.
        var path: PathBuilder = .{ .buf = .empty };
        out = try decodeInner(T, arena, .null, stream_options, &path);
    } else {
        out = try streamValue(T, &p, &cook, root_ev, 0, stream_options);
        const de = (try p.next()) orelse return error.YamlParseError;
        if (de.kind != .document_end) return error.YamlParseError;
    }
    // Exactly one document, then end of stream (parse() rejects streams
    // with zero or several documents).
    const tail = (try p.next()) orelse return error.YamlParseError;
    if (tail.kind != .stream_end) return error.YamlParseError;
    return out;
}

fn streamValue(comptime T: type, p: *parser_mod.Parser, cook: *composer.Composer, ev: Event, depth: usize, options: composer.ParseOptions) StreamError!T {
    // An anchored node may be aliased later; retaining it needs the tree.
    if (ev.anchor != null) return error.YamlParseError;

    if (ev.kind == .scalar) {
        // Any target decodes a scalar through the tree path's own scalar
        // pipeline: composeScalar cooks + schema-resolves, decodeInner
        // applies the full target-type semantics (optionals, nulls,
        // enums, numbers, strings). Diagnostics are off, so the path
        // builder never allocates.
        var path: PathBuilder = .{ .buf = .empty };
        const v = try cook.composeScalar(ev);
        return decodeInner(T, cook.arena, v, options, &path);
    }
    if (ev.kind == .alias) return error.YamlParseError;

    const info = @typeInfo(T);
    if (comptime info == .optional) {
        // Container events are never null; scalars were handled above.
        return try streamValue(info.optional.child, p, cook, ev, depth, options);
    }

    // Collection tags (!!seq / !!map / mismatches) are validated by the
    // composer; rather than replicate that policy, hand tagged
    // collections to the tree path.
    if (ev.tag != null) return error.YamlParseError;

    return switch (comptime @typeInfo(T)) {
        .pointer => |ptr| try streamPointer(T, ptr, p, cook, ev, depth, options),
        .array => |arr| try streamFixedArray(T, arr, p, cook, ev, depth, options),
        .@"struct" => try streamStruct(T, p, cook, ev, depth, options),
        // Scalar targets facing a collection event: structural mismatch.
        .bool, .int, .float, .@"enum" => error.TypeMismatch,
        else => @compileError("yaml decode: unsupported type " ++ @typeName(T)),
    };
}

fn streamPointer(comptime T: type, comptime ptr: std.builtin.Type.Pointer, p: *parser_mod.Parser, cook: *composer.Composer, ev: Event, depth: usize, options: composer.ParseOptions) StreamError!T {
    if (comptime ptr.size != .slice) @compileError("yaml decode: only slice pointers supported, got " ++ @typeName(T));
    if (comptime (ptr.child == u8 and ptr.is_const)) {
        // String target facing a collection event: mismatch.
        return error.TypeMismatch;
    }
    if (ev.kind != .sequence_start) return error.TypeMismatch;
    if (depth >= options.max_depth) return error.NestingTooDeep;
    var items: std.ArrayList(ptr.child) = .empty;
    while (true) {
        const child = (try p.next()) orelse return error.YamlParseError;
        if (child.kind == .sequence_end) break;
        try items.append(cook.arena, try streamValue(ptr.child, p, cook, child, depth + 1, options));
    }
    return items.items;
}

fn streamFixedArray(comptime T: type, comptime arr: std.builtin.Type.Array, p: *parser_mod.Parser, cook: *composer.Composer, ev: Event, depth: usize, options: composer.ParseOptions) StreamError!T {
    if (ev.kind != .sequence_start) return error.TypeMismatch;
    if (depth >= options.max_depth) return error.NestingTooDeep;
    var out: T = undefined;
    var i: usize = 0;
    while (true) {
        const child = (try p.next()) orelse return error.YamlParseError;
        if (child.kind == .sequence_end) break;
        if (comptime arr.len == 0) return error.TypeMismatch;
        if (i >= arr.len) return error.TypeMismatch;
        out[i] = try streamValue(arr.child, p, cook, child, depth + 1, options);
        i += 1;
    }
    if (i != arr.len) return error.TypeMismatch;
    return out;
}

fn streamStruct(comptime T: type, p: *parser_mod.Parser, cook: *composer.Composer, ev: Event, depth: usize, options: composer.ParseOptions) StreamError!T {
    comptime validateAnnotations(T);
    if (ev.kind != .mapping_start) return error.TypeMismatch;
    if (depth >= options.max_depth) return error.NestingTooDeep;

    const eff = comptime effFieldsOf(T, &.{});
    var seen = [_]bool{false} ** eff.len;
    var out: T = undefined;
    assignSkippedDefaults(T, &.{}, T, &out);

    while (true) {
        const kev = (try p.next()) orelse return error.YamlParseError;
        if (kev.kind == .mapping_end) break;

        if (kev.anchor != null or kev.kind == .alias) return error.YamlParseError;
        if (kev.kind == .scalar) {
            // A merge key rewrites the mapping from retained values; only
            // the tree path can do that. Detection mirrors the composer:
            // plain, untagged, raw content `<<`, with merge_keys on.
            if (options.merge_keys and kev.scalar_style == .plain and kev.tag == null and std.mem.eql(u8, kev.value, "<<"))
                return error.YamlParseError;
            const kv = try cook.composeScalar(kev);
            const vev = (try p.next()) orelse return error.YamlParseError;
            if (kv == .string) {
                var matched = false;
                inline for (eff, 0..) |f, idx| {
                    if (!matched and std.mem.eql(u8, kv.string, f.key)) {
                        // A duplicate key re-decodes and overwrites: last
                        // wins, matching mapGet's backwards scan.
                        pathPtr(T, f.path, &out).* = try streamValue(f.Type, p, cook, vev, depth + 1, options);
                        seen[idx] = true;
                        matched = true;
                    }
                }
                if (!matched) {
                    if (!options.ignore_unknown_fields) return error.UnknownField;
                    try skipNode(p, cook, vev, depth + 1, options);
                }
            } else {
                // Non-string keys are invisible to struct decode: never
                // matched, never unknown. Skip the value, still cooking
                // its scalars so validation matches the tree.
                try skipNode(p, cook, vev, depth + 1, options);
            }
        } else {
            // Complex (collection) key: equally invisible. Skip both halves.
            try skipNode(p, cook, kev, depth + 1, options);
            const vev = (try p.next()) orelse return error.YamlParseError;
            try skipNode(p, cook, vev, depth + 1, options);
        }
    }

    inline for (eff, 0..) |f, idx| {
        if (!seen[idx]) {
            const Parent = PathType(T, f.path[0 .. f.path.len - 1]);
            const fi = comptime blk: {
                for (@typeInfo(Parent).@"struct".fields) |sf| {
                    if (std.mem.eql(u8, sf.name, f.path[f.path.len - 1])) break :blk sf;
                }
                unreachable;
            };
            const dv_opt = comptime fi.defaultValue();
            if (dv_opt) |dv| {
                pathPtr(T, f.path, &out).* = dv;
            } else if (comptime @typeInfo(f.Type) == .optional) {
                pathPtr(T, f.path, &out).* = null;
            } else {
                return error.MissingField;
            }
        }
    }
    return out;
}

/// Structurally consume one node without decoding it, preserving the
/// tree path's validation: every scalar is still cooked (bad escapes,
/// tag mismatches error), depth stays bounded, and anchors / aliases /
/// tagged collections bail to the tree.
fn skipNode(p: *parser_mod.Parser, cook: *composer.Composer, ev: Event, depth: usize, options: composer.ParseOptions) StreamError!void {
    if (ev.anchor != null) return error.YamlParseError;
    switch (ev.kind) {
        .alias => return error.YamlParseError,
        .scalar => {
            _ = try cook.composeScalar(ev);
        },
        .sequence_start, .mapping_start => {
            if (ev.tag != null) return error.YamlParseError;
            if (depth >= options.max_depth) return error.NestingTooDeep;
            const is_mapping = ev.kind == .mapping_start;
            var key_position = true;
            while (true) {
                const child = (try p.next()) orelse return error.YamlParseError;
                switch (child.kind) {
                    .sequence_end, .mapping_end => break,
                    else => {
                        // A merge key rewrites even a skipped mapping from
                        // retained values (and errors on a non-mapping
                        // source), so it needs the tree path exactly like a
                        // decoded mapping does.
                        if (is_mapping and key_position and child.kind == .scalar and
                            options.merge_keys and child.scalar_style == .plain and
                            child.tag == null and std.mem.eql(u8, child.value, "<<"))
                            return error.YamlParseError;
                        try skipNode(p, cook, child, depth + 1, options);
                        key_position = !key_position;
                    },
                }
            }
        },
        else => return error.YamlParseError,
    }
}


/// Allocator wrapper that counts bytes handed out. Used to bound the
/// allocation cost of the streaming typed decode path.
const CountingAllocator = struct {
    child: Allocator,
    total: usize = 0,

    fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.total += len;
        return self.child.vtable.alloc(self.child.ptr, len, alignment, ret_addr);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) self.total += new_len - memory.len;
        return self.child.vtable.resize(self.child.ptr, memory, alignment, new_len, ret_addr);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) self.total += new_len - memory.len;
        return self.child.vtable.remap(self.child.ptr, memory, alignment, new_len, ret_addr);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.vtable.free(self.child.ptr, memory, alignment, ret_addr);
    }
};

test "parseInto streams: allocation bounded, no Value tree materialized" {
    // A block sequence of records large enough that tree materialization
    // (a Value box plus an Entry list per element) dwarfs the decoded
    // output. The streaming path must stay within a small multiple of the
    // input size; the tree path exceeds it severalfold.
    const Rec = struct {
        id: u64,
        name: []const u8,
        active: bool,
        score: f64,
        tags: []const []const u8,
    };

    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        try src.print(testing.allocator,
            "- id: {d}\n  name: record-{d}\n  active: {}\n  score: {d}.5\n  tags: [a, b]\n",
            .{ i, i, i % 2 == 0, i % 100 });
    }

    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var counting: CountingAllocator = .{ .child = ar.allocator() };

    const out = try parseInto([]const Rec, counting.allocator(), src.items, .{});
    try testing.expectEqual(@as(usize, 2000), out.len);
    try testing.expectEqualStrings("record-1999", out[1999].name);

    var tree_arena = ArenaAllocator.init(testing.allocator);
    defer tree_arena.deinit();
    var tree_counting: CountingAllocator = .{ .child = tree_arena.allocator() };
    const tree_out = try parseIntoTree([]const Rec, tree_counting.allocator(), src.items, .{});
    try testing.expectEqual(@as(usize, 2000), tree_out.len);

    // The streaming path allocates the decoded output plus list-growth
    // copies; the tree path materializes a Value and Entry list per
    // element on top. Bound the streaming path well under the tree cost
    // so a regression to tree materialization fails loudly.
    try testing.expect(counting.total <= src.items.len * 8);
    try testing.expect(counting.total * 3 <= tree_counting.total);
}

test "streaming equivalence: duplicate key with invalid first occurrence decodes last-wins" {
    // mapGet scans backwards (last wins), so a type-invalid FIRST
    // occurrence must not fail parseInto: the streaming pass errors,
    // falls back to the tree, and succeeds.
    const T = struct { a: u32 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const v = try parseInto(T, ar.allocator(), "a: not an int\na: 7\n", .{});
    try testing.expectEqual(@as(u32, 7), v.a);
}

test "streaming: anchors, aliases, and merge keys fall back to the tree and decode" {
    const T = struct {
        base: struct { x: u32, y: u32 },
        derived: struct { x: u32, y: u32, z: u32 },
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const v = try parseInto(T, ar.allocator(),
        \\base: &b { x: 1, y: 2 }
        \\derived: { <<: *b, z: 3 }
    , .{});
    try testing.expectEqual(@as(u32, 1), v.derived.x);
    try testing.expectEqual(@as(u32, 2), v.derived.y);
    try testing.expectEqual(@as(u32, 3), v.derived.z);
}

test "streaming: valid collection tag falls back and decodes" {
    const T = struct { xs: []const u32 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const v = try parseInto(T, ar.allocator(), "xs: !!seq [1, 2, 3]\n", .{});
    try testing.expectEqual(@as(usize, 3), v.xs.len);
}

test "streaming: non-string and complex keys stay invisible to struct decode" {
    const T = struct { a: u32 = 9 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    // Integer key and a flow-sequence key: both skipped, never unknown.
    const v = try parseInto(T, ar.allocator(), "5: ignored\n[1, 2]: also ignored\na: 3\n", .{});
    try testing.expectEqual(@as(u32, 3), v.a);
}

test "streaming: scalar semantics match the tree (quoted null is a string, block scalar, tags)" {
    const T = struct {
        s: []const u8,
        n: ?u32,
        text: []const u8,
        forced: []const u8,
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const v = try parseInto(T, ar.allocator(),
        \\s: "null"
        \\n: ~
        \\text: |
        \\  line one
        \\  line two
        \\forced: !!str 123
    , .{});
    try testing.expectEqualStrings("null", v.s);
    try testing.expectEqual(@as(?u32, null), v.n);
    try testing.expectEqualStrings("line one\nline two\n", v.text);
    try testing.expectEqualStrings("123", v.forced);
}

test "streaming: multi-document input errors like the tree path" {
    const T = struct { a: u32 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectError(error.YamlParseError, parseInto(T, ar.allocator(), "---\na: 1\n---\na: 2\n", .{}));
}

test "streaming: deep nesting inside ignored unknown field is depth-bounded" {
    const T = struct { a: u32 = 0 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "junk: ");
    try src.appendNTimes(testing.allocator, '[', 200);
    try src.appendNTimes(testing.allocator, ']', 200);
    try src.appendSlice(testing.allocator, "\na: 1\n");
    try testing.expectError(error.NestingTooDeep, parseInto(T, ar.allocator(), src.items, .{ .ignore_unknown_fields = true }));
}

test "streaming: bad scalar inside skipped unknown subtree still errors" {
    // The tree cooks every scalar in the document; a skipped subtree with
    // a tag mismatch must error identically through the streaming path.
    const T = struct { a: u32 = 0 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectError(error.YamlParseError, parseInto(T, ar.allocator(), "junk: !!int notanint\na: 1\n", .{ .ignore_unknown_fields = true }));
}

test "streaming: flatten inside flatten decodes from one mapping" {
    const Innermost = struct { z: u32 };
    const Inner = struct {
        y: u32,
        deep: Innermost,
        pub const yaml_flatten = .{"deep"};
    };
    const T = struct {
        x: u32,
        flat: Inner,
        skipped: u8 = 42,
        pub const yaml_flatten = .{"flat"};
        pub const yaml_skip = .{"skipped"};
    };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const v = try parseInto(T, ar.allocator(), "x: 1\ny: 2\nz: 3\n", .{});
    try testing.expectEqual(@as(u32, 1), v.x);
    try testing.expectEqual(@as(u32, 2), v.flat.y);
    try testing.expectEqual(@as(u32, 3), v.flat.deep.z);
    try testing.expectEqual(@as(u8, 42), v.skipped);
    try testing.expectError(error.UnknownField, parseInto(T, ar.allocator(), "x: 1\ny: 2\nz: 3\nw: 4\n", .{}));
    try testing.expectError(error.UnknownField, parseInto(T, ar.allocator(), "x: 1\ny: 2\nz: 3\nskipped: 9\n", .{}));
}

test "streaming: empty document decodes null semantics" {
    const T = struct { a: u32 = 5 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    // Empty INPUT is zero documents: YamlParseError from parse() either
    // way. An explicit empty DOCUMENT composes to null: decode of null
    // into a struct is MissingField; into an optional it is null.
    try testing.expectError(error.YamlParseError, parseInto(T, ar.allocator(), "", .{}));
    try testing.expectError(error.MissingField, parseInto(T, ar.allocator(), "---\n", .{}));
    const opt = try parseInto(?u32, ar.allocator(), "---\n", .{});
    try testing.expectEqual(@as(?u32, null), opt);
}

test "streaming: merge key inside skipped unknown subtree errors like the tree" {
    // Fuzz-found: `<<:` with a null value nested under an ignored unknown
    // field. The tree composes the subtree and rejects the merge source;
    // the streaming skip must not sail past it.
    const T = struct { name: []const u8 };
    var ar = ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectError(error.YamlParseError, parseInto(T, ar.allocator(),
        "name: x\njunk:\n  <<:\n  host: h\n", .{ .ignore_unknown_fields = true }));
}
