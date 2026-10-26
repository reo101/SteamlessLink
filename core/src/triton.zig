const std = @import("std");

pub const Error = error{
    ReportTooShort,
    UnsupportedReport,
    OutputBufferTooSmall,
    InvalidMappingOptions,
};

pub const REPORT_ID_USB_STATE = 0x42;
pub const REPORT_ID_BLE_STATE = 0x45;
pub const REPORT_ID_BLE_TIMESTAMP_STATE = 0x47;
pub const MIN_BASIC_REPORT_BYTES = 18;
pub const XBOX360_PACKET_SIZE = 20;

// SDL steam/controller_constants.h: SetSettingsValues, lizard mode and IMU mode.
pub const EXTENDED_BLE_SETTINGS = [_]u8{ 0x87, 6, 9, 0, 0, 48, 0x18, 0 };
pub const EXTENDED_USB_SETTINGS = [_]u8{1} ++ EXTENDED_BLE_SETTINGS ++ @as([64 - 1 - EXTENDED_BLE_SETTINGS.len]u8, @splat(0));

pub const Buttons = struct {
    pub const A: u32 = 0x0000_0001;
    pub const B: u32 = 0x0000_0002;
    pub const X: u32 = 0x0000_0004;
    pub const Y: u32 = 0x0000_0008;
    pub const QAM: u32 = 0x0000_0010;
    pub const R3: u32 = 0x0000_0020;
    pub const VIEW: u32 = 0x0000_0040;
    pub const R4: u32 = 0x0000_0080;
    pub const R5: u32 = 0x0000_0100;
    pub const R: u32 = 0x0000_0200;
    pub const DPAD_DOWN: u32 = 0x0000_0400;
    pub const DPAD_RIGHT: u32 = 0x0000_0800;
    pub const DPAD_LEFT: u32 = 0x0000_1000;
    pub const DPAD_UP: u32 = 0x0000_2000;
    pub const MENU: u32 = 0x0000_4000;
    pub const L3: u32 = 0x0000_8000;
    pub const STEAM: u32 = 0x0001_0000;
    pub const L4: u32 = 0x0002_0000;
    pub const L5: u32 = 0x0004_0000;
    pub const L: u32 = 0x0008_0000;
    pub const RIGHT_JOYSTICK_TOUCH: u32 = 0x0010_0000;
    pub const RIGHT_TOUCHPAD_TOUCH: u32 = 0x0020_0000;
    pub const RIGHT_TOUCHPAD_CLICK: u32 = 0x0040_0000;
    pub const RIGHT_TRIGGER_CLICK: u32 = 0x0080_0000;
    pub const LEFT_JOYSTICK_TOUCH: u32 = 0x0100_0000;
    pub const LEFT_TOUCHPAD_TOUCH: u32 = 0x0200_0000;
    pub const LEFT_TOUCHPAD_CLICK: u32 = 0x0400_0000;
    pub const LEFT_TRIGGER_CLICK: u32 = 0x0800_0000;
    pub const RIGHT_GRIP_TOUCH: u32 = 0x1000_0000;
    pub const LEFT_GRIP_TOUCH: u32 = 0x2000_0000;
};

const XboxButtons = struct {
    const DPAD_UP: u32 = 0x0001;
    const DPAD_DOWN: u32 = 0x0002;
    const DPAD_LEFT: u32 = 0x0004;
    const DPAD_RIGHT: u32 = 0x0008;
    const START: u32 = 0x0010;
    const BACK: u32 = 0x0020;
    const LEFT_STICK: u32 = 0x0040;
    const RIGHT_STICK: u32 = 0x0080;
    const LEFT_BUMPER: u32 = 0x0100;
    const RIGHT_BUMPER: u32 = 0x0200;
    const GUIDE: u32 = 0x0400;
    const A: u32 = 0x1000;
    const B: u32 = 0x2000;
    const X: u32 = 0x4000;
    const Y: u32 = 0x8000;
};

// Field layouts/scales: SDL src/joystick/hidapi/steam/controller_structs.h
// (TritonMTUNoQuat_t and TritonMTUNoQuat32TS_t).
pub const Touchpad = struct { x: i16, y: i16, pressure: u16 };
pub const Imu = struct {
    timestamp_us: u32,
    accel: [3]i16,
    gyro: [3]i16,
};

pub const State = struct {
    buttons: u32,
    left_trigger: i16,
    right_trigger: i16,
    left_stick_x: i16,
    left_stick_y: i16,
    right_stick_x: i16,
    right_stick_y: i16,
    pads: ?[2]Touchpad,
    imu: ?Imu,
};

pub fn mapTritonToXbox360(report: []const u8, out_packet: []u8) Error!void {
    if (out_packet.len < XBOX360_PACKET_SIZE) return error.OutputBufferTooSmall;

    const state = try parse(report);
    const buttons = mapButtons(state.buttons);

    putU32Le(out_packet, 0, buttons);
    out_packet[4] = scaleTrigger(state.left_trigger);
    out_packet[5] = scaleTrigger(state.right_trigger);
    putI16Le(out_packet, 6, state.left_stick_x);
    putI16Le(out_packet, 8, state.left_stick_y);
    putI16Le(out_packet, 10, state.right_stick_x);
    putI16Le(out_packet, 12, state.right_stick_y);
    @memset(out_packet[14..XBOX360_PACKET_SIZE], 0);
}

pub const LocalOptions = struct {
    // L4, L5, R4, R5. Zero leaves the grip unbound.
    grips: [4]u32 = .{ 0, 0, 0, 0 },
    right_pad_stick: bool = false,
    touch_gyro: bool = false,
    gyro_full_scale_dps: u32 = 180,
};

pub fn mapTritonToLocalXbox360(report: []const u8, out: []u8, options: LocalOptions) Error!void {
    const valid_buttons: u32 = 0xf7ff;
    for (options.grips) |mask| {
        if (mask & ~valid_buttons != 0) return error.InvalidMappingOptions;
    }
    if (options.gyro_full_scale_dps < 30 or options.gyro_full_scale_dps > 720) return error.InvalidMappingOptions;
    try mapTritonToXbox360(report, out);
    const state = try parse(report);
    var buttons = u32Le(out, 0);
    for ([_]u32{ Buttons.L4, Buttons.L5, Buttons.R4, Buttons.R5 }, options.grips) |grip, mapped| {
        if (has(state.buttons, grip)) buttons |= mapped;
    }
    putU32Le(out, 0, buttons);
    var x: i32 = state.right_stick_x;
    var y: i32 = state.right_stick_y;
    const touching = has(state.buttons, Buttons.RIGHT_TOUCHPAD_TOUCH);
    if (options.right_pad_stick and touching) {
        if (state.pads) |pads| {
            x = pads[1].x;
            y = pads[1].y;
        }
    }
    if (options.touch_gyro and touching) {
        if (state.imu) |imu| {
            // Triton gyro: +/-2000 degrees/s. Device-local yaw (-Y) and
            // pitch (X), not orientation integration; release touch to clutch.
            const scale: i32 = @intCast(options.gyro_full_scale_dps);
            x += @divTrunc(-@as(i32, imu.gyro[1]) * 2000, scale);
            y += @divTrunc(@as(i32, imu.gyro[0]) * 2000, scale);
        }
    }
    putI16Le(out, 10, @intCast(std.math.clamp(x, -32768, 32767)));
    putI16Le(out, 12, @intCast(std.math.clamp(y, -32768, 32767)));
}

pub fn parse(report: []const u8) Error!State {
    if (report.len < MIN_BASIC_REPORT_BYTES) return error.ReportTooShort;

    const report_id = report[0];
    if (report_id != REPORT_ID_USB_STATE and report_id != REPORT_ID_BLE_STATE and report_id != REPORT_ID_BLE_TIMESTAMP_STATE) {
        return error.UnsupportedReport;
    }

    const timestamped = report_id == REPORT_ID_BLE_TIMESTAMP_STATE;
    const pad_offset: usize = if (timestamped) 20 else 18;
    return .{
        .buttons = u32Le(report, 2),
        .left_trigger = i16Le(report, 6),
        .right_trigger = i16Le(report, 8),
        .left_stick_x = i16Le(report, 10),
        .left_stick_y = i16Le(report, 12),
        .right_stick_x = i16Le(report, 14),
        .right_stick_y = i16Le(report, 16),
        .pads = if (report.len >= pad_offset + 12) .{
            .{ .x = i16Le(report, pad_offset), .y = i16Le(report, pad_offset + 2), .pressure = @bitCast(i16Le(report, pad_offset + 4)) },
            .{ .x = i16Le(report, pad_offset + 6), .y = i16Le(report, pad_offset + 8), .pressure = @bitCast(i16Le(report, pad_offset + 10)) },
        } else null,
        .imu = if (report.len >= 46) .{
            .timestamp_us = if (timestamped) @as(u32, @as(u16, @bitCast(i16Le(report, 32)))) * 32 else u32Le(report, 30),
            .accel = .{ i16Le(report, 34), i16Le(report, 36), i16Le(report, 38) },
            .gyro = .{ i16Le(report, 40), i16Le(report, 42), i16Le(report, 44) },
        } else null,
    };
}

fn mapButtons(buttons: u32) u32 {
    var out: u32 = 0;
    if (has(buttons, Buttons.A)) out |= XboxButtons.A;
    if (has(buttons, Buttons.B)) out |= XboxButtons.B;
    if (has(buttons, Buttons.X)) out |= XboxButtons.X;
    if (has(buttons, Buttons.Y)) out |= XboxButtons.Y;
    if (has(buttons, Buttons.L)) out |= XboxButtons.LEFT_BUMPER;
    if (has(buttons, Buttons.R)) out |= XboxButtons.RIGHT_BUMPER;
    if (has(buttons, Buttons.L3)) out |= XboxButtons.LEFT_STICK;
    if (has(buttons, Buttons.R3)) out |= XboxButtons.RIGHT_STICK;
    if (has(buttons, Buttons.MENU)) out |= XboxButtons.START;
    if (has(buttons, Buttons.VIEW)) out |= XboxButtons.BACK;
    if (has(buttons, Buttons.STEAM)) out |= XboxButtons.GUIDE;
    if (has(buttons, Buttons.DPAD_UP)) out |= XboxButtons.DPAD_UP;
    if (has(buttons, Buttons.DPAD_DOWN)) out |= XboxButtons.DPAD_DOWN;
    if (has(buttons, Buttons.DPAD_LEFT)) out |= XboxButtons.DPAD_LEFT;
    if (has(buttons, Buttons.DPAD_RIGHT)) out |= XboxButtons.DPAD_RIGHT;
    return out;
}

fn has(buttons: u32, mask: u32) bool {
    return (buttons & mask) != 0;
}

fn scaleTrigger(raw: i16) u8 {
    const clamped: u32 = if (raw < 0) 0 else @min(@as(u32, @intCast(raw)), 32767);
    return @intCast((clamped * 255 + 16383) / 32767);
}

fn u32Le(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}

fn i16Le(bytes: []const u8, offset: usize) i16 {
    const value = @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
    return @bitCast(value);
}

fn putU32Le(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
    bytes[offset + 2] = @truncate(value >> 16);
    bytes[offset + 3] = @truncate(value >> 24);
}

fn putI16Le(bytes: []u8, offset: usize, value: i16) void {
    const bits: u16 = @bitCast(value);
    bytes[offset] = @truncate(bits);
    bytes[offset + 1] = @truncate(bits >> 8);
}

test "maps current and legacy BLE reports to Xbox 360 packets" {
    for ([_]u8{ REPORT_ID_BLE_STATE, REPORT_ID_BLE_TIMESTAMP_STATE }) |report_id| {
        var report: [64]u8 = @splat(0);
        report[0] = report_id;
        putU32Le(&report, 2, Buttons.A | Buttons.DPAD_UP | Buttons.MENU);
        putI16Le(&report, 6, 0);
        putI16Le(&report, 8, 32767);
        putI16Le(&report, 10, 100);
        putI16Le(&report, 12, 0);
        putI16Le(&report, 14, -200);
        putI16Le(&report, 16, 1234);

        var packet: [XBOX360_PACKET_SIZE]u8 = @splat(0xaa);
        try mapTritonToXbox360(&report, &packet);

        const expected_buttons = XboxButtons.A | XboxButtons.DPAD_UP | XboxButtons.START;
        try std.testing.expectEqual(@as(u32, expected_buttons), u32Le(&packet, 0));
        try std.testing.expectEqual(@as(u8, 0), packet[4]);
        try std.testing.expectEqual(@as(u8, 255), packet[5]);
        try std.testing.expectEqual(@as(i16, 100), i16Le(&packet, 6));
        try std.testing.expectEqual(@as(i16, 0), i16Le(&packet, 8));
        try std.testing.expectEqual(@as(i16, -200), i16Le(&packet, 10));
        try std.testing.expectEqual(@as(i16, 1234), i16Le(&packet, 12));
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0, 0 }, packet[14..]);
    }
}

test "optional pads and IMU require complete fields and preserve timestamp units" {
    for ([_]u8{ REPORT_ID_USB_STATE, REPORT_ID_BLE_STATE, REPORT_ID_BLE_TIMESTAMP_STATE }) |id| {
        var report: [46]u8 = @splat(0);
        report[0] = id;
        if (id == REPORT_ID_BLE_TIMESTAMP_STATE) {
            std.mem.writeInt(u16, report[32..34], 65535, .little);
        } else {
            std.mem.writeInt(u32, report[30..34], 0xfedcba98, .little);
        }
        for (MIN_BASIC_REPORT_BYTES..report.len) |length| {
            const state = try parse(report[0..length]);
            try std.testing.expect(state.imu == null);
            try std.testing.expectEqual(length >= (if (id == REPORT_ID_BLE_TIMESTAMP_STATE) @as(usize, 32) else 30), state.pads != null);
        }
        const state = try parse(&report);
        try std.testing.expectEqual(if (id == REPORT_ID_BLE_TIMESTAMP_STATE) @as(u32, 65535 * 32) else 0xfedcba98, state.imu.?.timestamp_us);
    }
}

test "shared Kotlin and Zig report vectors" {
    var lines = std.mem.tokenizeScalar(u8, @embedFile("testdata/triton-state-vectors.tsv"), '\n');
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        var storage: [64]u8 = undefined;
        const report = try std.fmt.hexToBytes(&storage, fields.next().?);
        const state = try parse(report);
        const actual = [_]i64{ state.buttons, state.left_stick_x, state.left_stick_y,
            state.right_stick_x, state.right_stick_y, state.pads.?[0].x, state.pads.?[0].y,
            state.pads.?[1].x, state.pads.?[1].y, state.imu.?.timestamp_us };
        for (actual) |value| try std.testing.expectEqual(try std.fmt.parseInt(i64, fields.next().?, 10), value);
        try std.testing.expect(fields.next() == null);
    }
}

test "Xbox 360 mapper rejects invalid buffers" {
    var packet: [XBOX360_PACKET_SIZE]u8 = @splat(0);
    try std.testing.expectError(error.ReportTooShort, mapTritonToXbox360(&[_]u8{0x45}, &packet));

    var report: [18]u8 = @splat(0);
    report[0] = 0x99;
    try std.testing.expectError(error.UnsupportedReport, mapTritonToXbox360(&report, &packet));
    try std.testing.expectError(error.OutputBufferTooSmall, mapTritonToXbox360(&report, packet[0..19]));
}
