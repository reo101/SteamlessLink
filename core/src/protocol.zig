//! SteamlessLink raw UHID wire protocol.
//!
//! Every frame is `u8 frame_type`, `u16be payload_length`, payload bytes.
//!
//! Controller side -> UHID server:
//! - FRAME_INPUT: numbered HID input report (normally 0x47 or legacy 0x45 + 45 bytes)
//! - FRAME_GET_REPORT_REPLY: u32le request_id, u16le errno, report bytes
//! - FRAME_SET_REPORT_REPLY: u32le request_id, u16le errno
//! - FRAME_DEVICE_INFO: HID bus, vendor/product IDs, and report descriptor;
//!   it must precede input and lets the host mirror the physical HID device
//! - FRAME_GET_IROH_TICKET: empty one-shot request for the host's Iroh ticket
//!
//! UHID server -> controller side:
//! - FRAME_OUTPUT: u8 uhid_report_type, HID output report bytes
//! - FRAME_GET_REPORT: u32le request_id, u8 report_number, u8 report_type
//! - FRAME_SET_REPORT: u32le request_id, u8 report_number, u8 report_type, report bytes
//! - FRAME_IROH_TICKET: endpoint ticket bytes

const std = @import("std");
const Io = std.Io;

pub const FRAME_INPUT: u8 = 0x01;
pub const FRAME_GET_REPORT_REPLY: u8 = 0x02;
pub const FRAME_SET_REPORT_REPLY: u8 = 0x03;
pub const FRAME_DEVICE_INFO: u8 = 0x04;
pub const FRAME_GET_IROH_TICKET: u8 = 0x05;
pub const FRAME_OUTPUT: u8 = 0x81;
pub const FRAME_GET_REPORT: u8 = 0x82;
pub const FRAME_SET_REPORT: u8 = 0x83;
pub const FRAME_IROH_TICKET: u8 = 0x85;
pub const MAX_FRAME_PAYLOAD = 65535;
pub const MAX_REPORT_DESCRIPTOR_SIZE = 4096;
pub const DEVICE_INFO_HEADER_SIZE = 10;

pub const DeviceInfo = struct {
    bus: u32,
    vendor: u16,
    product: u16,
    descriptor: []const u8,
};

pub const Frame = struct {
    frame_type: u8,
    payload: []const u8,
};

pub fn encodeDeviceInfo(info: DeviceInfo, out: []u8) ?[]const u8 {
    if (info.descriptor.len == 0 or info.descriptor.len > MAX_REPORT_DESCRIPTOR_SIZE) return null;
    const size = DEVICE_INFO_HEADER_SIZE + info.descriptor.len;
    if (out.len < size) return null;
    std.mem.writeInt(u32, out[0..4], info.bus, .little);
    std.mem.writeInt(u16, out[4..6], info.vendor, .little);
    std.mem.writeInt(u16, out[6..8], info.product, .little);
    std.mem.writeInt(u16, out[8..10], @intCast(info.descriptor.len), .little);
    @memcpy(out[DEVICE_INFO_HEADER_SIZE..size], info.descriptor);
    return out[0..size];
}

pub fn decodeDeviceInfo(payload: []const u8) ?DeviceInfo {
    if (payload.len < DEVICE_INFO_HEADER_SIZE) return null;
    const descriptor_len = std.mem.readInt(u16, payload[8..10], .little);
    const size = DEVICE_INFO_HEADER_SIZE + @as(usize, descriptor_len);
    if (descriptor_len == 0 or descriptor_len > MAX_REPORT_DESCRIPTOR_SIZE or payload.len != size) return null;
    return .{
        .bus = std.mem.readInt(u32, payload[0..4], .little),
        .vendor = std.mem.readInt(u16, payload[4..6], .little),
        .product = std.mem.readInt(u16, payload[6..8], .little),
        .descriptor = payload[DEVICE_INFO_HEADER_SIZE..],
    };
}

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

test "device info round trip" {
    const descriptor = [_]u8{ 1, 2, 3, 4 };
    var encoded: [DEVICE_INFO_HEADER_SIZE + descriptor.len]u8 = undefined;
    const payload = encodeDeviceInfo(.{
        .bus = 3,
        .vendor = 0x28de,
        .product = 0x1302,
        .descriptor = &descriptor,
    }, &encoded).?;
    const info = decodeDeviceInfo(payload).?;
    try std.testing.expectEqual(@as(u32, 3), info.bus);
    try std.testing.expectEqual(@as(u16, 0x28de), info.vendor);
    try std.testing.expectEqual(@as(u16, 0x1302), info.product);
    try std.testing.expectEqualSlices(u8, &descriptor, info.descriptor);
}

test "truncated frame reads as end of stream" {
    var wire: [64]u8 = undefined;
    var writer = Io.Writer.fixed(&wire);
    try sendFrame(&writer, FRAME_OUTPUT, &.{ 1, 2, 3, 4 });

    var reader = Io.Reader.fixed(writer.buffered()[0..5]);
    var payload_buf: [MAX_FRAME_PAYLOAD]u8 = undefined;
    try std.testing.expectEqual(@as(?Frame, null), try readFrame(&reader, &payload_buf));
}
