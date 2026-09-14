//! Standards-first profile: separate gamepad, two single-touch pads and HID sensor hub.
//! Usage IDs: USB HID Usage Tables; source layout/scales: SDL's steam_triton driver.
const std = @import("std");
const generic = @import("generic_gamepad.zig");
const triton = @import("triton.zig");

pub const NAMES = [_][]const u8{
    "SteamlessLink Extended Gamepad",
    "SteamlessLink Left Touchpad",
    "SteamlessLink Right Touchpad",
    "SteamlessLink Motion Sensors",
};
pub const GamepadReport = packed struct {
    id: u8 = 1,
    buttons: u32,
    hat: u8,
    x: u8,
    y: u8,
    rx: u8,
    ry: u8,
    z: u8,
    rz: u8,
};
pub const PadReport = packed struct {
    id: u8 = 1,
    touching: bool,
    padding: u7 = 0,
    x: u16,
    y: u16,
    pressure: u16,
};
pub const SensorReport = packed struct {
    id: u8,
    x: i32,
    y: i32,
    z: i32,
};
pub const ReportingState = enum(u8) { no_events = 1, all_events = 2 };
pub const PowerState = enum(u8) { full = 1, low = 2, standby = 3, sleep = 4, off = 5 };
pub const SensorFeature = packed struct {
    id: u8,
    reporting: ReportingState = .no_events,
    power: PowerState = .off,
    interval_ms: u32 = 4,
};

pub fn wireSize(comptime T: type) usize {
    return @divExact(@bitSizeOf(T), 8);
}
fn byteOffset(comptime T: type, comptime field: []const u8) usize {
    return @divExact(@bitOffsetOf(T, field), 8);
}
fn encode(comptime T: type, value: T, out: []u8) void {
    const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
    std.mem.writeInt(Bits, out[0..comptime wireSize(T)], @bitCast(value), .little);
}
pub const GAMEPAD_SIZE = wireSize(GamepadReport);
pub const PAD_SIZE = wireSize(PadReport);
pub const SENSOR_SIZE = wireSize(SensorReport);
pub const Sensor = struct {
    pub const DEVICE = 3;
    pub const COUNT = 2;
    pub const FIRST_REPORT_ID = 1;
    pub const FEATURE_REPORT_TYPE = 0; // Linux UHID, not USB's report-type numbering
    pub const INPUT_REPORT_TYPE = 2;
    pub const ID_OFFSET = byteOffset(SensorFeature, "id");
    pub const REPORTING_OFFSET = byteOffset(SensorFeature, "reporting");
    pub const POWER_OFFSET = byteOffset(SensorFeature, "power");
    pub const INTERVAL_OFFSET = byteOffset(SensorFeature, "interval_ms");
    pub const FEATURE_SIZE = wireSize(SensorFeature);
    pub const NO_EVENTS = @intFromEnum(ReportingState.no_events);
    pub const ALL_EVENTS = @intFromEnum(ReportingState.all_events);
    pub const FULL_POWER = @intFromEnum(PowerState.full);
    pub const POWER_OFF = @intFromEnum(PowerState.off);
    pub const INTERVAL_MS = (SensorFeature{ .id = FIRST_REPORT_ID }).interval_ms;
};
// Packed JNI result only, split into five ordinary HID reports before transmission.
pub const PACKET_SIZE = blk: {
    var size: usize = 0;
    for (REPORT_SIZES) |report_size| size += report_size;
    break :blk size;
};
pub const REPORT_SIZES = [_]usize{ GAMEPAD_SIZE, PAD_SIZE, PAD_SIZE, SENSOR_SIZE, SENSOR_SIZE };
pub const REPORT_DEVICES = [_]u8{ 0, 1, 2, 3, 3 };

pub const GAMEPAD_DESCRIPTOR = [_]u8{
    0x05, 0x01, 0x09, 0x05, 0xa1, 0x01, 0x85, 0x01,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x20, // Button 1..32
    0x15, 0x00, 0x25, 0x01, 0x75, 0x01,
    0x95, 0x20, 0x81, 0x02,
    0x05, 0x01, 0x09, 0x39, // hat
    0x15, 0x00, 0x25, 0x07,
    0x35, 0x00, 0x46, 0x3b,
    0x01, 0x65, 0x14, 0x75,
    0x04, 0x95, 0x01, 0x81,
    0x42, 0x75, 0x04, 0x95,
    0x01, 0x81, 0x03, 0x65,
    0x00, 0x35, 0x00, 0x45,
    0x00, 0x15, 0x00, 0x26,
    0xff, 0x00, 0x75, 0x08,
    0x95, 0x06, 0x09, 0x30,
    0x09, 0x31, 0x09, 0x33,
    0x09, 0x34, 0x09, 0x32,
    0x09, 0x35, 0x81, 0x02,
    0xc0,
};

// Single-touch Digitizer/Touch Pad. No Contact ID, so hid-generic handles it
// without a multitouch handshake. Coordinates and pressure remain absolute.
pub const PAD_DESCRIPTOR = [_]u8{
    0x05, 0x0d, 0x09, 0x05, 0xa1, 0x01, 0x85, 0x01,
    0x09, 0x22, 0xa1, 0x02, // Finger
    0x09, 0x42, 0x15, 0x00,
    0x25, 0x01, 0x75, 0x01,
    0x95, 0x01, 0x81, 0x02,
    0x75, 0x07, 0x95, 0x01,
    0x81, 0x03, 0x05, 0x01,
    0x09, 0x30, 0x09, 0x31,
    0x15, 0x00, 0x27, 0xff,
    0xff, 0x00, 0x00, 0x75,
    0x10, 0x95, 0x02, 0x81,
    0x02,
    0x05, 0x0d, 0x09, 0x30, // Tip Pressure
    0x75, 0x10, 0x95, 0x01,
    0x81, 0x02, 0xc0, 0xc0,
};

// Feature report for each sensor: ID, reporting state (1=no events,2=all),
// power (1=full,2..5=lower power), interval ms (u32). Fixed interval 4 ms.
// Linux's HID sensor drivers query/set these during probe and activation.
pub const SENSOR_FEATURE_SIZE = Sensor.FEATURE_SIZE;
pub const SENSOR_INTERVAL_MS = Sensor.INTERVAL_MS;
fn sensorDescriptor(comptime id: u8, comptime usage: u8, comptime axis: u16, comptime unit: u16) []const u8 {
    return &.{
        0x05, 0x20, 0x09, usage, 0xa1, 0x00, 0x85, id,
        0x0a, 0x16, 0x03, 0xa1, 0x02, // Reporting State (logical collection)
        0x15, 0x01, 0x25, 0x02, 0x75,
        0x08, 0x95, 0x01, 0x0a, 0x40,
        0x08, 0x0a, 0x41, 0x08, 0xb1,
        0x00, 0xc0,
        0x0a, 0x19, 0x03, 0xa1, 0x02, // Power State
        0x15, 0x01, 0x25, 0x05, 0x75,
        0x08, 0x95, 0x01, 0x1a, 0x51,
        0x08, 0x2a, 0x55, 0x08, 0xb1,
        0x00, 0xc0,
        0x0a,                 0x0e,                                      0x03, // Report Interval
        0x15,                 SENSOR_INTERVAL_MS,                        0x25,
        SENSOR_INTERVAL_MS,   0x75,                                      0x20,
        0x95,                 0x01,                                      0x65,
        0x19,                 0xb1,                                      0x02,
        // Axis values in micro m/s^2 or micro rad/s, signed 32-bit.
        0x17,                 0x00,                                      0x00,
        0x00,                 0x80,                                      0x27,
        0xff,                 0xff,                                      0xff,
        0x7f,                 0x66,                                      @truncate(unit),
        @truncate(unit >> 8), 0x55,                                      0x0a,
        0x75,                 @bitSizeOf(@FieldType(SensorReport, "x")), 0x95,
        0x01,
        // Separate fields: hid-sensor-hub dispatches each field by its first usage.
                        0x0a,                                      @truncate(axis),
        @truncate(axis >> 8), 0x81,                                      0x02,
        0x0a,                 @truncate(axis + 1),                       @truncate((axis + 1) >> 8),
        0x81,                 0x02,                                      0x0a,
        @truncate(axis + 2),  @truncate((axis + 2) >> 8),                0x81,
        0x02,                 0x55,                                      0x00,
        0x65,                 0x00,                                      0xc0,
    };
}
pub const SENSOR_DESCRIPTOR = sensorDescriptor(1, 0x73, 0x0453, 0x11e0) ++ sensorDescriptor(2, 0x76, 0x0457, 0x12f0);
pub const DESCRIPTORS = [_][]const u8{ &GAMEPAD_DESCRIPTOR, &PAD_DESCRIPTOR, &PAD_DESCRIPTOR, SENSOR_DESCRIPTOR };

// Extra HID buttons 16..30. Bits sourced from SDL_hidapi_steam_triton.c.
// QAM,L4,R4,L5,R5,pad clicks,trigger clicks,stick touch,pad touch,grip touch.
const EXTRA_BUTTONS = [_]u32{
    0x10,       0x20000,  0x80,      0x40000,  0x100,     0x4000000, 0x400000,
    0x8000000,  0x800000, 0x1000000, 0x100000, 0x2000000, 0x200000,  0x20000000,
    0x10000000,
};

pub fn mapTritonToInput(report: []const u8, out: []u8) triton.Error!void {
    if (out.len < PACKET_SIZE) return error.OutputBufferTooSmall;
    const state = try triton.parse(report);
    const pads = state.pads orelse return error.ReportTooShort;
    const imu = state.imu orelse return error.ReportTooShort;
    var basic: [generic.INPUT_REPORT_SIZE]u8 = undefined;
    try generic.mapTritonToInput(report, &basic);
    var buttons: @FieldType(GamepadReport, "buttons") = std.mem.readInt(u16, basic[1..3], .little);
    for (EXTRA_BUTTONS, 15..) |mask, bit| {
        if (state.buttons & mask != 0) buttons |= @as(u32, 1) << @intCast(bit);
    }
    encode(GamepadReport, .{
        .buttons = buttons,
        .hat = basic[3],
        .x = basic[4],
        .y = 255 - basic[5],
        .rx = basic[6],
        .ry = 255 - basic[7],
        .z = basic[8],
        .rz = basic[9],
    }, out);
    // Triton Y points up; HID gamepad/touchpad Y points down.
    for (pads, 0..) |pad, index| {
        const offset = GAMEPAD_SIZE + index * PAD_SIZE;
        const touching = state.buttons & (if (index == 0) @as(u32, 0x2000000) else 0x200000) != 0;
        encode(PadReport, .{
            .touching = touching,
            .x = @intCast(@as(i32, pad.x) + 32768),
            .y = @intCast(32767 - @as(i32, pad.y)),
            .pressure = if (touching) pad.pressure else 0,
        }, out[offset..]);
    }
    // Same right-handed axis convention as SDL: X, Z, -Y.
    for ([_][3]i16{ imu.accel, imu.gyro }, 0..) |axes, index| {
        const offset = GAMEPAD_SIZE + 2 * PAD_SIZE + index * SENSOR_SIZE;
        const scale: f64 = if (index == 0) 2.0 * 9.80665 * 1e6 / 32768.0 else 2000.0 * std.math.pi / 180.0 * 1e6 / 32768.0;
        const oriented = [_]i32{ axes[0], axes[2], -@as(i32, axes[1]) };
        var scaled: [oriented.len]@FieldType(SensorReport, "x") = undefined;
        for (oriented, &scaled) |value, *axis| axis.* = @intFromFloat(@round(@as(f64, @floatFromInt(value)) * scale));
        encode(SensorReport, .{
            .id = @intCast(index + Sensor.FIRST_REPORT_ID),
            .x = scaled[0],
            .y = scaled[1],
            .z = scaled[2],
        }, out[offset..]);
    }
}

test "wire serialization excludes packed backing storage padding" {
    var feature: [wireSize(SensorFeature)]u8 = undefined;
    encode(SensorFeature, .{ .id = 2, .interval_ms = 0x12345678 }, &feature);
    try std.testing.expectEqualSlices(u8, &.{ 2, 1, 5, 0x78, 0x56, 0x34, 0x12 }, &feature);
    try std.testing.expectEqual(@as(usize, 3), byteOffset(SensorFeature, "interval_ms"));
    try std.testing.expectEqual(@as(usize, 13), wireSize(SensorReport));
    var sensor: [wireSize(SensorReport)]u8 = undefined;
    encode(SensorReport, .{ .id = 1, .x = -1, .y = 0x12345678, .z = -2147483648 }, &sensor);
    try std.testing.expectEqualSlices(u8, &.{ 1, 255, 255, 255, 255, 0x78, 0x56, 0x34, 0x12, 0, 0, 0, 128 }, &sensor);
}

test "all descriptors match actual wire report lengths" {
    // Independent HID short-item decoding. Also forces every descriptor to instantiate.
    for (DESCRIPTORS, 0..) |descriptor, device| {
        var inputs = [_]usize{0} ** 3;
        var features = [_]usize{0} ** 3;
        var size: usize = 0;
        var count: usize = 0;
        var id: usize = 0;
        var offset: usize = 0;
        while (offset < descriptor.len) {
            const prefix = descriptor[offset];
            const length: usize = if (prefix & 3 == 3) 4 else prefix & 3;
            offset += 1;
            try std.testing.expect(offset + length <= descriptor.len);
            var value: usize = 0;
            for (descriptor[offset..][0..length], 0..) |byte, shift| value |= @as(usize, byte) << @intCast(shift * 8);
            offset += length;
            switch (prefix & 0xfc) {
                0x74 => size = value,
                0x94 => count = value,
                0x84 => id = value,
                0x80 => inputs[id] += size * count,
                0xb0 => features[id] += size * count,
                else => {},
            }
        }
        for (REPORT_DEVICES, REPORT_SIZES, 0..) |slot, report_size, index| {
            if (slot != device) continue;
            const report_id: usize = if (index == REPORT_SIZES.len - 1) 2 else 1;
            try std.testing.expectEqual(report_size * 8, inputs[report_id] + 8);
        }
        for (features[1..]) |bits| try std.testing.expectEqual(if (device == Sensor.DEVICE) (wireSize(SensorFeature) - 1) * 8 else @as(usize, 0), bits);
    }
}

test "extended profile preserves pads, paddles and both IMU layouts" {
    for ([_]u8{ 0x42, 0x45, 0x47 }) |id| {
        var report = [_]u8{0} ** 46;
        report[0] = id;
        std.mem.writeInt(u32, report[2..6], 0x2020080, .little); // L4, R4, left pad touch
        const pad: usize = if (id == 0x47) 20 else 18;
        std.mem.writeInt(i16, report[pad..][0..2], -32768, .little);
        std.mem.writeInt(i16, report[pad + 2 ..][0..2], 32767, .little);
        std.mem.writeInt(u16, report[pad + 4 ..][0..2], 1234, .little);
        std.mem.writeInt(i16, report[34..36], 16384, .little); // 1g X
        std.mem.writeInt(i16, report[42..44], -32768, .little); // +2000 deg/s Z after orientation
        var out: [PACKET_SIZE]u8 = undefined;
        try mapTritonToInput(&report, &out);
        try std.testing.expectEqual(@as(u32, (1 << 16) | (1 << 17) | (1 << 26)), std.mem.readInt(u32, out[1..5], .little));
        try std.testing.expectEqualSlices(u8, &.{ 1, 1, 0, 0, 0, 0, 0xd2, 4 }, out[12..20]);
        try std.testing.expectEqual(@as(i32, 9806650), std.mem.readInt(i32, out[29..33], .little));
        try std.testing.expectEqual(@as(i32, 34906585), std.mem.readInt(i32, out[50..54], .little));
        try std.testing.expectError(error.ReportTooShort, mapTritonToInput(report[0..45], &out));
        try std.testing.expectError(error.OutputBufferTooSmall, mapTritonToInput(&report, out[0..53]));
    }
}
