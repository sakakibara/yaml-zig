const std = @import("std");

pub const Field = struct {
    name: [:0]const u8,
    type: type,
    default_value_ptr: ?*const anyopaque,

    pub inline fn defaultValue(comptime field: Field) ?field.type {
        const ptr: *const field.type = @ptrCast(@alignCast(field.default_value_ptr orelse return null));
        return ptr.*;
    }
};

pub fn fields(comptime T: type) []const Field {
    comptime {
        const info = @typeInfo(T);
        const container = switch (info) {
            .@"struct" => |struct_info| struct_info,
            .@"union" => |union_info| union_info,
            else => @compileError("expected struct or union, found " ++ @typeName(T)),
        };
        var result: []const Field = &.{};
        switch (info) {
            .@"struct" => {
                if (@hasField(@TypeOf(container), "fields")) {
                    for (container.fields) |field| {
                        result = result ++ &[_]Field{.{
                            .name = field.name,
                            .type = field.type,
                            .default_value_ptr = field.default_value_ptr,
                        }};
                    }
                } else {
                    for (container.field_names, container.field_types, container.field_attrs) |name, field_type, attrs| {
                        result = result ++ &[_]Field{.{
                            .name = name,
                            .type = field_type,
                            .default_value_ptr = attrs.default_value_ptr,
                        }};
                    }
                }
            },
            .@"union" => {
                if (@hasField(@TypeOf(container), "fields")) {
                    for (container.fields) |field| {
                        result = result ++ &[_]Field{.{
                            .name = field.name,
                            .type = field.type,
                            .default_value_ptr = null,
                        }};
                    }
                } else {
                    for (container.field_names, container.field_types) |name, field_type| {
                        result = result ++ &[_]Field{.{
                            .name = name,
                            .type = field_type,
                            .default_value_ptr = null,
                        }};
                    }
                }
            },
            else => unreachable,
        }
        return result;
    }
}

pub fn functionParamCount(comptime function: anytype) usize {
    if (comptime @hasField(std.builtin.Type.Fn, "params")) return function.params.len;
    return function.param_types.len;
}

pub fn pointerIsConst(comptime pointer: anytype) bool {
    if (comptime @hasField(std.builtin.Type.Pointer, "is_const")) return pointer.is_const;
    return pointer.attrs.@"const";
}
