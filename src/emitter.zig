//! Block-style YAML emitter.
//!
//! Walks a `Value` tree and writes YAML 1.2 block-style text to a
//! `std.Io.Writer`. Mappings and sequences emit one entry/element per
//! line, indented `options.indent` spaces per nesting level. Empty
//! collections emit flow-empty `{}`/`[]` (block-empty is ambiguous).
//!
//! Scalar styling picks the narrowest round-trip-safe form: a string
//! emits PLAIN when that survives a re-parse under the core schema and
//! carries no syntactic indicator, otherwise double-quoted with escapes.
//! The quoting predicate is deliberately conservative -- when in doubt it
//! quotes, since a mis-parse silently corrupts the tree.
//!
//! Floats use std.fmt.float.render in shortest round-trip mode, adapted
//! to YAML: special values emit `.inf`/`-.inf`/`.nan`; integer-valued
//! finite floats get a `.0` suffix so they re-parse as `.float`.
//!
//! Non-scalar mapping keys (seq/map keys) are rare in real YAML. Block
//! context cannot carry a flow-collection key that this parser re-reads,
//! so a mapping containing ANY such key emits entirely in flow style with
//! the explicit-key indicator (`{? [1, 2]: value}`), which round-trips.
//! Scalar keys (the common case) take the same scalar-quoting path as
//! string values.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const value_mod = @import("value.zig");
const schema = @import("schema.zig");
const decode_mod = @import("decode.zig");

pub const Value = value_mod.Value;
pub const Entry = value_mod.Entry;

pub const EmitOptions = struct { indent: usize = 2 };

/// Writer failures, plus `NestingTooDeep` when a hand-built `Value` tree
/// exceeds `max_emit_depth` levels of collection nesting.
/// `UnrepresentableScalar` is reserved for scalars that cannot be
/// emitted; the current core-style emitter represents every `Value`, so
/// it does not fire in practice. `UnrepresentableInt` fires when an
/// integer value exceeds the i128 data model limit (e.g. a u128 field
/// whose value exceeds maxInt(i128)). `OutOfMemory` arises only on the
/// `emitTyped` path, which builds a `Value` tree (and any `toYaml` hook
/// values) in the caller's arena.
pub const EmitError = Io.Writer.Error || error{ UnrepresentableScalar, UnrepresentableInt, NestingTooDeep, OutOfMemory };

/// Maximum collection nesting depth. Matches the parser's default
/// `max_depth` (128) so hand-built trees get the same bound.
const max_emit_depth = 128;

/// Emit one document as block-style YAML, terminated by a trailing
/// newline. A root scalar emits on its own line; a root collection emits
/// its entries/elements at indent level 0.
pub fn emit(w: *Io.Writer, value: Value, options: EmitOptions) EmitError!void {
    try emitDocument(w, value, options);
}

/// Emit a multi-document stream: each document is preceded by a `---\n`
/// marker EXCEPT the first, yielding the conventional
/// `doc1\n---\ndoc2\n` form. A single-element slice emits no marker.
pub fn emitStream(w: *Io.Writer, values: []const Value, options: EmitOptions) EmitError!void {
    for (values, 0..) |v, i| {
        if (i > 0) try w.writeAll("---\n");
        try emitDocument(w, v, options);
    }
}

/// Emit a typed Zig value as block-style YAML, consulting the same
/// `yaml_rename` / `yaml_skip` / `yaml_flatten` / `yaml_tag` annotations
/// and `toYaml` hooks that typed decoding consults, so output decodes
/// back via `parseInto(T, ...)`. Builds a `Value` from `value` in `arena`
/// (honoring annotations), then emits it with the round-trip-safe quoting.
///
/// Null optional fields are omitted from mappings entirely (decode maps
/// the absent key back to null). Enums emit their tag name as a string.
/// Tagged unions emit the discriminator entry first, then the payload's
/// fields inline in the same mapping. Embedded `Value` fields emit
/// dynamically. `arena` backs the built tree and any `toYaml` hook values.
///
/// `value`'s own type drives annotation lookup: pass a typed value, not an
/// anonymous struct literal -- anonymous literals carry no declarations, so
/// `yaml_rename` / `yaml_skip` / `yaml_flatten` / `yaml_tag` would silently
/// not apply.
pub fn emitTyped(w: *Io.Writer, value: anytype, arena: std.mem.Allocator, options: EmitOptions) EmitError!void {
    const T = @TypeOf(value);
    const built = try buildValue(T, value, arena);
    try emit(w, built, options);
}

/// Reflect `value` of type `T` into a `Value`, honoring the same
/// annotations and `toYaml` hook as `emitTyped`. Symmetric with decode's
/// type dispatch so the result round-trips.
fn buildValue(comptime T: type, value: T, arena: std.mem.Allocator) (std.mem.Allocator.Error || error{UnrepresentableInt})!Value {
    if (T == Value) return value;

    // Custom toYaml hook short-circuit, symmetric with decode's fromYaml.
    if (comptime (@typeInfo(T) == .@"struct" and @hasDecl(T, "toYaml"))) {
        comptime {
            const fn_info = @typeInfo(@TypeOf(T.toYaml)).@"fn";
            if (fn_info.params.len != 2) {
                @compileError(@typeName(T) ++ ".toYaml must take exactly 2 params: (Self, Allocator)");
            }
        }
        return T.toYaml(value, arena);
    }

    if (comptime (@typeInfo(T) == .@"union" and @hasDecl(T, "yaml_tag"))) {
        return buildTaggedUnion(T, value, arena);
    }

    return switch (@typeInfo(T)) {
        .bool => .{ .bool = value },
        // Value.int is i128; a u128 value exceeding maxInt(i128) cannot be represented
        // in the YAML data model. Use a checked cast rather than a compile error or silent wrap.
        .int => .{ .int = std.math.cast(i128, value) orelse return error.UnrepresentableInt },
        .float => .{ .float = @floatCast(value) },
        .pointer => |p| blk: {
            if (p.size != .slice) @compileError("yaml emitTyped: only slice pointers supported, got " ++ @typeName(T));
            if (p.child == u8 and p.is_const) break :blk .{ .string = value };
            break :blk buildSeq(p.child, value, arena);
        },
        .array => |a| buildSeq(a.child, &value, arena),
        .optional => |o| if (value) |inner| try buildValue(o.child, inner, arena) else .null,
        .@"struct" => blk: {
            comptime decode_mod.validateAnnotations(T);
            var entries: std.ArrayList(Entry) = .empty;
            try buildStructFields(T, value, arena, &entries);
            break :blk .{ .map = entries.items };
        },
        .@"enum" => .{ .string = @tagName(value) },
        else => @compileError("yaml emitTyped: unsupported type " ++ @typeName(T)),
    };
}

fn buildSeq(comptime Child: type, items: []const Child, arena: std.mem.Allocator) (std.mem.Allocator.Error || error{UnrepresentableInt})!Value {
    const out = try arena.alloc(Value, items.len);
    for (items, 0..) |item, i| {
        out[i] = try buildValue(Child, item, arena);
    }
    return .{ .seq = out };
}

/// Append `value`'s fields as map entries to `entries`, so that flattened
/// fields and tagged-union payloads inline into the parent mapping.
/// Skipped fields are dropped; null optionals are omitted entirely.
fn buildStructFields(comptime T: type, value: T, arena: std.mem.Allocator, entries: *std.ArrayList(Entry)) (std.mem.Allocator.Error || error{UnrepresentableInt})!void {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime decode_mod.isSkipped(T, field.name)) continue;
        const fv = @field(value, field.name);
        if (comptime decode_mod.isFlattened(T, field.name)) {
            comptime decode_mod.validateAnnotations(field.type);
            try buildStructFields(field.type, fv, arena, entries);
        } else if (comptime @typeInfo(field.type) == .optional) {
            // Null optionals are omitted; decode maps the absent key back
            // to null, so the round-trip is lossless.
            if (fv) |inner| {
                const key = comptime decode_mod.renamedKey(T, field.name);
                const v = try buildValue(@typeInfo(field.type).optional.child, inner, arena);
                try entries.append(arena, .{ .key = .{ .string = key }, .value = v });
            }
        } else {
            const key = comptime decode_mod.renamedKey(T, field.name);
            const v = try buildValue(field.type, fv, arena);
            try entries.append(arena, .{ .key = .{ .string = key }, .value = v });
        }
    }
}

fn buildTaggedUnion(comptime T: type, value: T, arena: std.mem.Allocator) (std.mem.Allocator.Error || error{UnrepresentableInt})!Value {
    comptime decode_mod.validateAnnotations(T);
    const active = std.meta.activeTag(value);
    var entries: std.ArrayList(Entry) = .empty;
    inline for (@typeInfo(T).@"union".fields) |union_field| {
        if (active == @field(std.meta.Tag(T), union_field.name)) {
            try entries.append(arena, .{
                .key = .{ .string = T.yaml_tag },
                .value = .{ .string = comptime decode_mod.renamedKey(T, union_field.name) },
            });
            if (union_field.type != void) {
                try buildStructFields(union_field.type, @field(value, union_field.name), arena, &entries);
            }
        }
    }
    return .{ .map = entries.items };
}

/// Render a scalar `Value` to its YAML scalar bytes (no trailing newline),
/// using the same round-trip-safe quoting as block-style emission: a string
/// that would re-parse as null/bool/int/float (or carries a syntactic
/// indicator) is double-quoted, everything else stays plain. Collections are
/// rejected with `UnrepresentableScalar`; the document edit path renders only
/// scalars through here.
pub fn renderScalar(w: *Io.Writer, value: Value) EmitError!void {
    switch (value) {
        .seq, .map => return error.UnrepresentableScalar,
        else => try emitScalar(w, value),
    }
}

fn emitDocument(w: *Io.Writer, value: Value, options: EmitOptions) EmitError!void {
    switch (value) {
        .seq => |s| {
            if (s.len == 0) {
                try w.writeAll("[]\n");
            } else {
                try emitBlockSeq(w, s, options, 0);
            }
        },
        .map => |m| {
            if (m.len == 0) {
                try w.writeAll("{}\n");
            } else if (mapHasComplexKey(m)) {
                try emitFlow(w, value, 0);
                try w.writeByte('\n');
            } else {
                try emitBlockMap(w, m, options, 0);
            }
        },
        else => {
            try emitScalar(w, value);
            try w.writeByte('\n');
        },
    }
}

fn writeIndent(w: *Io.Writer, options: EmitOptions, depth: usize) EmitError!void {
    try w.splatByteAll(' ', options.indent * depth);
}

/// A non-empty collection nested under a mapping key or sequence dash
/// breaks to the next line and indents one level deeper; a scalar, an
/// empty collection, or a complex-keyed map (emitted inline in flow)
/// stays after the `:`/`-`.
fn breaksToBlock(v: Value) bool {
    return switch (v) {
        .seq => |s| s.len > 0,
        .map => |m| m.len > 0 and !mapHasComplexKey(m),
        else => false,
    };
}

/// True when any entry's key is a non-scalar (seq/map). Such a mapping
/// cannot be emitted in block style here (the parser rejects a flow-
/// collection block key), so it round-trips only via full flow style.
fn mapHasComplexKey(entries: []const Entry) bool {
    for (entries) |e| {
        switch (e.key) {
            .seq, .map => return true,
            else => {},
        }
    }
    return false;
}

fn emitBlockMap(w: *Io.Writer, entries: []const Entry, options: EmitOptions, depth: usize) EmitError!void {
    if (depth > max_emit_depth) return error.NestingTooDeep;
    for (entries) |e| {
        try writeIndent(w, options, depth);
        try emitKey(w, e.key);
        try emitValueAfterMarker(w, e.value, options, depth);
    }
}

fn emitBlockSeq(w: *Io.Writer, elems: []const Value, options: EmitOptions, depth: usize) EmitError!void {
    if (depth > max_emit_depth) return error.NestingTooDeep;
    for (elems) |elem| {
        try writeIndent(w, options, depth);
        try w.writeByte('-');
        try emitValueAfterMarker(w, elem, options, depth);
    }
}

/// Emit the value following a `:` (mapping) or `-` (sequence) marker that
/// is already written. A non-empty collection breaks to the next line at
/// depth+1; everything else stays inline after a single space. The caller
/// has written the key+colon or the dash but no separator yet.
fn emitValueAfterMarker(w: *Io.Writer, v: Value, options: EmitOptions, depth: usize) EmitError!void {
    if (breaksToBlock(v)) {
        try w.writeByte('\n');
        switch (v) {
            .seq => |s| try emitBlockSeq(w, s, options, depth + 1),
            .map => |m| try emitBlockMap(w, m, options, depth + 1),
            else => unreachable,
        }
    } else {
        try w.writeByte(' ');
        switch (v) {
            .seq => try w.writeAll("[]\n"),
            .map => |m| {
                // Empty, or complex-keyed (block style impossible) -> flow.
                if (m.len == 0) try w.writeAll("{}\n") else {
                    try emitFlow(w, v, depth + 1);
                    try w.writeByte('\n');
                }
            },
            else => {
                try emitScalar(w, v);
                try w.writeByte('\n');
            },
        }
    }
}

/// Scalar mapping key in block context, followed by `:` (no trailing
/// space; the value path adds the separator). Block maps with a non-
/// scalar key are diverted to flow style upstream, so only scalar keys
/// reach here.
fn emitKey(w: *Io.Writer, key: Value) EmitError!void {
    try emitScalar(w, key);
    try w.writeByte(':');
}

/// Compact flow representation, used for mappings with a non-scalar key
/// (and their nested values). Strings always double-quote here: flow
/// context gives plain scalars stricter terminators (`,`, `[`, `]`, `{`,
/// `}`, `:`), so quoting unconditionally is the conservative round-trip-
/// safe choice.
fn emitFlow(w: *Io.Writer, v: Value, depth: usize) EmitError!void {
    if (depth > max_emit_depth) return error.NestingTooDeep;
    switch (v) {
        .seq => |s| {
            try w.writeByte('[');
            for (s, 0..) |elem, i| {
                if (i > 0) try w.writeAll(", ");
                try emitFlow(w, elem, depth + 1);
            }
            try w.writeByte(']');
        },
        .map => |m| {
            try w.writeByte('{');
            for (m, 0..) |e, i| {
                if (i > 0) try w.writeAll(", ");
                // A flow collection key needs the explicit `? ` indicator;
                // without it the parser reads `[k]: v` as two entries.
                switch (e.key) {
                    .seq, .map => try w.writeAll("? "),
                    else => {},
                }
                try emitFlow(w, e.key, depth + 1);
                try w.writeAll(": ");
                try emitFlow(w, e.value, depth + 1);
            }
            try w.writeByte('}');
        },
        .string => |s| try emitDoubleQuoted(w, s),
        else => try emitScalar(w, v),
    }
}

fn emitScalar(w: *Io.Writer, v: Value) EmitError!void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .int => |i| try w.print("{d}", .{i}),
        .float => |f| try emitFloat(w, f),
        .string => |s| try emitString(w, s),
        .seq, .map => unreachable, // collections never reach the scalar path
    }
}

/// Special floats use YAML core spellings; finite floats use
/// std.fmt.float.render in shortest round-trip mode, with a `.0` suffix
/// on integer-valued output so it re-parses as `.float`, not `.int`.
fn emitFloat(w: *Io.Writer, f: f64) EmitError!void {
    if (std.math.isNan(f)) return w.writeAll(".nan");
    if (std.math.isInf(f)) return w.writeAll(if (f < 0) "-.inf" else ".inf");

    const a = @abs(f);
    if (a != 0 and (a < 1e-6 or a >= 1e21)) {
        var buf: [std.fmt.float.bufferSize(.scientific, f64)]u8 = undefined;
        const s = std.fmt.float.render(&buf, f, .{ .mode = .scientific }) catch unreachable;
        return w.writeAll(s); // scientific output always carries 'e': re-parses as float
    }
    var buf: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
    const s = std.fmt.float.render(&buf, f, .{ .mode = .decimal }) catch unreachable;
    try w.writeAll(s);
    for (s) |c| {
        if (c == '.' or c == 'e' or c == 'E') return;
    }
    try w.writeAll(".0");
}

// String styling

fn emitString(w: *Io.Writer, s: []const u8) EmitError!void {
    if (plainIsSafe(s)) {
        try w.writeAll(s);
    } else {
        try emitDoubleQuoted(w, s);
    }
}

/// Decide whether `s` survives emission as a PLAIN scalar: it must
/// re-parse as a string under the core schema AND carry no syntactic
/// construct that block context would read as structure. Conservative by
/// design -- a false "safe" silently corrupts the round-trip, a false
/// "unsafe" only adds quotes.
fn plainIsSafe(s: []const u8) bool {
    if (s.len == 0) return false; // empty plain resolves to null

    // Would the core schema read this text as null/bool/int/float? If so
    // it must quote to stay a string. (Covers true, 123, ~, null, .inf,
    // .nan, 0x1A, etc. -- schema.resolve owns the exact grammar.)
    if (!resolvesToString(s)) return false;

    // Leading/trailing whitespace is stripped or folded by the parser.
    if (s[0] == ' ' or s[0] == '\t') return false;
    if (s[s.len - 1] == ' ' or s[s.len - 1] == '\t') return false;

    // Control chars and newlines force double-quoting (escapes).
    for (s) |c| {
        if (c < 0x20 or c == 0x7f) return false;
    }

    // Leading indicator that opens a non-plain construct in block context.
    switch (s[0]) {
        '!', '&', '*', '#', '|', '>', '\'', '"', '%', '@', '`', ',', '[', ']', '{', '}' => return false,
        '-', '?', ':' => {
            // These are indicators only when followed by a space or when
            // they are the whole token; otherwise (e.g. `-1abc`, `:colon`)
            // they begin a valid plain scalar. Be conservative: a lone
            // `-`/`?`/`:` already resolves oddly, and `- `/`? `/`: ` would
            // open a block construct.
            if (s.len == 1) return false;
            if (s[1] == ' ') return false;
        },
        else => {},
    }

    // Document markers `---` / `...` (bare or followed by a space) at
    // column 0 are parsed as document-start/end directives, not scalars.
    // Because plainIsSafe has no positional context, reject them
    // unconditionally -- they are rare and quoting is the safe choice.
    if (std.mem.eql(u8, s, "---") or std.mem.eql(u8, s, "...")) return false;
    if (s.len >= 4 and (std.mem.startsWith(u8, s, "--- ") or std.mem.startsWith(u8, s, "... "))) return false;

    // A bare plain `<<` triggers merge semantics when used as a mapping key.
    // Quote it unconditionally (like `---`/`...` above) since plainIsSafe
    // has no positional context; quoting `<<` in other positions is harmless.
    if (std.mem.eql(u8, s, "<<")) return false;

    // Interior `: ` reads as a mapping value; ` #` reads as a comment.
    var i: usize = 0;
    while (i + 1 < s.len) : (i += 1) {
        if (s[i] == ':' and s[i + 1] == ' ') return false;
        if (s[i] == ' ' and s[i + 1] == '#') return false;
    }
    // A trailing `:` (last byte) reads as a mapping key indicator.
    if (s[s.len - 1] == ':') return false;

    return true;
}

/// True when the core schema leaves `s` as a `.string` (i.e. it is not a
/// null/bool/int/float spelling). Uses a throwaway fixed buffer allocator
/// since resolution only allocates to dupe a string result, which we
/// discard.
fn resolvesToString(s: []const u8) bool {
    var buf: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const resolved = schema.resolve(.core, fba.allocator(), s) catch {
        // Allocation only fails for a long string result, which means it
        // resolved to a string -- exactly the case we want.
        return true;
    };
    return resolved == .string;
}

fn emitDoubleQuoted(w: *Io.Writer, s: []const u8) EmitError!void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            0x08 => try w.writeAll("\\b"),
            0x09 => try w.writeAll("\\t"),
            0x0A => try w.writeAll("\\n"),
            0x0D => try w.writeAll("\\r"),
            else => {
                if (c < 0x20 or c == 0x7f) {
                    try w.print("\\x{x:0>2}", .{c});
                } else {
                    try w.writeByte(c); // printable ASCII and UTF-8 continuation bytes pass through
                }
            },
        }
    }
    try w.writeByte('"');
}

// Tests

const parse = @import("composer.zig").parse;
const parseStream = @import("composer.zig").parseStream;
const parseInto = @import("decode.zig").parseInto;

test "emitTyped honors annotations symmetric with decode" {
    const C = struct {
        pub const yaml_rename = .{ .listen_addr = "listen-addr" };
        pub const yaml_skip = .{"runtime"};
        listen_addr: []const u8,
        runtime: u32 = 0,
        port: u16,
    };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    // Typed const, not an anonymous literal: annotation lookup needs C's decls.
    const orig: C = .{ .listen_addr = "x", .port = 1 };
    try emitTyped(&aw.writer, orig, a, .{});
    const back = try parseInto(C, a, aw.written(), .{});
    try std.testing.expectEqualStrings("x", back.listen_addr);
    try std.testing.expectEqual(@as(u16, 1), back.port);
}

test "typed round-trip with seq and nested struct" {
    const C = struct { name: []const u8, tags: []const []const u8, inner: struct { k: i64 } };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const orig: C = .{ .name = "n", .tags = &.{ "a", "b" }, .inner = .{ .k = 7 } };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try emitTyped(&aw.writer, orig, a, .{});
    const back = try parseInto(C, a, aw.written(), .{});
    try std.testing.expectEqualStrings("b", back.tags[1]);
    try std.testing.expectEqual(@as(i64, 7), back.inner.k);
}

test "emitTyped tagged union and enum and null-omitted" {
    const Plugin = union(enum) {
        pub const yaml_tag = "kind";
        http: struct { port: u16 },
        exec: struct { cmd: []const u8 },
    };
    const Mode = enum { fast, slow };
    const C = struct { p: Plugin, mode: Mode, opt: ?[]const u8 };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const orig: C = .{ .p = .{ .http = .{ .port = 80 } }, .mode = .fast, .opt = null };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try emitTyped(&aw.writer, orig, a, .{});
    const back = try parseInto(C, a, aw.written(), .{});
    try std.testing.expectEqual(@as(u16, 80), back.p.http.port);
    try std.testing.expectEqual(Mode.fast, back.mode);
    try std.testing.expectEqual(@as(?[]const u8, null), back.opt);
}

test "toYaml hook" {
    const Version = struct {
        major: u32,
        minor: u32,
        pub fn toYaml(self: @This(), arena: std.mem.Allocator) std.mem.Allocator.Error!Value {
            const s = try std.fmt.allocPrint(arena, "{d}.{d}", .{ self.major, self.minor });
            return .{ .string = s };
        }
    };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const v: Version = .{ .major = 1, .minor = 2 };
    try emitTyped(&aw.writer, v, a, .{});
    // The hook returns the string "1.2"; the emitter quotes it so it
    // re-parses as a string rather than a float (round-trip-safe).
    try std.testing.expectEqualStrings("\"1.2\"\n", aw.written());
    const back = try parse(a, aw.written(), .{});
    try std.testing.expect(back == .string);
    try std.testing.expectEqualStrings("1.2", back.string);
}

test "combined rename+skip+flatten+tag round-trip" {
    const Inner = struct { verbose: bool };
    const C = struct {
        pub const yaml_rename = .{ .listen_addr = "listen-addr" };
        pub const yaml_skip = .{"secret"};
        pub const yaml_flatten = .{"common"};
        listen_addr: []const u8,
        secret: u32 = 0,
        common: Inner,
        port: u16,
    };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const orig: C = .{ .listen_addr = "0.0.0.0", .common = .{ .verbose = true }, .port = 8080 };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try emitTyped(&aw.writer, orig, a, .{});
    const back = try parseInto(C, a, aw.written(), .{});
    try std.testing.expectEqualStrings("0.0.0.0", back.listen_addr);
    try std.testing.expectEqual(true, back.common.verbose);
    try std.testing.expectEqual(@as(u16, 8080), back.port);
    try std.testing.expectEqual(@as(u32, 0), back.secret);
}

/// Recursive deep equality for the round-trip tests, tag-strict, floats by
/// BIT PATTERN so NaN==NaN and -0.0 != 0.0. Deliberately stricter than
/// `Value.eql` (which canonicalizes NaN and treats +0.0 == -0.0): a
/// parse -> emit -> parse round-trip must preserve the sign of zero, and the
/// canonicalizing comparison would mask an emitter fidelity regression.
fn valueEql(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => a.bool == b.bool,
        .int => a.int == b.int,
        .float => @as(u64, @bitCast(a.float)) == @as(u64, @bitCast(b.float)),
        .string => std.mem.eql(u8, a.string, b.string),
        .seq => {
            if (a.seq.len != b.seq.len) return false;
            for (a.seq, b.seq) |x, y| if (!valueEql(x, y)) return false;
            return true;
        },
        .map => {
            if (a.map.len != b.map.len) return false;
            for (a.map, b.map) |x, y| {
                if (!valueEql(x.key, y.key)) return false;
                if (!valueEql(x.value, y.value)) return false;
            }
            return true;
        },
    };
}

test "emit block mapping and sequence" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "name: app\nports:\n  - 80\n  - 443\n", .{});
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try emit(&aw.writer, v, .{});
    try std.testing.expectEqualStrings("name: app\nports:\n  - 80\n  - 443\n", aw.written());
}

test "emit quotes scalars that would otherwise mis-parse" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "a: \"true\"\nb: \"123\"\nc: \"with: colon\"\n", .{});
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try emit(&aw.writer, v, .{});
    const back = try parse(a, aw.written(), .{});
    try std.testing.expectEqualStrings("true", back.getT([]const u8, "a").?);
    try std.testing.expectEqualStrings("123", back.getT([]const u8, "b").?);
    try std.testing.expectEqualStrings("with: colon", back.getT([]const u8, "c").?);
}

test "round-trip arbitrary parsed value" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "m:\n  x: 1\n  y: [2, 3]\n  z: hello world\nn: 3.5\nflag: true\nempty: ~\n";
    const v = try parse(a, src, .{});
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try emit(&aw.writer, v, .{});
    const v2 = try parse(a, aw.written(), .{});
    try std.testing.expect(valueEql(v, v2));
}

test "emit stream separates documents" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const docs = try parseStream(a, "a: 1\n---\nb: 2\n", .{});
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try emitStream(&aw.writer, docs, .{});
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "---") != null);
    const back = try parseStream(a, aw.written(), .{});
    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expectEqual(@as(i64, 2), back[1].getT(i64, "b").?);
}

test "empty containers and nested" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "outer:\n  inner:\n    - 1\n  e: {}\n  s: []\n", .{});
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try emit(&aw.writer, v, .{});
    const v2 = try parse(a, aw.written(), .{});
    try std.testing.expect(valueEql(v, v2));
}

test "emit special floats round-trip" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const cases = [_]struct { f: f64, want: []const u8 }{
        .{ .f = std.math.inf(f64), .want = ".inf" },
        .{ .f = -std.math.inf(f64), .want = "-.inf" },
        .{ .f = std.math.nan(f64), .want = ".nan" },
        .{ .f = 1.0, .want = "1.0" },
        .{ .f = 3.5, .want = "3.5" },
    };
    for (cases) |c| {
        var aw: std.Io.Writer.Allocating = .init(a);
        defer aw.deinit();
        try emit(&aw.writer, .{ .float = c.f }, .{});
        try std.testing.expectEqualStrings(c.want, std.mem.trimEnd(u8, aw.written(), "\n"));
        const back = try parse(a, aw.written(), .{});
        try std.testing.expect(back == .float);
        if (std.math.isNan(c.f)) {
            try std.testing.expect(std.math.isNan(back.float));
        } else {
            try std.testing.expectEqual(c.f, back.float);
        }
    }
}

test "emit quotes empty string and whitespace-padded string" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const entries = try a.dupe(Entry, &.{
        .{ .key = .{ .string = "empty" }, .value = .{ .string = "" } },
        .{ .key = .{ .string = "pad" }, .value = .{ .string = " x " } },
        .{ .key = .{ .string = "lead" }, .value = .{ .string = "- dash" } },
    });
    const v: Value = .{ .map = entries };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try emit(&aw.writer, v, .{});
    const back = try parse(a, aw.written(), .{});
    try std.testing.expectEqualStrings("", back.getT([]const u8, "empty").?);
    try std.testing.expectEqualStrings(" x ", back.getT([]const u8, "pad").?);
    try std.testing.expectEqualStrings("- dash", back.getT([]const u8, "lead").?);
}

test "emit multiline string round-trips via double-quote" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const entries = try a.dupe(Entry, &.{
        .{ .key = .{ .string = "text" }, .value = .{ .string = "line1\nline2\ttab" } },
    });
    const v: Value = .{ .map = entries };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try emit(&aw.writer, v, .{});
    const back = try parse(a, aw.written(), .{});
    try std.testing.expectEqualStrings("line1\nline2\ttab", back.getT([]const u8, "text").?);
}

test "emit nesting depth guard" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    var inner: Value = .null;
    var depth: usize = 0;
    while (depth < 200) : (depth += 1) {
        const elems = try a.alloc(Value, 1);
        elems[0] = inner;
        inner = .{ .seq = elems };
    }
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try std.testing.expectError(error.NestingTooDeep, emit(&aw.writer, inner, .{}));

    var shallow: Value = .null;
    depth = 0;
    while (depth < 100) : (depth += 1) {
        const elems = try a.alloc(Value, 1);
        elems[0] = shallow;
        shallow = .{ .seq = elems };
    }
    var ok: std.Io.Writer.Allocating = .init(a);
    defer ok.deinit();
    try emit(&ok.writer, shallow, .{});
}

test "emit nesting depth guard on flow complex-key path" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    // A non-scalar map key forces the whole tree through emitFlow, whose
    // recursion must honour the same depth bound as the block path.
    var key: Value = .null;
    var depth: usize = 0;
    while (depth < 200) : (depth += 1) {
        const elems = try a.alloc(Value, 1);
        elems[0] = key;
        key = .{ .seq = elems };
    }
    const deep_entries = try a.dupe(Entry, &.{.{ .key = key, .value = .{ .string = "v" } }});
    const deep: Value = .{ .map = deep_entries };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try std.testing.expectError(error.NestingTooDeep, emit(&aw.writer, deep, .{}));

    var shallow_key: Value = .null;
    depth = 0;
    while (depth < 100) : (depth += 1) {
        const elems = try a.alloc(Value, 1);
        elems[0] = shallow_key;
        shallow_key = .{ .seq = elems };
    }
    const ok_entries = try a.dupe(Entry, &.{.{ .key = shallow_key, .value = .{ .string = "v" } }});
    const ok_v: Value = .{ .map = ok_entries };
    var ok: std.Io.Writer.Allocating = .init(a);
    defer ok.deinit();
    try emit(&ok.writer, ok_v, .{});
}

test "emit non-scalar key in flow round-trips" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const keyseq = try a.dupe(Value, &.{ .{ .int = 1 }, .{ .int = 2 } });
    const entries = try a.dupe(Entry, &.{.{ .key = .{ .seq = keyseq }, .value = .{ .string = "x" } }});
    const v: Value = .{ .map = entries };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try emit(&aw.writer, v, .{});
    const v2 = try parse(a, aw.written(), .{});
    try std.testing.expect(valueEql(v, v2));
}

test "emit root scalar" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try emit(&aw.writer, .{ .int = 42 }, .{});
    try std.testing.expectEqualStrings("42\n", aw.written());
}

test "document-marker strings round-trip safely" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const cases = [_][]const u8{ "---", "...", "--- x", "... y" };
    for (cases) |s| {
        // As a root scalar: emit then re-parse, value must survive intact.
        const root: Value = .{ .string = s };
        var aw: std.Io.Writer.Allocating = .init(a);
        defer aw.deinit();
        try emit(&aw.writer, root, .{});
        const back = try parse(a, aw.written(), .{});
        try std.testing.expect(back == .string and std.mem.eql(u8, back.string, s));

        // As a column-0 mapping key: { s: 1 } -- the key must survive.
        // Use direct entry scan instead of Value.get() because get() splits
        // on '.' (path syntax), which collides with "..." and "... y".
        const entries = try a.dupe(Entry, &.{.{ .key = .{ .string = s }, .value = .{ .int = 1 } }});
        const m: Value = .{ .map = entries };
        var aw2: std.Io.Writer.Allocating = .init(a);
        defer aw2.deinit();
        try emit(&aw2.writer, m, .{});
        const back2 = try parse(a, aw2.written(), .{});
        try std.testing.expect(back2 == .map);
        const found: ?i128 = blk: {
            for (back2.map) |e| {
                if (e.key == .string and std.mem.eql(u8, e.key.string, s))
                    break :blk if (e.value == .int) e.value.int else null;
            }
            break :blk null;
        };
        try std.testing.expectEqual(@as(i128, 1), found.?);
    }
}

test "emitTyped round-trips struct with u64 field at max value" {
    // Value.int must be wide enough to hold every u64 value so emitTyped
    // can coerce u64 fields without loss.
    const S = struct { id: u64 };
    const max_u64 = std.math.maxInt(u64);
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const s: S = .{ .id = max_u64 };
    try emitTyped(&aw.writer, s, a, .{});
    const back = try parseInto(S, a, aw.written(), .{});
    try std.testing.expectEqual(max_u64, back.id);
}

test "parse and getT recover u64 values above i64 max" {
    // Values in the range (i64_max, u64_max] must parse as .int and be
    // retrievable via getT(u64, ...) without overflow.
    const above_i64_max = @as(u64, std.math.maxInt(i64)) + 1;
    const max_u64 = std.math.maxInt(u64);
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const src_above = try std.fmt.allocPrint(a, "v: {d}\n", .{above_i64_max});
    const v_above = try parse(a, src_above, .{});
    try std.testing.expectEqual(above_i64_max, v_above.getT(u64, "v").?);

    const src_max = try std.fmt.allocPrint(a, "v: {d}\n", .{max_u64});
    const v_max = try parse(a, src_max, .{});
    try std.testing.expectEqual(max_u64, v_max.getT(u64, "v").?);
}

test "small int and i64 min round-trip through the i128 Value.int" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const v_small = try parse(a, "n: 42\n", .{});
    try std.testing.expectEqual(@as(i64, 42), v_small.getT(i64, "n").?);

    const i64_min = std.math.minInt(i64);
    const src_min = try std.fmt.allocPrint(a, "n: {d}\n", .{i64_min});
    const v_min = try parse(a, src_min, .{});
    try std.testing.expectEqual(i64_min, v_min.getT(i64, "n").?);
}

test "literal << string key is quoted on emit" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // A Value with a literal "<<" key must emit quoted so reparse sees it as
    // a string key, not a merge trigger.
    const entries = try a.dupe(Entry, &.{
        .{ .key = .{ .string = "<<" }, .value = .{ .string = "hello" } },
        .{ .key = .{ .string = "x" }, .value = .{ .int = 1 } },
    });
    const v: Value = .{ .map = entries };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try emit(&aw.writer, v, .{});
    // The emitted YAML must not contain a bare `<<:` (which would be parsed
    // as a merge key on reparse).
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"<<\"") != null or
        std.mem.indexOf(u8, aw.written(), "'<<'") != null);
    // Round-trip: re-parse must recover the literal "<<" key.
    const back = try parse(a, aw.written(), .{});
    try std.testing.expect(back == .map);
    var found_key = false;
    for (back.map) |e| {
        if (e.key == .string and std.mem.eql(u8, e.key.string, "<<")) found_key = true;
    }
    try std.testing.expect(found_key);
    try std.testing.expectEqual(@as(i64, 1), back.getT(i64, "x").?);
}

test "emitTyped: u128 field with small value round-trips" {
    const S = struct { v: u128 };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const s: S = .{ .v = 42 };
    try emitTyped(&aw.writer, s, a, .{});
    const back = try parseInto(S, a, aw.written(), .{});
    try std.testing.expectEqual(@as(u128, 42), back.v);
}

test "emitTyped: u128 field exceeding i128 max returns UnrepresentableInt" {
    const S = struct { v: u128 };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const too_large: u128 = @as(u128, std.math.maxInt(i128)) + 1;
    const s: S = .{ .v = too_large };
    try std.testing.expectError(error.UnrepresentableInt, emitTyped(&aw.writer, s, a, .{}));
}

test "literal << key round-trip preserves value" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // Full round-trip: build a Value, emit it, re-parse, confirm << key survives.
    const inner_entries = try a.dupe(Entry, &.{.{ .key = .{ .string = "y" }, .value = .{ .int = 42 } }});
    const entries = try a.dupe(Entry, &.{
        .{ .key = .{ .string = "<<" }, .value = .{ .map = inner_entries } },
        .{ .key = .{ .string = "z" }, .value = .{ .int = 2 } },
    });
    const v: Value = .{ .map = entries };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try emit(&aw.writer, v, .{});
    const back = try parse(a, aw.written(), .{});
    try std.testing.expect(back == .map);
    // "<<" key preserved, "z" also present (no merge applied)
    try std.testing.expectEqual(@as(i64, 2), back.getT(i64, "z").?);
    var found_merge_lit = false;
    for (back.map) |e| {
        if (e.key == .string and std.mem.eql(u8, e.key.string, "<<")) found_merge_lit = true;
    }
    try std.testing.expect(found_merge_lit);
}
