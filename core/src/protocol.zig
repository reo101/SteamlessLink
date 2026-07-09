//! SteamlessLink raw UHID wire protocol.
//!
//! Every frame is `u8 frame_type`, `u16be payload_length`, payload bytes.
//!
//! Controller side -> UHID server:
//! - FRAME_INPUT: numbered HID input report (normally 0x45 + 45 bytes)
//! - FRAME_GET_REPORT_REPLY: u32le request_id, u16le errno, report bytes
//! - FRAME_SET_REPORT_REPLY: u32le request_id, u16le errno
//!
//! UHID server -> controller side:
//! - FRAME_OUTPUT: u8 uhid_report_type, HID output report bytes
//! - FRAME_GET_REPORT: u32le request_id, u8 report_number, u8 report_type
//! - FRAME_SET_REPORT: u32le request_id, u8 report_number, u8 report_type, report bytes

const std = @import("std");
const Io = std.Io;

pub const FRAME_INPUT: u8 = 0x01;
pub const FRAME_GET_REPORT_REPLY: u8 = 0x02;
pub const FRAME_SET_REPORT_REPLY: u8 = 0x03;
pub const FRAME_OUTPUT: u8 = 0x81;
pub const FRAME_GET_REPORT: u8 = 0x82;
pub const FRAME_SET_REPORT: u8 = 0x83;
pub const MAX_FRAME_PAYLOAD = 65535;

pub const Frame = struct {
    frame_type: u8,
    payload: []const u8,
};

/// Writes one frame and flushes so it hits the wire immediately.
pub fn sendFrame(w: *Io.Writer, frame_type: u8, payload: []const u8) Io.Writer.Error!void {
    const safe_len = @min(payload.len, MAX_FRAME_PAYLOAD);
    try w.writeAll(&.{
        frame_type,
        @intCast((safe_len >> 8) & 0xff),
        @intCast(safe_len & 0xff),
    });
    try w.writeAll(payload[0..safe_len]);
    try w.flush();
}

/// Returns null when the stream ends (cleanly or mid-frame).
pub fn readFrame(r: *Io.Reader, payload_buf: *[MAX_FRAME_PAYLOAD]u8) error{ReadFailed}!?Frame {
    var header: [3]u8 = undefined;
    r.readSliceAll(&header) catch |err| switch (err) {
        error.EndOfStream => return null,
        error.ReadFailed => return error.ReadFailed,
    };
    const size = (@as(usize, header[1]) << 8) | header[2];
    r.readSliceAll(payload_buf[0..size]) catch |err| switch (err) {
        error.EndOfStream => return null,
        error.ReadFailed => return error.ReadFailed,
    };
    return .{ .frame_type = header[0], .payload = payload_buf[0..size] };
}

test "frame round trip" {
    var wire: [64]u8 = undefined;
    var writer = Io.Writer.fixed(&wire);

    const payload = [_]u8{ 0x45, 1, 2, 3, 4, 5 };
    try sendFrame(&writer, FRAME_INPUT, &payload);
    try sendFrame(&writer, FRAME_SET_REPORT_REPLY, &.{});

    var reader = Io.Reader.fixed(writer.buffered());
    var payload_buf: [MAX_FRAME_PAYLOAD]u8 = undefined;

    const first = (try readFrame(&reader, &payload_buf)).?;
    try std.testing.expectEqual(FRAME_INPUT, first.frame_type);
    try std.testing.expectEqualSlices(u8, &payload, first.payload);

    const second = (try readFrame(&reader, &payload_buf)).?;
    try std.testing.expectEqual(FRAME_SET_REPORT_REPLY, second.frame_type);
    try std.testing.expectEqual(@as(usize, 0), second.payload.len);

    try std.testing.expectEqual(@as(?Frame, null), try readFrame(&reader, &payload_buf));
}

test "truncated frame reads as end of stream" {
    var wire: [64]u8 = undefined;
    var writer = Io.Writer.fixed(&wire);
    try sendFrame(&writer, FRAME_OUTPUT, &.{ 1, 2, 3, 4 });

    var reader = Io.Reader.fixed(writer.buffered()[0..5]);
    var payload_buf: [MAX_FRAME_PAYLOAD]u8 = undefined;
    try std.testing.expectEqual(@as(?Frame, null), try readFrame(&reader, &payload_buf));
}
