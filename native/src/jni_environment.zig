const std = @import("std");
const jni = @import("jni-bindings");
const Environment = @This();
const Interface = @typeInfo(jni.JNIEnv).pointer.child;

pub const Method = methodEnum();

env: *jni.JNIEnv,

/// Borrows the current thread's JNI environment.
pub fn init(env: *jni.JNIEnv) Environment {
    return .{ .env = env };
}

/// Unwraps only the selected function pointer, not its arguments or return value.
pub fn call(self: Environment, comptime method: Method, arguments: ArgumentsType(method)) ReturnType(method) {
    if (functionInfo(method).attrs.varargs) @compileError("Use callVariadic for C variadic JNI methods");
    const functions: *const Interface = self.env.*;
    const function = @field(functions, @tagName(method)).?;
    return @call(.auto, function, .{self.env} ++ arguments);
}

/// Trailing arguments must use the C types required by the variadic method.
pub fn callVariadic(self: Environment, comptime method: Method, arguments: ArgumentsType(method), variadic_arguments: anytype) ReturnType(method) {
    if (!functionInfo(method).attrs.varargs) @compileError("Use call for non-variadic JNI methods");
    const functions: *const Interface = self.env.*;
    const function = @field(functions, @tagName(method)).?;
    return @call(.auto, function, .{self.env} ++ arguments ++ variadic_arguments);
}

fn ArgumentsType(comptime method: Method) type {
    const parameters = functionInfo(method).param_types[1..];
    var types: [parameters.len]type = undefined;
    for (&types, parameters) |*Type, Parameter| Type.* = Parameter.?;
    return @Tuple(&types);
}

fn ReturnType(comptime method: Method) type {
    return functionInfo(method).return_type.?;
}

fn functionInfo(comptime method: Method) std.lang.Type.Fn {
    const OptionalPointer = @FieldType(Interface, @tagName(method));
    const Pointer = @typeInfo(OptionalPointer).optional.child;
    const Function = @typeInfo(Pointer).pointer.child;
    return @typeInfo(Function).@"fn";
}

fn methodEnum() type {
    @setEvalBranchQuota(10_000);
    const fields = @typeInfo(Interface).@"struct";
    var storage: [fields.field_names.len][:0]const u8 = undefined;
    var names: std.ArrayList([:0]const u8) = .initBuffer(&storage);
    for (fields.field_names, fields.field_types) |name, Field| {
        const Pointer = switch (@typeInfo(Field)) {
            .optional => |optional| optional.child,
            else => continue,
        };
        const Function = switch (@typeInfo(Pointer)) {
            .pointer => |pointer| pointer.child,
            else => continue,
        };
        if (@typeInfo(Function) != .@"fn") continue;
        names.appendAssumeCapacity(name);
    }
    const Tag = std.math.IntFittingRange(0, names.items.len - 1);
    var values: [names.items.len]Tag = undefined;
    for (&values, 0..) |*value, index| value.* = @intCast(index);
    return @Enum(Tag, .exhaustive, names.items, &values);
}

const VariadicCall = struct {
    env: [*c]jni.JNIEnv = null,
    object: jni.jobject = null,
    method: jni.jmethodID = null,
};

var last_variadic_call: VariadicCall = .{};

const TestState = struct {
    length: jni.jsize = 37,
    env: [*c]jni.JNIEnv = null,
    bytes: [4]jni.jbyte = @splat(0),
};

const TestFunctions = struct {
    fn getVersion(env: [*c]jni.JNIEnv) callconv(.c) jni.jint {
        std.debug.assert(env != null);
        return jni.JNI_VERSION_1_6;
    }

    fn getArrayLength(env: [*c]jni.JNIEnv, array: jni.jarray) callconv(.c) jni.jsize {
        const state: *TestState = @ptrCast(@alignCast(array.?));
        state.env = env;
        return state.length;
    }

    fn setByteArrayRegion(env: [*c]jni.JNIEnv, array: jni.jbyteArray, start: jni.jsize, length: jni.jsize, buffer: [*c]const jni.jbyte) callconv(.c) void {
        const state: *TestState = @ptrCast(@alignCast(array.?));
        state.env = env;
        const offset: usize = @intCast(start);
        const count: usize = @intCast(length);
        @memcpy(state.bytes[offset..][0..count], buffer[0..count]);
    }

    fn newGlobalRef(_: [*c]jni.JNIEnv, object: jni.jobject) callconv(.c) jni.jobject {
        return object;
    }

    fn callIntMethod(env: [*c]jni.JNIEnv, object: jni.jobject, method: jni.jmethodID, ...) callconv(.c) jni.jint {
        last_variadic_call = .{ .env = env, .object = object, .method = method };
        var arguments = @cVaStart();
        defer @cVaEnd(&arguments);
        return @cVaArg(&arguments, jni.jint) + @cVaArg(&arguments, jni.jint);
    }
};

test "method names include JNI functions but exclude reserved slots" {
    @setEvalBranchQuota(10_000);
    try std.testing.expect(@hasField(Method, "GetVersion"));
    try std.testing.expect(@hasField(Method, "CallIntMethod"));
    try std.testing.expect(@hasField(Method, "GetObjectRefType"));
    inline for (@typeInfo(Interface).@"struct".field_names) |name| {
        if (comptime std.mem.startsWith(u8, name, "reserved")) {
            try std.testing.expect(!@hasField(Method, name));
        }
    }
    inline for (@typeInfo(Method).@"enum".field_names, 0..) |name, index| {
        try std.testing.expectEqual(index, @as(usize, @backingInt(@field(Method, name))));
    }
}

test "methods with only an environment parameter accept an empty tuple" {
    var functions: Interface = std.mem.zeroes(Interface);
    functions.GetVersion = TestFunctions.getVersion;
    var raw_env: jni.JNIEnv = &functions;
    const environment: Environment = .init(&raw_env);

    try std.testing.expectEqual(@as(jni.jint, jni.JNI_VERSION_1_6), environment.call(.GetVersion, .{}));
}

test "dispatch forwards the environment and arguments without unwrapping unused slots" {
    var functions: Interface = std.mem.zeroes(Interface);
    functions.GetArrayLength = TestFunctions.getArrayLength;
    var raw_env: jni.JNIEnv = &functions;
    var state: TestState = .{};
    const environment: Environment = .init(&raw_env);
    const array: jni.jarray = @ptrCast(&state);

    try std.testing.expectEqual(state.length, environment.call(.GetArrayLength, .{array}));
    try std.testing.expect(state.env == &raw_env);
    try std.testing.expect(functions.FindClass == null);
}

test "void dispatch preserves buffer pointers and argument order" {
    var functions: Interface = std.mem.zeroes(Interface);
    functions.SetByteArrayRegion = TestFunctions.setByteArrayRegion;
    var raw_env: jni.JNIEnv = &functions;
    var state: TestState = .{};
    const environment: Environment = .init(&raw_env);
    const bytes = [_]jni.jbyte{ -1, 7 };

    environment.call(.SetByteArrayRegion, .{ @ptrCast(&state), 1, @intCast(bytes.len), &bytes });
    try std.testing.expectEqualSlices(jni.jbyte, &.{ 0, -1, 7, 0 }, &state.bytes);
    try std.testing.expect(state.env == &raw_env);
}

test "nullable JNI arguments and return values remain nullable" {
    var functions: Interface = std.mem.zeroes(Interface);
    functions.NewGlobalRef = TestFunctions.newGlobalRef;
    var raw_env: jni.JNIEnv = &functions;
    var state: TestState = .{};
    const environment: Environment = .init(&raw_env);
    const object: jni.jobject = @ptrCast(&state);

    try std.testing.expectEqual(object, environment.call(.NewGlobalRef, .{object}));
    try std.testing.expectEqual(@as(jni.jobject, null), environment.call(.NewGlobalRef, .{null}));
}

test "argument tuples match every method signature without the bound environment" {
    comptime {
        @setEvalBranchQuota(20_000);
        for (@typeInfo(Method).@"enum".field_names) |name| {
            const method = @field(Method, name);
            const parameters = functionInfo(method).param_types[1..];
            const tuple = @typeInfo(ArgumentsType(method)).@"struct";
            std.debug.assert(tuple.is_tuple);
            std.debug.assert(parameters.len == tuple.field_types.len);
            for (parameters, tuple.field_types) |Parameter, Argument| {
                std.debug.assert(Parameter.? == Argument);
            }
        }
    }
}

test "variadic dispatch forwards fixed and trailing arguments" {
    var functions: Interface = std.mem.zeroes(Interface);
    functions.CallIntMethod = TestFunctions.callIntMethod;
    var raw_env: jni.JNIEnv = &functions;
    const environment: Environment = .init(&raw_env);
    const object: jni.jobject = @ptrFromInt(0x1000);
    const method: jni.jmethodID = @ptrFromInt(0x2000);

    const total = environment.callVariadic(.CallIntMethod, .{ object, method }, .{ @as(jni.jint, 7), @as(jni.jint, 35) });

    try std.testing.expectEqual(@as(jni.jint, 42), total);
    try std.testing.expectEqual(@as([*c]jni.JNIEnv, @ptrCast(&raw_env)), last_variadic_call.env);
    try std.testing.expectEqual(object, last_variadic_call.object);
    try std.testing.expectEqual(method, last_variadic_call.method);
}
