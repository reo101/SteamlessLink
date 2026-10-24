const std = @import("std");
const c = @import("c");
const core = @import("steamless-core");
const bytes = core.bytes;
const descriptor_io = @import("descriptor_io.zig");

pub const DESTROY: u32 = 1;
pub const START: u32 = 2;
pub const STOP: u32 = 3;
pub const OPEN: u32 = 4;
pub const CLOSE: u32 = 5;
pub const OUTPUT: u32 = 6;
pub const GET_REPORT: u32 = 9;
pub const GET_REPORT_REPLY: u32 = 10;
pub const CREATE2: u32 = 11;
pub const INPUT2: u32 = 12;
pub const SET_REPORT: u32 = 13;
pub const SET_REPORT_REPLY: u32 = 14;
pub const DATA_MAX = 4096;
const CREATE2_SIZE = 128 + 64 + 64 + 2 + 2 + 4 + 4 + 4 + 4 + DATA_MAX;
pub const EVENT_SIZE = 4 + CREATE2_SIZE;
pub const REPORT_DESCRIPTOR_SIZE = 7 + 19 * 15 + 1;

pub const Identity = struct {
    name: []const u8 = "Steam Controller",
    phys: []const u8 = "steamlesslink/input0",
    uniq: []const u8 = "steamlesslink-triton",
    bus: u16 = 0x03,
    vendor: u32 = 0x28de,
    product: u32 = 0x1303,
    version: u32 = 0x0110,
    country: u32 = 0,
};

pub const Device = struct {
    fd: c_int,
    destroyed: bool = false,

    pub fn open(path: []const u8, identity: Identity, device_info: ?core.protocol.DeviceInfo) !Device {
        var effective = identity;
        const default_descriptor = vendorReportDescriptor();
        const descriptor = if (device_info) |info| blk: {
            effective.bus = @intCast(info.bus);
            effective.vendor = info.vendor;
            effective.product = info.product;
            if (info.name.len != 0) effective.name = info.name;
            break :blk info.descriptor;
        } else &default_descriptor;
        const path_z = try std.heap.page_allocator.dupeSentinel(u8, path, 0);
        defer std.heap.page_allocator.free(path_z);
        const fd = c.open(path_z.ptr, c.O_RDWR | c.O_CLOEXEC);
        if (std.c.errno(fd) != .SUCCESS) return error.UhidOpenFailed;
        errdefer descriptor_io.closeFd(fd);
        var event: [EVENT_SIZE]u8 = undefined;
        try descriptor_io.writeAllFd(fd, try encodeCreateEvent(effective, descriptor, &event));
        return .{ .fd = fd };
    }

    pub fn inputReport(dev: *Device, data: []const u8) !void {
        if (data.len == 0) return;
        if (data.len > DATA_MAX) return error.ReportTooLarge;
        var payload: [2 + DATA_MAX]u8 = @splat(0);
        bytes.writeU16Le(&payload, 0, @intCast(data.len));
        @memcpy(payload[2 .. 2 + data.len], data);
        try dev.writeEvent(INPUT2, &payload);
    }

    pub fn getReportReply(dev: *Device, request_id: u32, err: u16, data: []const u8) !void {
        const safe_len = @min(data.len, DATA_MAX);
        var payload: [8 + DATA_MAX]u8 = @splat(0);
        bytes.writeU32Le(&payload, 0, request_id);
        bytes.writeU16Le(&payload, 4, err);
        bytes.writeU16Le(&payload, 6, @intCast(safe_len));
        @memcpy(payload[8 .. 8 + safe_len], data[0..safe_len]);
        try dev.writeEvent(GET_REPORT_REPLY, &payload);
    }

    pub fn setReportReply(dev: *Device, request_id: u32, err: u16) !void {
        var payload: [6]u8 = @splat(0);
        bytes.writeU32Le(&payload, 0, request_id);
        bytes.writeU16Le(&payload, 4, err);
        try dev.writeEvent(SET_REPORT_REPLY, &payload);
    }

    pub fn destroy(dev: *Device) void {
        if (dev.destroyed) return;
        dev.destroyed = true;
        dev.writeEvent(DESTROY, &.{}) catch {};
        descriptor_io.closeFd(dev.fd);
    }

    fn writeEvent(dev: *Device, event_type: u32, payload: []const u8) !void {
        if (payload.len > CREATE2_SIZE) return error.UhidPayloadTooLarge;
        var event: [EVENT_SIZE]u8 = @splat(0);
        bytes.writeU32Le(&event, 0, event_type);
        @memcpy(event[4 .. 4 + payload.len], payload);
        try descriptor_io.writeAllFd(dev.fd, &event);
    }
};

fn encodeCreateEvent(identity: Identity, descriptor: []const u8, event: *[EVENT_SIZE]u8) ![]const u8 {
    if (descriptor.len == 0 or descriptor.len > DATA_MAX) return error.InvalidReportDescriptor;
    @memset(event, 0);
    bytes.writeU32Le(event, 0, CREATE2);
    const payload = event[4..];
    copyZBytes(payload[0..128], identity.name);
    copyZBytes(payload[128..192], identity.phys);
    copyZBytes(payload[192..256], identity.uniq);
    bytes.writeU16Le(payload, 256, @intCast(descriptor.len));
    bytes.writeU16Le(payload, 258, identity.bus);
    bytes.writeU32Le(payload, 260, identity.vendor);
    bytes.writeU32Le(payload, 264, identity.product);
    bytes.writeU32Le(payload, 268, identity.version);
    bytes.writeU32Le(payload, 272, identity.country);
    @memcpy(payload[276 .. 276 + descriptor.len], descriptor);
    return event;
}

fn copyZBytes(dest: []u8, value: []const u8) void {
    @memset(dest, 0);
    if (dest.len == 0) return;
    const len = @min(value.len, dest.len - 1);
    @memcpy(dest[0..len], value[0..len]);
}

pub fn vendorReportDescriptor() [REPORT_DESCRIPTOR_SIZE]u8 {
    var out: [REPORT_DESCRIPTOR_SIZE]u8 = undefined;
    var index: usize = 0;
    appendDescriptor(&out, &index, &.{ 0x06, 0x00, 0xff, 0x09, 0x01, 0xa1, 0x01 });
    addReport(&out, &index, 0x45, 0x81, 45);
    addReport(&out, &index, 0x47, 0x81, 45);
    addReport(&out, &index, 0x42, 0x81, 63);
    addReport(&out, &index, 0x43, 0x81, 63);
    for ([_]u8{ 0x01, 0x03, 0x04, 0x08, 0x09 }) |report_id| addReport(&out, &index, report_id, 0xb1, 63);
    for (0x80..0x8a) |report_id| addReport(&out, &index, @intCast(report_id), 0x91, 63);
    appendDescriptor(&out, &index, &.{0xc0});
    std.debug.assert(index == REPORT_DESCRIPTOR_SIZE);
    return out;
}

fn addReport(out: *[REPORT_DESCRIPTOR_SIZE]u8, index: *usize, report_id: u8, main_item: u8, count: u8) void {
    appendDescriptor(out, index, &.{ 0x85, report_id, 0x09, 0x01, 0x15, 0x00, 0x26, 0xff, 0x00, 0x75, 0x08, 0x95, count, main_item, 0x02 });
}
fn appendDescriptor(out: *[REPORT_DESCRIPTOR_SIZE]u8, index: *usize, data: []const u8) void {
    @memcpy(out[index.* .. index.* + data.len], data);
    index.* += data.len;
}

test "vendor report descriptor has expected shape" {
    const descriptor = vendorReportDescriptor();
    try std.testing.expectEqual(@as(usize, REPORT_DESCRIPTOR_SIZE), descriptor.len);
    try std.testing.expect(std.mem.indexOf(u8, &descriptor, &.{ 0x85, 0x47 }) != null);
    try std.testing.expectEqual(@as(u8, 0xc0), descriptor[descriptor.len - 1]);
}

test "actual create event encoder preserves identity descriptor and zero padding" {
    var event: [EVENT_SIZE]u8 = undefined;
    const descriptor = [_]u8{ 0x05, 0x01 };
    const encoded = try encodeCreateEvent(.{ .name = "Test", .bus = 5, .vendor = 0xabcd, .product = 0x1234 }, &descriptor, &event);
    try std.testing.expectEqual(@as(usize, EVENT_SIZE), encoded.len);
    try std.testing.expectEqual(CREATE2, bytes.readU32Le(encoded, 0));
    const payload = encoded[4..];
    try std.testing.expectEqualStrings("Test", std.mem.sliceTo(payload[0..128], 0));
    try std.testing.expectEqual(@as(u16, 2), bytes.readU16Le(payload, 256));
    try std.testing.expectEqual(@as(u16, 5), bytes.readU16Le(payload, 258));
    try std.testing.expectEqual(@as(u32, 0xabcd), bytes.readU32Le(payload, 260));
    try std.testing.expectEqual(@as(u32, 0x1234), bytes.readU32Le(payload, 264));
    try std.testing.expectEqualSlices(u8, &descriptor, payload[276..278]);
    for (payload[278..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectError(error.InvalidReportDescriptor, encodeCreateEvent(.{}, &.{}, &event));
}
