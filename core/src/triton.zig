const std = @import("std");

pub const Error = error{
    ReportTooShort,
    UnsupportedReport,
    OutputBufferTooSmall,
};

pub const REPORT_ID_USB_STATE = 0x42;
pub const REPORT_ID_BLE_STATE = 0x45;
pub const REPORT_ID_BLE_TIMESTAMP_STATE = 0x47;
pub const MIN_BASIC_REPORT_BYTES = 18;
pub const XBOX360_PACKET_SIZE = 20;

pub const Buttons = struct {
    pub const A: u32 = 0x0000_0001;
    pub const B: u32 = 0x0000_0002;
    pub const X: u32 = 0x0000_0004;
    pub const Y: u32 = 0x0000_0008;
    pub const R3: u32 = 0x0000_0020;
    pub const VIEW: u32 = 0x0000_0040;
    pub const R: u32 = 0x0000_0200;
    pub const DPAD_DOWN: u32 = 0x0000_0400;
    pub const DPAD_RIGHT: u32 = 0x0000_0800;
    pub const DPAD_LEFT: u32 = 0x0000_1000;
    pub const DPAD_UP: u32 = 0x0000_2000;
    pub const MENU: u32 = 0x0000_4000;
    pub const L3: u32 = 0x0000_8000;
    pub const STEAM: u32 = 0x0001_0000;
    pub const L: u32 = 0x0008_0000;
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

pub const State = struct {
    buttons: u32,
    left_trigger: i16,
    right_trigger: i16,
    left_stick_x: i16,
    left_stick_y: i16,
    right_stick_x: i16,
    right_stick_y: i16,
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

pub fn parse(report: []const u8) Error!State {
    if (report.len < MIN_BASIC_REPORT_BYTES) return error.ReportTooShort;

    const report_id = report[0];
    if (report_id != REPORT_ID_USB_STATE and report_id != REPORT_ID_BLE_STATE and report_id != REPORT_ID_BLE_TIMESTAMP_STATE) {
        return error.UnsupportedReport;
    }

    return .{
        .buttons = u32Le(report, 2),
        .left_trigger = i16Le(report, 6),
        .right_trigger = i16Le(report, 8),
        .left_stick_x = i16Le(report, 10),
        .left_stick_y = i16Le(report, 12),
        .right_stick_x = i16Le(report, 14),
        .right_stick_y = i16Le(report, 16),
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
        var report = [_]u8{0} ** 64;
        report[0] = report_id;
        putU32Le(&report, 2, Buttons.A | Buttons.DPAD_UP | Buttons.MENU);
        putI16Le(&report, 6, 0);
        putI16Le(&report, 8, 32767);
        putI16Le(&report, 10, 100);
        putI16Le(&report, 12, 0);
        putI16Le(&report, 14, -200);
        putI16Le(&report, 16, 1234);

        var packet = [_]u8{0xaa} ** XBOX360_PACKET_SIZE;
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

test "Xbox 360 mapper rejects invalid buffers" {
    var packet = [_]u8{0} ** XBOX360_PACKET_SIZE;
    try std.testing.expectError(error.ReportTooShort, mapTritonToXbox360(&[_]u8{0x45}, &packet));

    var report = [_]u8{0} ** 18;
    report[0] = 0x99;
    try std.testing.expectError(error.UnsupportedReport, mapTritonToXbox360(&report, &packet));
    try std.testing.expectError(error.OutputBufferTooSmall, mapTritonToXbox360(&report, packet[0..19]));
}
