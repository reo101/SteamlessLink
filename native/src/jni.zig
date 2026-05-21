const protocol = @import("protocol.zig");

const jint = i32;
const jsize = i32;
const jbyte = i8;
const jboolean = u8;
const jobject = ?*anyopaque;
const jclass = jobject;
const jarray = jobject;
const jbyteArray = jarray;

const JNI_FALSE: jboolean = 0;
const JNI_TRUE: jboolean = 1;
const MAX_TRITON_REPORT_BYTES = 64;

// Minimal C JNI table prefix. Zig can call JNI directly through this stable
// ABI without importing `jni.h` or depending on Android libc headers.
const JNINativeInterface = extern struct {
    skip0: [6]?*const anyopaque,
    FindClass: *const fn (env: *JNIEnv, name: [*:0]const u8) callconv(.c) jclass,
    skip1: [7]?*const anyopaque,
    ThrowNew: *const fn (env: *JNIEnv, clazz: jclass, msg: [*:0]const u8) callconv(.c) jint,
    skip2: [156]?*const anyopaque,
    GetArrayLength: *const fn (env: *JNIEnv, array: jarray) callconv(.c) jsize,
    skip3: [28]?*const anyopaque,
    GetByteArrayRegion: *const fn (env: *JNIEnv, array: jbyteArray, start: jsize, len: jsize, buf: [*]jbyte) callconv(.c) void,
    skip4: [7]?*const anyopaque,
    SetByteArrayRegion: *const fn (env: *JNIEnv, array: jbyteArray, start: jsize, len: jsize, buf: [*]const jbyte) callconv(.c) void,
};
const JNIEnv = *const JNINativeInterface;

export fn Java_xyz_reo101_steamlesslink_protocol_NativeProtocol_nativeMapTritonToViiper(
    env: *JNIEnv,
    thiz: jobject,
    report_array: jbyteArray,
    requested_length: jint,
    out_packet_array: jbyteArray,
) jboolean {
    _ = thiz;

    mapTritonToViiper(env, report_array, requested_length, out_packet_array) catch |err| {
        throwZigError(env, err);
        return JNI_FALSE;
    };
    return JNI_TRUE;
}

fn mapTritonToViiper(
    env: *JNIEnv,
    report_array: jbyteArray,
    requested_length: jint,
    out_packet_array: jbyteArray,
) !void {
    if (requested_length < 0) return error.InvalidLength;

    const report_array_len = env.*.GetArrayLength(env, report_array);
    const out_array_len = env.*.GetArrayLength(env, out_packet_array);
    if (out_array_len < protocol.VIIPER_PACKET_SIZE) return error.OutputBufferTooSmall;
    if (requested_length > report_array_len) return error.InvalidLength;

    const requested_len: usize = @intCast(requested_length);
    const copy_len = @min(requested_len, MAX_TRITON_REPORT_BYTES);
    var report = [_]u8{0} ** MAX_TRITON_REPORT_BYTES;
    if (copy_len > 0) {
        env.*.GetByteArrayRegion(
            env,
            report_array,
            0,
            @intCast(copy_len),
            @ptrCast(&report),
        );
    }

    var packet = [_]u8{0} ** protocol.VIIPER_PACKET_SIZE;
    try protocol.mapTritonToViiper(report[0..copy_len], &packet);
    env.*.SetByteArrayRegion(
        env,
        out_packet_array,
        0,
        protocol.VIIPER_PACKET_SIZE,
        @ptrCast(&packet),
    );
}

fn throwZigError(env: *JNIEnv, err: anyerror) void {
    switch (err) {
        error.ReportTooShort,
        error.UnsupportedReport,
        error.InvalidLength,
        => throwNew(env, "java/lang/IllegalArgumentException", @errorName(err)),

        error.OutputBufferTooSmall,
        => throwNew(env, "java/lang/IndexOutOfBoundsException", @errorName(err)),

        else => throwNew(env, "java/lang/RuntimeException", @errorName(err)),
    }
}

fn throwNew(env: *JNIEnv, class_name: [*:0]const u8, message: [*:0]const u8) void {
    const cls = env.*.FindClass(env, class_name);
    if (cls == null) return;
    _ = env.*.ThrowNew(env, cls, message);
}
