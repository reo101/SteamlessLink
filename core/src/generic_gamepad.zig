//! Standard HID Game Pad profile for host-side UHID devices.

const std = @import("std");
const triton = @import("triton.zig");

pub const Error = triton.Error;

pub const BUS_USB: u32 = 0x0003;
pub const VENDOR_ID: u16 = 0x0000;
pub const PRODUCT_ID: u16 = 0x0000;
pub const NAME = "SteamlessLink Generic Gamepad";
pub const INPUT_REPORT_ID: u8 = 0x01;
pub const INPUT_REPORT_SIZE = 10;

/// One numbered input report: 15 standard buttons, hat switch, two sticks,
/// and two unsigned triggers. It deliberately has no output/feature reports.
pub const REPORT_DESCRIPTOR = [_]u8{
    0x05, 0x01, // Usage Page (Generic Desktop)
    0x09, 0x05, // Usage (Game Pad)
    0xa1, 0x01, // Collection (Application)
    0x85, INPUT_REPORT_ID, // Report ID
    0x05, 0x09, // Usage Page (Button)
    0x19, 0x01, // Usage Minimum (Button 1)
    0x29, 0x0f, // Usage Maximum (Button 15)
    0x15, 0x00, // Logical Minimum (0)
    0x25, 0x01, // Logical Maximum (1)
    0x75, 0x01, // Report Size (1)
    0x95, 0x0f, // Report Count (15)
    0x81, 0x02, // Input (Data,Var,Abs)
    0x75, 0x01, // Report Size (1)
    0x95, 0x01, // Report Count (1)
    0x81, 0x03, // Input (Const,Var,Abs) padding
    0x05, 0x01, // Usage Page (Generic Desktop)
    0x09, 0x39, // Usage (Hat switch)
    0x15, 0x00, // Logical Minimum (0)
    0x25, 0x07, // Logical Maximum (7)
    0x35, 0x00, // Physical Minimum (0)
    0x46, 0x3b, 0x01, // Physical Maximum (315)
    0x65, 0x14, // Unit (English Rotation, angular position)
    0x75, 0x04, // Report Size (4)
    0x95, 0x01, // Report Count (1)
    0x81, 0x42, // Input (Data,Var,Abs,Null)
    0x75, 0x04, // Report Size (4)
    0x95, 0x01, // Report Count (1)
    0x81, 0x03, // Input (Const,Var,Abs) padding
    0x65, 0x00, // Unit (None)
    0x15, 0x00, // Logical Minimum (0)
    0x26, 0xff, 0x00, // Logical Maximum (255)
    0x75, 0x08, // Report Size (8)
    0x95, 0x06, // Report Count (6)
    0x09, 0x30, // Usage (X)
    0x09, 0x31, // Usage (Y)
    0x09, 0x33, // Usage (Rx)
    0x09, 0x34, // Usage (Ry)
    0x09, 0x32, // Usage (Z)
    0x09, 0x35, // Usage (Rz)
    0x81, 0x02, // Input (Data,Var,Abs)
    0xc0, // End Collection
};

const GenericButtons = struct {
    const SOUTH: u16 = 1 << 0;
    const EAST: u16 = 1 << 1;
    const NORTH: u16 = 1 << 3;
    const WEST: u16 = 1 << 4;
    const LEFT_BUMPER: u16 = 1 << 6;
    const RIGHT_BUMPER: u16 = 1 << 7;
    const SELECT: u16 = 1 << 10;
    const START: u16 = 1 << 11;
    const MODE: u16 = 1 << 12;
    const LEFT_STICK: u16 = 1 << 13;
    const RIGHT_STICK: u16 = 1 << 14;
};

pub fn mapTritonToInput(report: []const u8, out_report: []u8) Error!void {
    if (out_report.len < INPUT_REPORT_SIZE) return error.OutputBufferTooSmall;

    const state = try triton.parse(report);
    @memset(out_report[0..INPUT_REPORT_SIZE], 0);
    out_report[0] = INPUT_REPORT_ID;
    std.mem.writeInt(u16, out_report[1..3], mapButtons(state.buttons), .little);
    out_report[3] = mapHat(state.buttons);
    out_report[4] = scaleAxis(state.left_stick_x);
    out_report[5] = scaleAxis(state.left_stick_y);
    out_report[6] = scaleAxis(state.right_stick_x);
    out_report[7] = scaleAxis(state.right_stick_y);
    out_report[8] = scaleTrigger(state.left_trigger);
    out_report[9] = scaleTrigger(state.right_trigger);
}

fn mapButtons(buttons: u32) u16 {
    var out: u16 = 0;
    if (has(buttons, triton.Buttons.A)) out |= GenericButtons.SOUTH;
    if (has(buttons, triton.Buttons.B)) out |= GenericButtons.EAST;
    if (has(buttons, triton.Buttons.X)) out |= GenericButtons.WEST;
    if (has(buttons, triton.Buttons.Y)) out |= GenericButtons.NORTH;
    if (has(buttons, triton.Buttons.L)) out |= GenericButtons.LEFT_BUMPER;
    if (has(buttons, triton.Buttons.R)) out |= GenericButtons.RIGHT_BUMPER;
    if (has(buttons, triton.Buttons.VIEW)) out |= GenericButtons.SELECT;
    if (has(buttons, triton.Buttons.MENU)) out |= GenericButtons.START;
    if (has(buttons, triton.Buttons.STEAM)) out |= GenericButtons.MODE;
    if (has(buttons, triton.Buttons.L3)) out |= GenericButtons.LEFT_STICK;
    if (has(buttons, triton.Buttons.R3)) out |= GenericButtons.RIGHT_STICK;
    return out;
}

fn mapHat(buttons: u32) u8 {
    const up = has(buttons, triton.Buttons.DPAD_UP);
    const down = has(buttons, triton.Buttons.DPAD_DOWN);
    const left = has(buttons, triton.Buttons.DPAD_LEFT);
    const right = has(buttons, triton.Buttons.DPAD_RIGHT);

    if (up and right and !down and !left) return 1;
    if (right and !up and !down and !left) return 2;
    if (down and right and !up and !left) return 3;
    if (down and !up and !left and !right) return 4;
    if (down and left and !up and !right) return 5;
    if (left and !up and !down and !right) return 6;
    if (up and left and !down and !right) return 7;
    if (up and !down and !left and !right) return 0;
    return 8;
}

fn has(buttons: u32, mask: u32) bool {
    return (buttons & mask) != 0;
}

fn scaleAxis(raw: i16) u8 {
    const shifted: u32 = @intCast(@as(i32, raw) + 32768);
    return @intCast((shifted * 255 + 32767) / 65535);
}

fn scaleTrigger(raw: i16) u8 {
    const clamped: u32 = if (raw < 0) 0 else @min(@as(u32, @intCast(raw)), 32767);
    return @intCast((clamped * 255 + 16383) / 32767);
}

fn putI16Le(bytes: []u8, offset: usize, value: i16) void {
    const bits: u16 = @bitCast(value);
    bytes[offset] = @truncate(bits);
    bytes[offset + 1] = @truncate(bits >> 8);
}

test "maps Triton reports to a standard HID gamepad report" {
    var report = [_]u8{0} ** 18;
    report[0] = triton.REPORT_ID_BLE_STATE;
    std.mem.writeInt(u32, report[2..6], triton.Buttons.A | triton.Buttons.X | triton.Buttons.L | triton.Buttons.R | triton.Buttons.VIEW | triton.Buttons.MENU | triton.Buttons.STEAM | triton.Buttons.L3 | triton.Buttons.DPAD_UP | triton.Buttons.DPAD_RIGHT, .little);
    putI16Le(&report, 6, 0);
    putI16Le(&report, 8, 32767);
    putI16Le(&report, 10, -32768);
    putI16Le(&report, 12, 32767);
    putI16Le(&report, 14, 0);
    putI16Le(&report, 16, -32768);

    var packet = [_]u8{0xaa} ** INPUT_REPORT_SIZE;
    try mapTritonToInput(&report, &packet);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0xd1, 0x3c, 0x01, 0x00, 0xff, 0x80, 0x00, 0x00, 0xff }, &packet);
}

test "generic gamepad rejects invalid buffers" {
    var packet = [_]u8{0} ** INPUT_REPORT_SIZE;
    try std.testing.expectError(error.ReportTooShort, mapTritonToInput(&[_]u8{0x45}, &packet));

    var report = [_]u8{0} ** 18;
    report[0] = 0x99;
    try std.testing.expectError(error.UnsupportedReport, mapTritonToInput(&report, &packet));
    try std.testing.expectError(error.OutputBufferTooSmall, mapTritonToInput(&report, packet[0 .. INPUT_REPORT_SIZE - 1]));
}

test "descriptor is a numbered gamepad application collection" {
    try std.testing.expectEqualSlices(u8, &.{ 0x05, 0x01, 0x09, 0x05, 0xa1, 0x01, 0x85, INPUT_REPORT_ID }, REPORT_DESCRIPTOR[0..8]);
    try std.testing.expectEqual(@as(u8, 0xc0), REPORT_DESCRIPTOR[REPORT_DESCRIPTOR.len - 1]);
}
