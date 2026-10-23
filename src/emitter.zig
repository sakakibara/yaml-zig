//! Block-style YAML emitter.
//!
//! Walks a `Value` tree and writes YAML 1.2 block-style text to a
//! `std.Io.Writer`. Mappings and sequences emit one entry/element per
//! line, indented `options.indent` spaces per nesting level. Empty
//! collections emit flow-empty `{}`/`[]` (block-empty is ambiguous).
//!
//! Scalar styling picks the narrowest round-trip-safe form: a string
//! emits PLAIN when the core schema, the YAML 1.1 types, and the YAML 1.1
//! readers in common use all read it back as that string and it carries no
//! syntactic indicator, otherwise double-quoted with escapes. The quoting
//! predicate is deliberately conservative -- when in doubt it quotes, since
//! a mis-parse silently corrupts the tree. A key that would be longer than
//! the 1024 characters YAML allows an implicit key is written as an
//! explicit `? key` entry.
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

/// `indent` sets the per-level indent width for block-style output.
///
/// `sort_keys` (default `false`) emits mapping entries -- and, via
/// `emitTyped`, struct fields -- in ascending byte-lexicographic key
/// order, recursively into nested mappings, instead of insertion /
/// declaration order. Only mappings whose keys are ALL scalar strings are
/// reordered; a mapping containing any non-string key (including a
/// seq/map key) is left in insertion order, since a non-string key has no
/// defined byte-lexicographic position. This is plain byte ordering, not
/// a YAML or JSON canonicalization scheme. Default output is
/// byte-for-byte unchanged unless the flag is set.
pub const EmitOptions = struct {
    indent: usize = 2,
    sort_keys: bool = false,
};

/// Writer failures, plus `NestingTooDeep` when a hand-built `Value` tree
/// exceeds `max_emit_depth` levels of collection nesting.
/// `UnrepresentableScalar` is reserved for scalars that cannot be
/// emitted; the current core-style emitter represents every `Value`, so
/// it does not fire in practice. `UnrepresentableInt` fires when an
/// integer value exceeds the i128 data model limit (e.g. a u128 field
/// whose value exceeds maxInt(i128)). `OutOfMemory` arises only on the
/// `emitTyped` path, which builds a `Value` tree (and any `toYaml` hook
/// values) in the caller's arena. `InvalidUtf8` fires for a string that is
/// not valid UTF-8: a YAML stream is Unicode text, so no spelling of it
/// reads back as those bytes.
pub const EmitError = Io.Writer.Error || error{ UnrepresentableScalar, UnrepresentableInt, NestingTooDeep, OutOfMemory, InvalidUtf8 };

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
    const built = try reflectValue(value, arena);
    try emit(w, built, options);
}

/// Reflect `value` into a `Value` the way `emitTyped` does, without writing it.
/// The KYAML emitter uses this so typed output shares one conversion.
pub fn reflectValue(value: anytype, arena: std.mem.Allocator) (std.mem.Allocator.Error || error{UnrepresentableInt})!Value {
    return buildValue(@TypeOf(value), value, arena);
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
            if (fn_info.param_types.len != 2) {
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
            if (p.child == u8 and p.attrs.@"const") break :blk .{ .string = value };
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
    inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |name, Field| {
        if (comptime decode_mod.isSkipped(T, name)) continue;
        const fv = @field(value, name);
        if (comptime decode_mod.isFlattened(T, name)) {
            comptime decode_mod.validateAnnotations(Field);
            try buildStructFields(Field, fv, arena, entries);
        } else if (comptime @typeInfo(Field) == .optional) {
            // Null optionals are omitted; decode maps the absent key back
            // to null, so the round-trip is lossless.
            if (fv) |inner| {
                const key = comptime decode_mod.renamedKey(T, name);
                const v = try buildValue(@typeInfo(Field).optional.child, inner, arena);
                try entries.append(arena, .{ .key = .{ .string = key }, .value = v });
            }
        } else {
            const key = comptime decode_mod.renamedKey(T, name);
            const v = try buildValue(Field, fv, arena);
            try entries.append(arena, .{ .key = .{ .string = key }, .value = v });
        }
    }
}

fn buildTaggedUnion(comptime T: type, value: T, arena: std.mem.Allocator) (std.mem.Allocator.Error || error{UnrepresentableInt})!Value {
    comptime decode_mod.validateAnnotations(T);
    const active = std.meta.activeTag(value);
    var entries: std.ArrayList(Entry) = .empty;
    inline for (@typeInfo(T).@"union".field_names, @typeInfo(T).@"union".field_types) |name, Field| {
        if (active == @field(std.meta.Tag(T), name)) {
            try entries.append(arena, .{
                .key = .{ .string = T.yaml_tag },
                .value = .{ .string = comptime decode_mod.renamedKey(T, name) },
            });
            if (Field != void) {
                try buildStructFields(Field, @field(value, name), arena, &entries);
            }
        }
    }
    return .{ .map = entries.items };
}

/// Write a null, bool, int, or float the way `emit` writes it.
/// Strings and collections return `UnrepresentableScalar`.
pub fn writeDataScalar(w: *Io.Writer, value: Value) EmitError!void {
    switch (value) {
        .null, .bool, .int, .float => try emitScalar(w, value),
        else => return error.UnrepresentableScalar,
    }
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

/// `renderScalar` for a scalar inside a flow collection: a string is always
/// double-quoted, as `emit` writes flow content, since flow context ends a
/// plain scalar at `,`, `[`, `]`, `{` and `}`.
pub fn renderFlowScalar(w: *Io.Writer, value: Value) EmitError!void {
    switch (value) {
        .seq, .map => return error.UnrepresentableScalar,
        .string => |s| try emitDoubleQuoted(w, s),
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
                try emitFlow(w, value, options, 0);
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
    if (options.sort_keys and allStringKeys(entries)) {
        var prev: ?SortCursor = null;
        for (0..entries.len) |_| {
            const idx = nextSortedIndex(entries, prev);
            try emitKey(w, entries[idx].key, options, depth);
            try emitValueAfterMarker(w, entries[idx].value, options, depth);
            prev = .{ .key = entries[idx].key.string, .idx = idx };
        }
        return;
    }
    for (entries) |e| {
        try emitKey(w, e.key, options, depth);
        try emitValueAfterMarker(w, e.value, options, depth);
    }
}

/// True when every entry's key is a scalar string. `sort_keys` only
/// reorders such mappings: a non-string key (including a seq/map key,
/// which already forces flow style via `mapHasComplexKey`) has no defined
/// byte-lexicographic position, so a mapping containing one keeps
/// insertion order and never crashes.
fn allStringKeys(entries: []const Entry) bool {
    for (entries) |e| {
        if (e.key != .string) return false;
    }
    return true;
}

/// One entry selected by `nextSortedIndex`, remembered so the next call
/// can resume the scan past it.
const SortCursor = struct { key: []const u8, idx: usize };

/// True when `(a_key, a_idx)` sorts strictly before `(b_key, b_idx)`:
/// byte-lexicographic on the key, original position breaking ties so
/// entries sharing a duplicate key keep their relative order.
fn keyIdxLess(a_key: []const u8, a_idx: usize, b_key: []const u8, b_idx: usize) bool {
    if (!std.mem.eql(u8, a_key, b_key)) return std.mem.lessThan(u8, a_key, b_key);
    return a_idx < b_idx;
}

/// Index of the next entry in ascending sorted order after `prev` (or the
/// first entry, when `prev` is null). Every `entries` key must be
/// `.string` (checked by the caller via `allStringKeys`). A selection
/// search over `entries` avoids allocating a sorted copy; O(n^2) across a
/// full pass, which fits `sort_keys`'s human-scale document target.
fn nextSortedIndex(entries: []const Entry, prev: ?SortCursor) usize {
    var best: usize = 0;
    var found = false;
    for (entries, 0..) |e, j| {
        if (prev) |p| if (!keyIdxLess(p.key, p.idx, e.key.string, j)) continue;
        if (!found or keyIdxLess(e.key.string, j, entries[best].key.string, best)) {
            best = j;
            found = true;
        }
    }
    return best;
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
                    try emitFlow(w, v, options, depth + 1);
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
/// The indented key of a block mapping entry and its `:`: an implicit key,
/// or an explicit `? key` line when the key is past the implicit limit.
fn emitKey(w: *Io.Writer, key: Value, options: EmitOptions, depth: usize) EmitError!void {
    try writeIndent(w, options, depth);
    if (try fitsImplicitKey(key)) {
        try emitScalar(w, key);
    } else {
        try w.writeAll("? ");
        try emitScalar(w, key);
        try w.writeByte('\n');
        try writeIndent(w, options, depth);
    }
    try w.writeByte(':');
}

/// YAML limits an implicit key to 1024 Unicode characters as written.
pub const max_implicit_key_chars = 1024;

/// Whether `key`, written as `emitScalar` writes it, is short enough to be
/// an implicit key.
fn fitsImplicitKey(key: Value) EmitError!bool {
    var counter: CharCounter = .{};
    try emitScalar(&counter.writer, key);
    return counter.chars <= max_implicit_key_chars;
}

/// A writer that only counts the Unicode characters written to it.
const CharCounter = struct {
    writer: Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
    chars: usize = 0,

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const c: *CharCounter = @alignCast(@fieldParentPtr("writer", w));
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            c.chars += leadBytes(d);
            n += d.len;
        }
        const last = data[data.len - 1];
        c.chars += leadBytes(last) * splat;
        return n + last.len * splat;
    }

    fn leadBytes(d: []const u8) usize {
        var k: usize = 0;
        for (d) |b| {
            if (b & 0xC0 != 0x80) k += 1;
        }
        return k;
    }
};

/// Compact flow representation, used for mappings with a non-scalar key
/// (and their nested values). Strings always double-quote here: flow
/// context gives plain scalars stricter terminators (`,`, `[`, `]`, `{`,
/// `}`, `:`), so quoting unconditionally is the conservative round-trip-
/// safe choice. `options.sort_keys` applies the same string-key-only
/// ordering rule as block style, recursively into nested maps.
fn emitFlow(w: *Io.Writer, v: Value, options: EmitOptions, depth: usize) EmitError!void {
    if (depth > max_emit_depth) return error.NestingTooDeep;
    switch (v) {
        .seq => |s| {
            try w.writeByte('[');
            for (s, 0..) |elem, i| {
                if (i > 0) try w.writeAll(", ");
                try emitFlow(w, elem, options, depth + 1);
            }
            try w.writeByte(']');
        },
        .map => |m| {
            try w.writeByte('{');
            if (options.sort_keys and allStringKeys(m)) {
                var prev: ?SortCursor = null;
                for (0..m.len) |i| {
                    const idx = nextSortedIndex(m, prev);
                    if (i > 0) try w.writeAll(", ");
                    try emitFlowKey(w, m[idx].key, options, depth + 1);
                    try w.writeAll(": ");
                    try emitFlow(w, m[idx].value, options, depth + 1);
                    prev = .{ .key = m[idx].key.string, .idx = idx };
                }
            } else {
                for (m, 0..) |e, i| {
                    if (i > 0) try w.writeAll(", ");
                    try emitFlowKey(w, e.key, options, depth + 1);
                    try w.writeAll(": ");
                    try emitFlow(w, e.value, options, depth + 1);
                }
            }
            try w.writeByte('}');
        },
        .string => |s| try emitDoubleQuoted(w, s),
        else => try emitScalar(w, v),
    }
}

/// A flow mapping key, with the explicit `? ` indicator where it needs one:
/// a collection key (without it `[k]: v` reads as two entries), and a key
/// that, as written, is past the implicit-key length limit.
fn emitFlowKey(w: *Io.Writer, key: Value, options: EmitOptions, depth: usize) EmitError!void {
    const explicit = switch (key) {
        .seq, .map => true,
        else => blk: {
            var counter: CharCounter = .{};
            try emitFlow(&counter.writer, key, options, depth);
            break :blk counter.chars > max_implicit_key_chars;
        },
    };
    if (explicit) try w.writeAll("? ");
    try emitFlow(w, key, options, depth);
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
/// on integer-valued output so it re-parses as `.float`, not `.int`, and in
/// scientific form a dot and a signed exponent (`1.0e+21`).
fn emitFloat(w: *Io.Writer, f: f64) EmitError!void {
    if (std.math.isNan(f)) return w.writeAll(".nan");
    if (std.math.isInf(f)) return w.writeAll(if (f < 0) "-.inf" else ".inf");

    const a = @abs(f);
    if (a != 0 and (a < 1e-6 or a >= 1e21)) {
        var buf: [std.fmt.float.bufferSize(.scientific, f64)]u8 = undefined;
        const s = std.fmt.float.render(&buf, f, .{ .mode = .scientific }) catch unreachable;
        // The YAML 1.1 float grammar needs a dot in the mantissa and a sign
        // on the exponent; with both, every reader takes it as a float.
        const e = std.mem.indexOfScalar(u8, s, 'e').?;
        try w.writeAll(s[0..e]);
        if (std.mem.indexOfScalar(u8, s[0..e], '.') == null) try w.writeAll(".0");
        try w.writeByte('e');
        if (s[e + 1] != '-') try w.writeByte('+');
        return w.writeAll(s[e + 1 ..]);
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

/// Where a plain scalar sits, for `isPlainSafe`.
pub const PlainContext = struct {
    /// Inside a flow collection (`[...]`, `{...}`), where more characters
    /// end a scalar.
    flow: bool = false,
    /// An implicit key (one without `?`), which YAML limits to
    /// `max_implicit_key_chars` characters.
    key: bool = false,
};

/// True when `s` written as a plain scalar where `context` says reads back
/// as this string under the core schema, the YAML 1.1 types, and the YAML
/// 1.1 readers in common use; false for bytes that are not UTF-8. For a
/// block value (`.{}`), `emit` writes a string plain exactly when this
/// holds. A release that does not break may only make it return false for
/// more strings.
pub fn isPlainSafe(s: []const u8, context: PlainContext) bool {
    if (!std.unicode.utf8ValidateSlice(s) or !plainIsSafe(s)) return false;
    // A flow indicator ends the scalar; `?` opens a key there (anywhere, to
    // PyYAML); a `:` can end it before a flow indicator, and older readers
    // refuse one inside it.
    if (context.flow and std.mem.indexOfAny(u8, s, ",[]{}?:") != null) return false;
    if (context.key and (std.unicode.utf8CountCodepoints(s) catch return false) > max_implicit_key_chars) return false;
    return true;
}

fn emitString(w: *Io.Writer, s: []const u8) EmitError!void {
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
    if (plainIsSafe(s)) {
        try w.writeAll(s);
    } else {
        try emitDoubleQuoted(w, s);
    }
}

/// Whether a YAML 1.1 reader in common use widens the 1.1 grammars to read
/// `s` as something other than a string. Each widens them differently, so
/// this covers them by shape rather than one grammar each:
///
/// - a number past what the 1.1 types allow: `_` in a fraction (PyYAML), an
///   unsigned exponent (SnakeYAML, go-yaml v2, js-yaml), `_` anywhere and
///   uppercase base prefixes such as `0X1F` (go-yaml v2, which drops every
///   `_` and parses with Go's prefix rules, so `-_1` is a number), `,` digit
///   groups (Psych), and `._5` (js-yaml) -- covered by quoting anything that,
///   after an optional sign, starts with a digit, or with `.` or (signed)
///   `_` followed by a digit or `_`;
/// - booleans, nulls, `.inf` and `.nan` in any letter case (Psych);
/// - a `:name` symbol (Psych).
fn readerWidening(s: []const u8) bool {
    if (s[0] == ':') return true;
    const signed = s[0] == '+' or s[0] == '-';
    const b = if (signed) s[1..] else s;
    if (b.len == 0) return false;
    if (std.ascii.isDigit(b[0])) return true;
    if ((b[0] == '.' or (signed and b[0] == '_')) and b.len > 1 and (std.ascii.isDigit(b[1]) or b[1] == '_')) return true;
    if (signed and b[0] == '_') return true;
    for ([_][]const u8{ ".inf", ".nan" }) |w| if (std.ascii.eqlIgnoreCase(b, w)) return true;
    if (signed) return false;
    for ([_][]const u8{ "yes", "no", "on", "off", "true", "false", "null", "y", "n" }) |w| if (std.ascii.eqlIgnoreCase(s, w)) return true;
    return false;
}

/// YAML's printable characters (`c-printable`), less tab and line breaks,
/// which the caller handles.
fn printable(cp: u21) bool {
    return (cp >= 0x20 and cp <= 0x7E) or cp == 0x85 or (cp >= 0xA0 and cp <= 0xD7FF) or
        (cp >= 0xE000 and cp <= 0xFFFD) or cp >= 0x10000;
}

/// Decide whether the valid UTF-8 `s` survives emission as a PLAIN scalar:
/// it must re-parse as that string under the core schema, under the YAML 1.1
/// types, and under the YAML 1.1 readers in common use, AND carry no
/// syntactic construct that block context would read as structure.
/// Conservative by design -- a false "safe" silently corrupts the
/// round-trip, a false "unsafe" only adds quotes.
fn plainIsSafe(s: []const u8) bool {
    if (s.len == 0) return false; // empty plain resolves to null

    // Would a core or a YAML 1.1 reader give this text another type? Many
    // programs that read config files still use YAML 1.1, where `yes`,
    // `0123`, `1:20`, a timestamp and `<<` are not strings. The schema
    // module owns the exact grammars.
    if (schema.tagOf(.core, s) != .str or schema.tagOf(.yaml11, s) != .str) return false;
    if (readerWidening(s)) return false;

    // Leading/trailing whitespace is stripped or folded by the parser.
    if (s[0] == ' ' or s[0] == '\t') return false;
    if (s[s.len - 1] == ' ' or s[s.len - 1] == '\t') return false;

    // Only characters YAML lets a plain scalar hold as they are: no control
    // characters or line breaks (U+0085, U+2028 and U+2029 among them, line
    // breaks to a YAML 1.1 reader), no non-characters, and no U+FEFF, which a
    // reader strips as a byte order mark at the start of a stream.
    var it: std.unicode.Utf8Iterator = .{ .bytes = s, .i = 0 };
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x20 or cp == 0x7f or !printable(cp) or cp == 0x85 or cp == 0x2028 or cp == 0x2029 or cp == 0xFEFF) return false;
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

    // Document markers `---` / `...` at column 0 are parsed as
    // document-start/end directives, not scalars, when bare or followed by
    // a space -- and by js-yaml 3 whatever follows them. Because plainIsSafe
    // has no positional context, quote any string that starts with one.
    if (std.mem.startsWith(u8, s, "---") or std.mem.startsWith(u8, s, "...")) return false;

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

/// `s` double-quoted, or `error.InvalidUtf8` when it is not UTF-8: every character YAML does not let a
/// double-quoted scalar hold as it is, and each line break of a YAML 1.1
/// reader, escaped; U+FEFF too, which a reader would strip as a byte order
/// mark at the start of a stream.
fn emitDoubleQuoted(w: *Io.Writer, s: []const u8) EmitError!void {
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
    try w.writeByte('"');
    var it: std.unicode.Utf8Iterator = .{ .bytes = s, .i = 0 };
    while (it.nextCodepointSlice()) |bytes| {
        const cp = std.unicode.utf8Decode(bytes) catch unreachable;
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
            else => if (cp == 0xFEFF or !printable(cp)) {
                if (cp <= 0xFF) try w.print("\\x{X:0>2}", .{cp}) else try w.print("\\u{X:0>4}", .{cp});
            } else {
                try w.writeAll(bytes);
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

test "emit quotes a string a core or YAML 1.1 reader would read as another type" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const quoted = [_][]const u8{ "yes", "No", "on", "OFF", "y", "n", "=", "<<", "0123", "0b101", "1_000", "1:20", "190:20:30.15", "1.2.3", "2026-10-18", "2001-12-14t21:59:43.10-05:00", "-.Inf", "1e3", "08", "a\u{2028}b", "x\u{85}", "1:60" };
    const plain = [_][]const u8{ "hello", "en_US.UTF-8", "Asia/Tokyo", "v1.2.3", "cafe", "yesterday", "_1", "-foo", "a:b", ".gitignore", "+x" };
    for (quoted) |q| {
        var aw: std.Io.Writer.Allocating = .init(a);
        try emit(&aw.writer, .{ .string = q }, .{});
        std.testing.expect(aw.written()[0] == '"') catch |e| {
            std.debug.print("not quoted: {s}\n", .{q});
            return e;
        };
        try std.testing.expectEqualStrings(q, (try parse(a, aw.written(), .{})).string);
    }
    for (plain) |p| {
        var aw: std.Io.Writer.Allocating = .init(a);
        try emit(&aw.writer, .{ .string = p }, .{});
        try std.testing.expectEqualStrings(p, std.mem.trimEnd(u8, aw.written(), "\n"));
    }
}

test "emit quotes a string a YAML 1.1 reader in common use widens its grammar to read as another type" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // PyYAML: `_` in a fraction; SnakeYAML, go-yaml v2, js-yaml: unsigned
    // exponents; go-yaml v2: uppercase prefixes and `_` after a sign; Psych:
    // `,` groups, case-folded words and specials, `:symbols`; js-yaml: `._5`.
    const quoted = [_][]const u8{ "1.0_0", "685.230_15e+03", "1_000e5", "0X1F", "0B101", "0O17", "-_1", "1,000", "1,000.5", "._5", "yES", "On", "NULL", "tRUE", ".InF", "+.INF", ".NaN", ":sym" };
    for (quoted) |q| {
        var aw: std.Io.Writer.Allocating = .init(a);
        try emit(&aw.writer, .{ .string = q }, .{});
        std.testing.expect(aw.written()[0] == '"') catch |e| {
            std.debug.print("not quoted: {s}\n", .{q});
            return e;
        };
        try std.testing.expectEqualStrings(q, (try parse(a, aw.written(), .{})).string);
    }
}

test "emit escapes the characters YAML does not let a scalar hold as they are, and refuses bytes that are not UTF-8" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "a\u{80}b", .out = "\"a\\x80b\"\n" },
        .{ .in = "\u{9f}", .out = "\"\\x9F\"\n" },
        .{ .in = "x\u{FFFE}", .out = "\"x\\uFFFE\"\n" },
        .{ .in = "\u{FEFF}a", .out = "\"\\uFEFFa\"\n" },
        .{ .in = "caf\u{e9} \u{1F600}", .out = "caf\u{e9} \u{1F600}\n" },
    };
    for (cases) |c| {
        var aw: std.Io.Writer.Allocating = .init(a);
        try emit(&aw.writer, .{ .string = c.in }, .{});
        try std.testing.expectEqualStrings(c.out, aw.written());
        try std.testing.expectEqualStrings(c.in, (try parse(a, aw.written(), .{})).string);
    }
    var aw: std.Io.Writer.Allocating = .init(a);
    try std.testing.expectError(error.InvalidUtf8, emit(&aw.writer, .{ .string = "a\xffb" }, .{}));
}

test "emit writes a key past the implicit key limit as an explicit key" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const long = &@as([1100]u8, @splat('k'));
    const entries = try a.dupe(Entry, &.{
        .{ .key = .{ .string = long }, .value = .{ .int = 1 } },
        .{ .key = .{ .string = "short" }, .value = .{ .int = 2 } },
    });
    var aw: std.Io.Writer.Allocating = .init(a);
    try emit(&aw.writer, .{ .map = entries }, .{});
    try std.testing.expectEqualStrings("? " ++ long ++ "\n: 1\nshort: 2\n", aw.written());
    const back = try parse(a, aw.written(), .{});
    try std.testing.expectEqual(@as(i64, 1), back.getT(i64, long).?);
    var fits: std.Io.Writer.Allocating = .init(a);
    try emit(&fits.writer, .{ .map = try a.dupe(Entry, &.{.{ .key = .{ .string = &@as([1024]u8, @splat('k')) }, .value = .{ .int = 1 } }}) }, .{});
    try std.testing.expect(fits.written()[0] == 'k');
}

test "flow style refuses bytes that are not UTF-8, and writes a long or escaped key as an explicit key" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const seq_key: Value = .{ .seq = try a.dupe(Value, &.{.{ .string = "x" }}) };
    for ([_][]const u8{ "a\xff", "a\xc3" }) |bad| {
        var aw: std.Io.Writer.Allocating = .init(a);
        const m: Value = .{ .map = try a.dupe(Entry, &.{.{ .key = seq_key, .value = .{ .string = bad } }}) };
        try std.testing.expectError(error.InvalidUtf8, emit(&aw.writer, m, .{}));
    }
    // 600 quotes are 1200 characters once escaped.
    const quotes = &@as([600]u8, @splat('"'));
    const long = &@as([2000]u8, @splat('k'));
    for ([_]bool{ false, true }) |sorted| {
        const inner: Value = .{ .map = try a.dupe(Entry, &.{.{ .key = .{ .string = long }, .value = .{ .int = 1 } }}) };
        const m: Value = .{ .map = try a.dupe(Entry, &.{
            .{ .key = seq_key, .value = inner },
            .{ .key = .{ .string = quotes }, .value = .{ .int = 2 } },
        }) };
        var aw: std.Io.Writer.Allocating = .init(a);
        try emit(&aw.writer, m, .{ .sort_keys = sorted });
        try std.testing.expect(std.mem.indexOf(u8, aw.written(), "? \"" ++ &@as([10]u8, @splat('k'))) != null);
        try std.testing.expect(std.mem.indexOf(u8, aw.written(), "? \"\\\"\\\"") != null);
        const back = try parse(a, aw.written(), .{});
        try std.testing.expectEqual(@as(usize, 2), back.map.len);
    }
}

test "emit quotes a string that starts like a document marker" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    for ([_][]const u8{ "---x", "---", "----", "--->", "...a", "..." }) |q| {
        var aw: std.Io.Writer.Allocating = .init(a);
        try emit(&aw.writer, .{ .string = q }, .{});
        try std.testing.expect(aw.written()[0] == '"');
        try std.testing.expectEqualStrings(q, (try parse(a, aw.written(), .{})).string);
    }
}

test "emit writes a float in scientific form that the core and YAML 1.1 schemas both read as that float" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const cases = [_]struct { f: f64, out: []const u8 }{
        .{ .f = 1e21, .out = "1.0e+21" },
        .{ .f = -1.5e300, .out = "-1.5e+300" },
        .{ .f = 1e-7, .out = "1.0e-7" },
        .{ .f = 2.5e-10, .out = "2.5e-10" },
    };
    for (cases) |c| {
        var aw: std.Io.Writer.Allocating = .init(a);
        try emit(&aw.writer, .{ .float = c.f }, .{});
        try std.testing.expectEqualStrings(c.out, std.mem.trimEnd(u8, aw.written(), "\n"));
        for ([_]schema.Schema{ .core, .yaml11 }) |sch| {
            const back = try parse(a, aw.written(), .{ .schema = sch });
            try std.testing.expectEqual(c.f, back.float);
        }
    }
}

test "emit escapes YAML 1.1 line breaks in a double-quoted string" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    try emit(&aw.writer, .{ .string = "a\u{85}b\u{2028}c\u{2029}d\"" }, .{});
    try std.testing.expectEqualStrings("\"a\\Nb\\Lc\\Pd\\\"\"\n", aw.written());
    try std.testing.expectEqualStrings("a\u{85}b\u{2028}c\u{2029}d\"", (try parse(a, aw.written(), .{})).string);
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

// sort_keys

test "sort_keys: mapping emitted in sorted order, default keeps insertion" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const entries = try a.dupe(Entry, &.{
        .{ .key = .{ .string = "z" }, .value = .{ .int = 1 } },
        .{ .key = .{ .string = "a" }, .value = .{ .int = 2 } },
        .{ .key = .{ .string = "m" }, .value = .{ .int = 3 } },
    });
    const v: Value = .{ .map = entries };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try emit(&aw.writer, v, .{ .sort_keys = true });
    try std.testing.expectEqualStrings("a: 2\nm: 3\nz: 1\n", aw.written());

    aw.clearRetainingCapacity();
    try emit(&aw.writer, v, .{});
    try std.testing.expectEqualStrings("z: 1\na: 2\nm: 3\n", aw.written());
}

test "sort_keys: recurses into nested mappings" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "b:\n  y: 1\n  x: 2\na: 3\n", .{});
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try emit(&aw.writer, v, .{ .sort_keys = true });
    try std.testing.expectEqualStrings("a: 3\nb:\n  x: 2\n  \"y\": 1\n", aw.written());
}

test "sort_keys: byte-lexicographic order (uppercase sorts before lowercase)" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try parse(a, "b: 1\nA: 2\na: 3\nB: 4\n", .{});
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try emit(&aw.writer, v, .{ .sort_keys = true });
    // ASCII bytes: 'A'(65) 'B'(66) 'a'(97) 'b'(98). Not JCS/UTF-16 order.
    try std.testing.expectEqualStrings("A: 2\nB: 4\na: 3\nb: 1\n", aw.written());
}

test "sort_keys: empty mapping stays {}" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try emit(&aw.writer, .{ .map = &.{} }, .{ .sort_keys = true });
    try std.testing.expectEqualStrings("{}\n", aw.written());
}

test "sort_keys: mapping with a non-string key keeps insertion order" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // Boundary case: sorting a non-string (even scalar, e.g. int) key has
    // no defined byte-lexicographic position, so the mapping is left as-is
    // rather than sorted or crashed on.
    const entries = try a.dupe(Entry, &.{
        .{ .key = .{ .int = 2 }, .value = .{ .string = "b" } },
        .{ .key = .{ .int = 1 }, .value = .{ .string = "a" } },
    });
    const v: Value = .{ .map = entries };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try emit(&aw.writer, v, .{ .sort_keys = true });
    try std.testing.expectEqualStrings("2: b\n1: a\n", aw.written());
}

test "sort_keys: duplicate keys preserve relative order (stable)" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const entries = try a.dupe(Entry, &.{
        .{ .key = .{ .string = "a" }, .value = .{ .int = 1 } },
        .{ .key = .{ .string = "a" }, .value = .{ .int = 2 } },
    });
    const v: Value = .{ .map = entries };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try emit(&aw.writer, v, .{ .sort_keys = true });
    try std.testing.expectEqualStrings("a: 1\na: 2\n", aw.written());
}

test "sort_keys: nested mapping under a complex flow key sorts too" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // The outer map has a seq key (non-string -> stays in flow, unsorted);
    // the inner mapping value has scalar string keys and sorts.
    const keyseq = try a.dupe(Value, &.{ .{ .int = 1 }, .{ .int = 2 } });
    const inner = try a.dupe(Entry, &.{
        .{ .key = .{ .string = "b" }, .value = .{ .int = 1 } },
        .{ .key = .{ .string = "a" }, .value = .{ .int = 2 } },
    });
    const entries = try a.dupe(Entry, &.{.{ .key = .{ .seq = keyseq }, .value = .{ .map = inner } }});
    const v: Value = .{ .map = entries };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try emit(&aw.writer, v, .{ .sort_keys = true });
    try std.testing.expectEqualStrings("{? [1, 2]: {\"a\": 2, \"b\": 1}}\n", aw.written());
}

test "sort_keys: typed struct fields sorted, honoring rename" {
    const Inner = struct { yy: u8, xx: u8 };
    const C = struct {
        pub const yaml_rename = .{ .zed = "aaa" };
        zed: u8,
        bbb: Inner,
    };
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const c: C = .{ .zed = 1, .bbb = .{ .yy = 2, .xx = 3 } };
    try emitTyped(&aw.writer, c, a, .{ .sort_keys = true });
    // "aaa" (zed renamed) sorts before "bbb"; inner sorts xx before yy.
    try std.testing.expectEqualStrings("aaa: 1\nbbb:\n  xx: 3\n  yy: 2\n", aw.written());

    aw.clearRetainingCapacity();
    try emitTyped(&aw.writer, c, a, .{});
    try std.testing.expectEqualStrings("aaa: 1\nbbb:\n  yy: 2\n  xx: 3\n", aw.written());
}

test "isPlainSafe for a block value agrees with how emit writes a string" {
    const cases = [_][]const u8{ "hello", "darwin", "yes", "YES", "yEs", "1st", "0123", "1:20", ":sym", "a: b", "a #b", "-1abc", "--- x", "", " lead", "trail ", "\xff", "caf\xc3\xa9" };
    for (cases) |c| {
        var aw: Io.Writer.Allocating = .init(std.testing.allocator);
        defer aw.deinit();
        const plain = isPlainSafe(c, .{});
        emit(&aw.writer, .{ .string = c }, .{}) catch |e| {
            try std.testing.expect(e == error.InvalidUtf8);
            try std.testing.expect(!plain);
            continue;
        };
        const out = std.mem.trimEnd(u8, aw.written(), "\n");
        try std.testing.expectEqual(plain, std.mem.eql(u8, out, c));
    }
    try std.testing.expect(isPlainSafe("darwin", .{}));
    try std.testing.expect(!isPlainSafe("yEs", .{}));
    try std.testing.expect(!isPlainSafe("1st", .{}));
    try std.testing.expect(!isPlainSafe("\xff", .{}));
}

test "isPlainSafe in a flow collection also refuses flow indicators, `?` and `:`" {
    try std.testing.expect(isPlainSafe("darwin", .{ .flow = true }));
    for ([_][]const u8{ "?x", "x?y", "a,b", "[a", "a]", "{a", "a}", "a:b", ":x", "yes", "1st" }) |c|
        try std.testing.expect(!isPlainSafe(c, .{ .flow = true }));
    try std.testing.expect(isPlainSafe("?x", .{}));
    try std.testing.expect(isPlainSafe("a:b", .{}));
}

test "isPlainSafe for an implicit key also limits its length in characters" {
    const at_limit = &@as([max_implicit_key_chars]u8, @splat('k'));
    try std.testing.expect(isPlainSafe(at_limit, .{ .key = true }));
    try std.testing.expect(!isPlainSafe(at_limit ++ "k", .{ .key = true }));
    try std.testing.expect(isPlainSafe(at_limit ++ "k", .{}));
    try std.testing.expect(isPlainSafe(&@as([2 * max_implicit_key_chars]u8, @bitCast(@as([max_implicit_key_chars][2]u8, @splat("\u{e9}".*)))), .{ .key = true }));
}
