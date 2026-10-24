const std = @import("std");

// This JNI library does not link libc. Zig's default stderr writer pulls in
// Android libc symbols via its I/O runtime; keep safety panics self-contained.
pub const panic = std.debug.FullPanic(struct {
    fn call(message: []const u8, _: ?usize) noreturn {
        _ = std.os.linux.write(std.posix.STDERR_FILENO, message.ptr, message.len);
        @trap();
    }
}.call);

const extended_gamepad = @import("steamless-core").extended_gamepad;
const generic_gamepad = @import("steamless-core").generic_gamepad;
const triton = @import("steamless-core").triton;

// Generated per target from Android's official jni.h, without linking libc.
const jni = @import("jni-bindings");
const JniEnvironment = @import("jni_environment.zig");
const jint = jni.jint;
const jboolean = jni.jboolean;
const jobject = jni.jobject;
const jbyteArray = jni.jbyteArray;
const JNIEnv = jni.JNIEnv;

const JNI_FALSE: jboolean = jni.JNI_FALSE;
const JNI_TRUE: jboolean = jni.JNI_TRUE;
const MAX_TRITON_REPORT_BYTES = 64;

comptime {
    for (@typeInfo(NativeProtocol).@"struct".decl_names) |method_name| {
        @export(&@field(NativeProtocol, method_name), .{
            .name = "Java_xyz_reo101_steamlesslink_protocol_NativeProtocol_" ++ method_name,
        });
    }
}

// Only JNI entry points belong in this namespace; names match the Kotlin methods.
const NativeProtocol = struct {
    pub fn nativeMapTritonToXbox360(
        env: *JNIEnv,
        thiz: jobject,
        report_array: jbyteArray,
        requested_length: jint,
        out_packet_array: jbyteArray,
    ) callconv(.c) jboolean {
        _ = thiz;

        mapTritonToXbox360(env, report_array, requested_length, out_packet_array) catch |err| {
            throwZigError(env, err);
            return JNI_FALSE;
        };
        return JNI_TRUE;
    }

    pub fn nativeMapTritonToGenericGamepad(
        env: *JNIEnv,
        thiz: jobject,
        report_array: jbyteArray,
        requested_length: jint,
        out_packet_array: jbyteArray,
    ) callconv(.c) jboolean {
        _ = thiz;

        mapTritonToGenericGamepad(env, report_array, requested_length, out_packet_array) catch |err| {
            throwZigError(env, err);
            return JNI_FALSE;
        };
        return JNI_TRUE;
    }

    pub fn nativeMapTritonToLocalXbox360(
        env: *JNIEnv,
        thiz: jobject,
        report_array: jbyteArray,
        requested_length: jint,
        out_packet_array: jbyteArray,
        l4: jint,
        l5: jint,
        r4: jint,
        r5: jint,
        right_pad_stick: jboolean,
        touch_gyro: jboolean,
        gyro_full_scale_dps: jint,
    ) callconv(.c) jboolean {
        _ = thiz;
        const options = triton.LocalOptions{
            .grips = .{ @bitCast(l4), @bitCast(l5), @bitCast(r4), @bitCast(r5) },
            .right_pad_stick = right_pad_stick != 0,
            .touch_gyro = touch_gyro != 0,
            .gyro_full_scale_dps = @bitCast(gyro_full_scale_dps),
        };
        mapLocal(env, report_array, requested_length, out_packet_array, options) catch |err| {
            throwZigError(env, err);
            return JNI_FALSE;
        };
        return JNI_TRUE;
    }

    pub fn nativeMapTritonToExtendedGamepad(
        env: *JNIEnv,
        thiz: jobject,
        report_array: jbyteArray,
        requested_length: jint,
        out_packet_array: jbyteArray,
    ) callconv(.c) jboolean {
        _ = thiz;
        mapTritonToExtendedGamepad(env, report_array, requested_length, out_packet_array) catch |err| {
            throwZigError(env, err);
            return JNI_FALSE;
        };
        return JNI_TRUE;
    }
};

fn mapLocal(env: *JNIEnv, report_array: jbyteArray, length: jint, out: jbyteArray, options: triton.LocalOptions) !void {
    const environment: JniEnvironment = .init(env);
    if (environment.call(.GetArrayLength, .{out}) < triton.XBOX360_PACKET_SIZE) return error.OutputBufferTooSmall;
    var report: [MAX_TRITON_REPORT_BYTES]u8 = undefined;
    const bytes = try readTritonReport(env, report_array, length, &report);
    var packet: [triton.XBOX360_PACKET_SIZE]u8 = undefined;
    try triton.mapTritonToLocalXbox360(bytes, &packet, options);
    environment.call(.SetByteArrayRegion, .{ out, 0, packet.len, @ptrCast(&packet) });
}

fn mapTritonToXbox360(
    env: *JNIEnv,
    report_array: jbyteArray,
    requested_length: jint,
    out_packet_array: jbyteArray,
) !void {
    const environment: JniEnvironment = .init(env);
    const out_array_len = environment.call(.GetArrayLength, .{out_packet_array});
    if (out_array_len < triton.XBOX360_PACKET_SIZE) return error.OutputBufferTooSmall;

    var report: [MAX_TRITON_REPORT_BYTES]u8 = @splat(0);
    const report_bytes = try readTritonReport(env, report_array, requested_length, &report);
    var packet: [triton.XBOX360_PACKET_SIZE]u8 = @splat(0);
    try triton.mapTritonToXbox360(report_bytes, &packet);
    environment.call(.SetByteArrayRegion, .{
        out_packet_array,
        0,
        triton.XBOX360_PACKET_SIZE,
        @ptrCast(&packet),
    });
}

fn mapTritonToGenericGamepad(
    env: *JNIEnv,
    report_array: jbyteArray,
    requested_length: jint,
    out_packet_array: jbyteArray,
) !void {
    const environment: JniEnvironment = .init(env);
    const out_array_len = environment.call(.GetArrayLength, .{out_packet_array});
    if (out_array_len < generic_gamepad.INPUT_REPORT_SIZE) return error.OutputBufferTooSmall;

    var report: [MAX_TRITON_REPORT_BYTES]u8 = @splat(0);
    const report_bytes = try readTritonReport(env, report_array, requested_length, &report);
    var packet: [generic_gamepad.INPUT_REPORT_SIZE]u8 = @splat(0);
    try generic_gamepad.mapTritonToInput(report_bytes, &packet);
    environment.call(.SetByteArrayRegion, .{
        out_packet_array,
        0,
        generic_gamepad.INPUT_REPORT_SIZE,
        @ptrCast(&packet),
    });
}

fn mapTritonToExtendedGamepad(env: *JNIEnv, report_array: jbyteArray, requested_length: jint, out_packet_array: jbyteArray) !void {
    const environment: JniEnvironment = .init(env);
    if (environment.call(.GetArrayLength, .{out_packet_array}) < extended_gamepad.PACKET_SIZE) return error.OutputBufferTooSmall;
    var report: [MAX_TRITON_REPORT_BYTES]u8 = undefined;
    const bytes = try readTritonReport(env, report_array, requested_length, &report);
    var packet: [extended_gamepad.PACKET_SIZE]u8 = undefined;
    try extended_gamepad.mapTritonToInput(bytes, &packet);
    environment.call(.SetByteArrayRegion, .{ out_packet_array, 0, extended_gamepad.PACKET_SIZE, @ptrCast(&packet) });
}

fn readTritonReport(
    env: *JNIEnv,
    report_array: jbyteArray,
    requested_length: jint,
    out: *[MAX_TRITON_REPORT_BYTES]u8,
) ![]const u8 {
    if (requested_length < 0) return error.InvalidLength;
    const environment: JniEnvironment = .init(env);
    const report_array_len = environment.call(.GetArrayLength, .{report_array});
    if (requested_length > report_array_len) return error.InvalidLength;

    const requested_len: usize = @intCast(requested_length);
    const copy_len = @min(requested_len, MAX_TRITON_REPORT_BYTES);
    if (copy_len > 0) {
        environment.call(.GetByteArrayRegion, .{
            report_array,
            0,
            @intCast(copy_len),
            @ptrCast(out),
        });
    }
    return out[0..copy_len];
}

fn throwZigError(env: *JNIEnv, err: anyerror) void {
    switch (err) {
        error.ReportTooShort,
        error.UnsupportedReport,
        error.InvalidLength,
        error.InvalidMappingOptions,
        => throwNew(env, "java/lang/IllegalArgumentException", @errorName(err)),

        error.OutputBufferTooSmall,
        => throwNew(env, "java/lang/IndexOutOfBoundsException", @errorName(err)),

        else => throwNew(env, "java/lang/RuntimeException", @errorName(err)),
    }
}

fn throwNew(env: *JNIEnv, class_name: [*:0]const u8, message: [*:0]const u8) void {
    const environment: JniEnvironment = .init(env);
    const cls = environment.call(.FindClass, .{class_name});
    if (cls == null) return;
    _ = environment.call(.ThrowNew, .{ cls, message });
}
