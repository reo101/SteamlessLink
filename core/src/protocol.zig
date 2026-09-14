//! SteamlessLink raw UHID wire protocol.
//!
//! `generate_kotlin_protocol.zig` emits Android constants from this module.
//!
//! Every frame is `u8 frame_type`, `u16be payload_length`, payload bytes.
//!
//! Controller side -> UHID server:
//! - FRAME_INPUT: numbered HID input report (normally 0x47 or legacy 0x45 + 45 bytes)
//! - FRAME_GET_REPORT_REPLY: u32le request_id, u16le errno, report bytes
//! - FRAME_SET_REPORT_REPLY: u32le request_id, u16le errno
//! - FRAME_DEVICE_INFO: HID bus, vendor/product IDs, report descriptor, and an
//!   optional host-visible name; it must precede input and lets the host mirror
//!   the physical HID device
//! - FRAME_GET_IROH_TICKET: empty one-shot request for the host's Iroh ticket
//!
//! UHID server -> controller side:
//! - FRAME_OUTPUT: u8 uhid_report_type, HID output report bytes
//! - FRAME_GET_REPORT: u32le request_id, u8 report_number, u8 report_type
//! - FRAME_SET_REPORT: u32le request_id, u8 report_number, u8 report_type, report bytes
//! - FRAME_IROH_TICKET: endpoint ticket bytes

const std = @import("std");
const Io = std.Io;

pub const FrameType = enum(u8) {
    input = 0x01,
    get_report_reply = 0x02,
    set_report_reply = 0x03,
    device_info = 0x04,
    get_iroh_ticket = 0x05,
    device_frame = 0x06,
    device_bundle = 0x07,
    output = 0x81,
    get_report = 0x82,
    set_report = 0x83,
    iroh_ticket = 0x85,
    device_bundle_ready = 0x87,
    // Preserve unknown wire values so receivers can ignore future frame types.
    _,
};
pub const DeviceFrameHeader = packed struct { device: u8, frame_type: FrameType };
pub const DeviceBundleHeader = packed struct { count: u8 };
pub const DeviceBundleEntry = packed struct { info_length: u16 };
pub const DEVICE_FRAME_HEADER_SIZE = @divExact(@bitSizeOf(DeviceFrameHeader), 8);
pub const DEVICE_FRAME_TYPE_OFFSET = @divExact(@bitOffsetOf(DeviceFrameHeader, "frame_type"), 8);
pub const DEVICE_BUNDLE_HEADER_SIZE = @divExact(@bitSizeOf(DeviceBundleHeader), 8);
pub const DEVICE_BUNDLE_ENTRY_SIZE = @divExact(@bitSizeOf(DeviceBundleEntry), 8);
pub const MAX_DEVICES = 4;
pub const FRAME_HEADER_SIZE = 3;
pub const MAX_FRAME_PAYLOAD = 65535;
pub const MAX_REPORT_DESCRIPTOR_SIZE = 4096;
pub const MAX_DEVICE_NAME_SIZE = 127;
pub const DEVICE_INFO_HEADER_SIZE = 10;

pub const DeviceInfo = struct {
    bus: u32,
    vendor: u16,
    product: u16,
    descriptor: []const u8,
    name: []const u8 = &.{},
};

/// Initial bundle: count, then repeated u16le length + DeviceInfo. No trailing bytes.
pub fn decodeDeviceBundle(payload: []const u8, out: *[MAX_DEVICES]DeviceInfo) ?[]DeviceInfo {
    if (payload.len == 0 or payload[0] == 0 or payload[0] > MAX_DEVICES) return null;
    var offset: usize = DEVICE_BUNDLE_HEADER_SIZE;
    for (out[0..payload[0]]) |*info| {
        if (payload.len - offset < DEVICE_BUNDLE_ENTRY_SIZE) return null;
        const len = std.mem.readInt(@FieldType(DeviceBundleEntry, "info_length"), payload[offset..][0..DEVICE_BUNDLE_ENTRY_SIZE], .little);
        offset += DEVICE_BUNDLE_ENTRY_SIZE;
        if (len > payload.len - offset) return null;
        info.* = decodeDeviceInfo(payload[offset..][0..len]) orelse return null;
        if (info.bus > std.math.maxInt(u16)) return null;
        offset += len;
    }
    if (offset != payload.len) return null;
    return out[0..payload[0]];
}

pub const Frame = struct {
    frame_type: FrameType,
    payload: []const u8,
};

pub const FrameHeader = struct {
    frame_type: FrameType,
    payload_len: usize,
};

pub fn encodeFrameHeader(out: *[FRAME_HEADER_SIZE]u8, frame_type: FrameType, payload_len: usize) usize {
    const safe_len: usize = @min(payload_len, MAX_FRAME_PAYLOAD);
    out.* = .{
        @intFromEnum(frame_type),
        @intCast((safe_len >> 8) & 0xff),
        @intCast(safe_len & 0xff),
    };
    return safe_len;
}

pub fn decodeFrameHeader(header: []const u8) ?FrameHeader {
    if (header.len != FRAME_HEADER_SIZE) return null;
    return .{
        .frame_type = @enumFromInt(header[0]),
        .payload_len = (@as(usize, header[1]) << 8) | header[2],
    };
}

pub fn encodeDeviceInfo(info: DeviceInfo, out: []u8) ?[]const u8 {
    if (info.descriptor.len == 0 or info.descriptor.len > MAX_REPORT_DESCRIPTOR_SIZE) return null;
    if (info.name.len > MAX_DEVICE_NAME_SIZE or std.mem.indexOfScalar(u8, info.name, 0) != null or !std.unicode.utf8ValidateSlice(info.name)) return null;

    const descriptor_end = DEVICE_INFO_HEADER_SIZE + info.descriptor.len;
    const extension_size: usize = if (info.name.len == 0) 0 else 1 + info.name.len;
    const size = descriptor_end + extension_size;
    if (out.len < size) return null;

    std.mem.writeInt(u32, out[0..4], info.bus, .little);
    std.mem.writeInt(u16, out[4..6], info.vendor, .little);
    std.mem.writeInt(u16, out[6..8], info.product, .little);
    std.mem.writeInt(u16, out[8..10], @intCast(info.descriptor.len), .little);
    @memcpy(out[DEVICE_INFO_HEADER_SIZE..descriptor_end], info.descriptor);
    if (info.name.len != 0) {
        out[descriptor_end] = @intCast(info.name.len);
        @memcpy(out[descriptor_end + 1 .. size], info.name);
    }
    return out[0..size];
}

pub fn decodeDeviceInfo(payload: []const u8) ?DeviceInfo {
    if (payload.len < DEVICE_INFO_HEADER_SIZE) return null;
    const descriptor_len = std.mem.readInt(u16, payload[8..10], .little);
    const descriptor_end = DEVICE_INFO_HEADER_SIZE + @as(usize, descriptor_len);
    if (descriptor_len == 0 or descriptor_len > MAX_REPORT_DESCRIPTOR_SIZE or payload.len < descriptor_end) return null;

    var name: []const u8 = &.{};
    if (payload.len != descriptor_end) {
        if (payload.len < descriptor_end + 1) return null;
        const name_len = payload[descriptor_end];
        const size = descriptor_end + 1 + @as(usize, name_len);
        if (name_len == 0 or name_len > MAX_DEVICE_NAME_SIZE or payload.len != size) return null;
        name = payload[descriptor_end + 1 .. size];
        if (std.mem.indexOfScalar(u8, name, 0) != null or !std.unicode.utf8ValidateSlice(name)) return null;
    }

    return .{
        .bus = std.mem.readInt(u32, payload[0..4], .little),
        .vendor = std.mem.readInt(u16, payload[4..6], .little),
        .product = std.mem.readInt(u16, payload[6..8], .little),
        .descriptor = payload[DEVICE_INFO_HEADER_SIZE..descriptor_end],
        .name = name,
    };
}

/// Writes one frame and flushes so it hits the wire immediately.
pub fn sendFrame(w: *Io.Writer, frame_type: FrameType, payload: []const u8) Io.Writer.Error!void {
    var header: [FRAME_HEADER_SIZE]u8 = undefined;
    const safe_len = encodeFrameHeader(&header, frame_type, payload.len);
    try w.writeAll(&header);
    try w.writeAll(payload[0..safe_len]);
    try w.flush();
}

/// Returns null when the stream ends (cleanly or mid-frame).
pub fn readFrame(r: *Io.Reader, payload_buf: *[MAX_FRAME_PAYLOAD]u8) error{ReadFailed}!?Frame {
    var header: [FRAME_HEADER_SIZE]u8 = undefined;
    r.readSliceAll(&header) catch |err| switch (err) {
        error.EndOfStream => return null,
        error.ReadFailed => return error.ReadFailed,
    };
    const decoded = decodeFrameHeader(&header) orelse unreachable;
    r.readSliceAll(payload_buf[0..decoded.payload_len]) catch |err| switch (err) {
        error.EndOfStream => return null,
        error.ReadFailed => return error.ReadFailed,
    };
    return .{ .frame_type = decoded.frame_type, .payload = payload_buf[0..decoded.payload_len] };
}

test "frame round trip" {
    var wire: [64]u8 = undefined;
    var writer = Io.Writer.fixed(&wire);

    const payload = [_]u8{ 0x45, 1, 2, 3, 4, 5 };
    try sendFrame(&writer, .input, &payload);
    try sendFrame(&writer, .set_report_reply, &.{});

    var reader = Io.Reader.fixed(writer.buffered());
    var payload_buf: [MAX_FRAME_PAYLOAD]u8 = undefined;

    const first = (try readFrame(&reader, &payload_buf)).?;
    try std.testing.expectEqual(FrameType.input, first.frame_type);
    try std.testing.expectEqualSlices(u8, &payload, first.payload);

    const second = (try readFrame(&reader, &payload_buf)).?;
    try std.testing.expectEqual(FrameType.set_report_reply, second.frame_type);
    try std.testing.expectEqual(@as(usize, 0), second.payload.len);

    try std.testing.expectEqual(@as(?Frame, null), try readFrame(&reader, &payload_buf));
}

test "unknown frame types round trip without losing their wire value" {
    var storage: [64]u8 = undefined;
    var writer = Io.Writer.fixed(&storage);
    const unknown: FrameType = @enumFromInt(0xfe);
    try sendFrame(&writer, unknown, &.{ 0xab, 0xcd });
    try std.testing.expectEqualSlices(u8, &.{ 0xfe, 0, 2, 0xab, 0xcd }, writer.buffered());
    var reader = Io.Reader.fixed(writer.buffered());
    var payload_buf: [MAX_FRAME_PAYLOAD]u8 = undefined;
    const frame = (try readFrame(&reader, &payload_buf)).?;
    try std.testing.expectEqual(unknown, frame.frame_type);
    try std.testing.expectEqualSlices(u8, &.{ 0xab, 0xcd }, frame.payload);
    const known = switch (frame.frame_type) {
        .input, .output => true,
        else => false,
    };
    try std.testing.expect(!known);
}

test "frame header round trip" {
    var header: [FRAME_HEADER_SIZE]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 65535), encodeFrameHeader(&header, .output, 70000));
    const decoded = decodeFrameHeader(&header).?;
    try std.testing.expectEqual(FrameType.output, decoded.frame_type);
    try std.testing.expectEqual(@as(usize, 65535), decoded.payload_len);
    try std.testing.expectEqual(@as(?FrameHeader, null), decodeFrameHeader(&.{ 0x01, 0x00 }));
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
    try std.testing.expectEqualSlices(u8, &.{}, info.name);
}

test "device info carries an optional host-visible name" {
    const descriptor = [_]u8{ 1, 2, 3, 4 };
    const name = "SteamlessLink Generic Gamepad";
    var encoded: [DEVICE_INFO_HEADER_SIZE + descriptor.len + 1 + name.len]u8 = undefined;
    const payload = encodeDeviceInfo(.{
        .bus = 3,
        .vendor = 0,
        .product = 0,
        .descriptor = &descriptor,
        .name = name,
    }, &encoded).?;
    const info = decodeDeviceInfo(payload).?;
    try std.testing.expectEqualSlices(u8, &descriptor, info.descriptor);
    try std.testing.expectEqualSlices(u8, name, info.name);
}

test "device info rejects invalid name extensions" {
    var empty: [DEVICE_INFO_HEADER_SIZE + 2]u8 = .{0} ** (DEVICE_INFO_HEADER_SIZE + 2);
    std.mem.writeInt(u16, empty[8..10], 1, .little);
    empty[10] = 1;
    empty[11] = 0;
    try std.testing.expectEqual(@as(?DeviceInfo, null), decodeDeviceInfo(&empty));

    var oversized: [DEVICE_INFO_HEADER_SIZE + 1 + 1 + MAX_DEVICE_NAME_SIZE + 1]u8 = .{0} ** (DEVICE_INFO_HEADER_SIZE + 1 + 1 + MAX_DEVICE_NAME_SIZE + 1);
    std.mem.writeInt(u16, oversized[8..10], 1, .little);
    oversized[10] = 1;
    oversized[11] = MAX_DEVICE_NAME_SIZE + 1;
    try std.testing.expectEqual(@as(?DeviceInfo, null), decodeDeviceInfo(&oversized));

    var nul: [DEVICE_INFO_HEADER_SIZE + 3]u8 = .{0} ** (DEVICE_INFO_HEADER_SIZE + 3);
    std.mem.writeInt(u16, nul[8..10], 1, .little);
    nul[10] = 1;
    nul[11] = 1;
    try std.testing.expectEqual(@as(?DeviceInfo, null), decodeDeviceInfo(&nul));

    var invalid_utf8: [DEVICE_INFO_HEADER_SIZE + 3]u8 = .{0} ** (DEVICE_INFO_HEADER_SIZE + 3);
    std.mem.writeInt(u16, invalid_utf8[8..10], 1, .little);
    invalid_utf8[10] = 1;
    invalid_utf8[11] = 1;
    invalid_utf8[12] = 0xc0;
    try std.testing.expectEqual(@as(?DeviceInfo, null), decodeDeviceInfo(&invalid_utf8));
}

test "bundle bounds, truncation, bus and trailing bytes" {
    var storage: [128]u8 = undefined;
    storage[0] = 2;
    var offset: usize = 1;
    for (0..2) |_| {
        const info = encodeDeviceInfo(.{ .bus = 3, .vendor = 0, .product = 0, .descriptor = &.{ 5, 1 }, .name = "test" }, storage[offset + 2 ..]).?;
        std.mem.writeInt(u16, storage[offset..][0..2], @intCast(info.len), .little);
        offset += 2 + info.len;
    }
    var infos: [MAX_DEVICES]DeviceInfo = undefined;
    const decoded = decodeDeviceBundle(storage[0..offset], &infos).?;
    try std.testing.expectEqual(@as(usize, 2), decoded.len);
    try std.testing.expectEqualStrings("test", decoded[1].name);
    for (0..offset) |length| try std.testing.expect(decodeDeviceBundle(storage[0..length], &infos) == null);
    try std.testing.expect(decodeDeviceBundle(storage[0 .. offset + 1], &infos) == null);
    storage[0] = 0;
    try std.testing.expect(decodeDeviceBundle(storage[0..offset], &infos) == null);
    storage[0] = MAX_DEVICES + 1;
    try std.testing.expect(decodeDeviceBundle(storage[0..offset], &infos) == null);
    storage[0] = 2;
    storage[5] = 1; // bus no longer fits Linux UHID's u16 field
    try std.testing.expect(decodeDeviceBundle(storage[0..offset], &infos) == null);
}

test "truncated frame reads as end of stream" {
    var wire: [64]u8 = undefined;
    var writer = Io.Writer.fixed(&wire);
    try sendFrame(&writer, .output, &.{ 1, 2, 3, 4 });

    var reader = Io.Reader.fixed(writer.buffered()[0..5]);
    var payload_buf: [MAX_FRAME_PAYLOAD]u8 = undefined;
    try std.testing.expectEqual(@as(?Frame, null), try readFrame(&reader, &payload_buf));
}
