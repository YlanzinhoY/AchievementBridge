const std = @import("std");

pub fn getMethod(instance: *anyopaque, index: usize, comptime Function: type) Function {
    const vtable_pointer: *const [*]const *const anyopaque = @ptrCast(@alignCast(instance));
    return @ptrCast(vtable_pointer.*[index]);
}

test "read a typed method from a C++ style vtable" {
    const Example = struct {
        fn value(_: *anyopaque) callconv(.c) u32 {
            return 42;
        }
    };
    var methods = [_]*const anyopaque{@ptrCast(&Example.value)};
    var object: [*]const *const anyopaque = &methods;
    const instance: *anyopaque = @ptrCast(&object);
    const method = getMethod(instance, 0, *const fn (*anyopaque) callconv(.c) u32);
    try std.testing.expectEqual(@as(u32, 42), method(instance));
}
