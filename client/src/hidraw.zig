//! Linux hidraw device access.
//!
//! File reads/writes go through `std.Io`; the HID report ioctls are
//! inherently Linux-specific and use `std.os.linux.ioctl` on the file handle.

const std = @import("std");
const linux = std.os.linux;
const Io = std.Io;

/// Report types as used by UHID (and HID core): matches the `rtype` byte the
/// server forwards in FRAME_GET_REPORT / FRAME_SET_REPORT.
pub const REPORT_TYPE_FEATURE: u8 = 0;
pub const REPORT_TYPE_OUTPUT: u8 = 1;
pub const REPORT_TYPE_INPUT: u8 = 2;

/// Largest HID report we handle: report number byte + UHID_DATA_MAX.
pub const MAX_REPORT_SIZE = 4096;

const IOC_READ: u32 = 2;
const IOC_WRITE: u32 = 1;

fn hidIoc(dir: u32, nr: u32, len: usize) u32 {
    return (dir << 30) | (@as(u32, @intCast(len)) << 16) | (@as(u32, 'H') << 8) | nr;
}

fn hidiocSFeature(len: usize) u32 {
    return hidIoc(IOC_READ | IOC_WRITE, 0x06, len);
}
fn hidiocGFeature(len: usize) u32 {
    return hidIoc(IOC_READ | IOC_WRITE, 0x07, len);
}
fn hidiocSInput(len: usize) u32 {
    return hidIoc(IOC_READ | IOC_WRITE, 0x09, len);
}
fn hidiocGInput(len: usize) u32 {
    return hidIoc(IOC_READ | IOC_WRITE, 0x0a, len);
}
fn hidiocSOutput(len: usize) u32 {
    return hidIoc(IOC_READ | IOC_WRITE, 0x0b, len);
}
fn hidiocGOutput(len: usize) u32 {
    return hidIoc(IOC_READ | IOC_WRITE, 0x0c, len);
}
fn hidiocGRawInfo() u32 {
    return hidIoc(IOC_READ, 0x03, @sizeOf(HidrawDevInfo));
}
fn hidiocGReportDescriptorSize() u32 {
    return hidIoc(IOC_READ, 0x01, @sizeOf(u32));
}
fn hidiocGReportDescriptor() u32 {
    return hidIoc(IOC_READ, 0x02, @sizeOf(HidrawReportDescriptor));
}

const HidrawDevInfo = extern struct {
    bus: u32,
    vendor: u16,
    product: u16,
};

const HidrawReportDescriptor = extern struct {
    size: u32,
    value: [MAX_REPORT_DESCRIPTOR_SIZE]u8,
};

pub const MAX_REPORT_DESCRIPTOR_SIZE = 4096;

pub const DeviceInfo = struct {
    bus: u32,
    vendor: u16,
    product: u16,
    descriptor_len: usize,
};

pub const Device = struct {
    file: Io.File,

    pub fn open(io: Io, path: []const u8) !Device {
        const file = try Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write });
        return .{ .file = file };
    }

    pub fn close(dev: *Device, io: Io) void {
        dev.file.close(io);
    }

    pub fn deviceInfo(dev: *Device, descriptor: *[MAX_REPORT_DESCRIPTOR_SIZE]u8) !DeviceInfo {
        var raw_info: HidrawDevInfo = undefined;
        const info_rc = linux.ioctl(dev.file.handle, hidiocGRawInfo(), @intFromPtr(&raw_info));
        if (linux.errno(info_rc) != .SUCCESS) return error.GetRawInfoFailed;

        var descriptor_size: u32 = undefined;
        const size_rc = linux.ioctl(dev.file.handle, hidiocGReportDescriptorSize(), @intFromPtr(&descriptor_size));
        if (linux.errno(size_rc) != .SUCCESS) return error.GetReportDescriptorSizeFailed;
        if (descriptor_size == 0 or descriptor_size > MAX_REPORT_DESCRIPTOR_SIZE) return error.InvalidReportDescriptor;

        var raw_descriptor = HidrawReportDescriptor{
            .size = descriptor_size,
            .value = undefined,
        };
        const descriptor_rc = linux.ioctl(dev.file.handle, hidiocGReportDescriptor(), @intFromPtr(&raw_descriptor));
        if (linux.errno(descriptor_rc) != .SUCCESS) return error.GetReportDescriptorFailed;

        const descriptor_len: usize = descriptor_size;
        @memcpy(descriptor[0..descriptor_len], raw_descriptor.value[0..descriptor_len]);
        return .{
            .bus = raw_info.bus,
            .vendor = raw_info.vendor,
            .product = raw_info.product,
            .descriptor_len = descriptor_len,
        };
    }

    /// Reads one input report. hidraw preserves report boundaries per read;
    /// for numbered devices the report number is the first byte.
    pub fn readReport(dev: *Device, io: Io, buf: []u8) !usize {
        return dev.file.readStreaming(io, &.{buf});
    }

    /// Writes one output report (report number as first byte).
    pub fn writeReport(dev: *Device, io: Io, data: []const u8) !void {
        try dev.file.writeStreamingAll(io, data);
    }

    /// Fetches a report via ioctl. `buf[0]` must hold the report number on
    /// entry. Returns the report length, or the errno value as a u16 error
    /// code to forward to the server.
    pub fn getReport(dev: *Device, report_type: u8, buf: []u8) union(enum) { len: usize, err: u16 } {
        const request = switch (report_type) {
            REPORT_TYPE_FEATURE => hidiocGFeature(buf.len),
            REPORT_TYPE_INPUT => hidiocGInput(buf.len),
            REPORT_TYPE_OUTPUT => hidiocGOutput(buf.len),
            else => return .{ .err = @intFromEnum(linux.E.INVAL) },
        };
        const rc = linux.ioctl(dev.file.handle, request, @intFromPtr(buf.ptr));
        const err = linux.errno(rc);
        if (err != .SUCCESS) return .{ .err = @intFromEnum(err) };
        return .{ .len = rc };
    }

    /// Sends a report via ioctl. `data[0]` must be the report number.
    /// Returns 0 on success or the errno value to forward to the server.
    pub fn setReport(dev: *Device, io: Io, report_type: u8, data: []const u8) u16 {
        switch (report_type) {
            REPORT_TYPE_OUTPUT => {
                // Plain hidraw write is the portable way to send output reports.
                dev.writeReport(io, data) catch return @intFromEnum(linux.E.IO);
                return 0;
            },
            REPORT_TYPE_FEATURE, REPORT_TYPE_INPUT => {
                const request = if (report_type == REPORT_TYPE_FEATURE)
                    hidiocSFeature(data.len)
                else
                    hidiocSInput(data.len);
                const rc = linux.ioctl(dev.file.handle, request, @intFromPtr(data.ptr));
                const err = linux.errno(rc);
                if (err != .SUCCESS) return @intFromEnum(err);
                return 0;
            },
            else => return @intFromEnum(linux.E.INVAL),
        }
    }
};

/// Scans /sys/class/hidraw/hidrawN/device/uevent for a HID_ID matching
/// the vendor and one product ID on any bus (USB 0x03 or Bluetooth 0x05). On match, writes
/// "/dev/hidrawN" into `path_buf` and returns it.
pub fn discover(io: Io, vendor: u32, products: []const u32, path_buf: *[32]u8) ?[]const u8 {
    var index: u8 = 0;
    while (index < 64) : (index += 1) {
        var sys_buf: [64]u8 = undefined;
        const sys_path = std.fmt.bufPrint(
            &sys_buf,
            "/sys/class/hidraw/hidraw{d}/device/uevent",
            .{index},
        ) catch unreachable;

        var content: [1024]u8 = undefined;
        const len = readSmallFile(io, sys_path, &content) orelse continue;
        const id = parseHidId(content[0..len]) orelse continue;
        if (id.vendor == vendor and std.mem.indexOfScalar(u32, products, id.product) != null) {
            return std.fmt.bufPrint(path_buf, "/dev/hidraw{d}", .{index}) catch unreachable;
        }
    }
    return null;
}

fn readSmallFile(io: Io, path: []const u8, buf: []u8) ?usize {
    const file = Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    var total: usize = 0;
    while (total < buf.len) {
        const n = file.readStreaming(io, &.{buf[total..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return null,
        };
        total += n;
    }
    return total;
}

pub const HidId = struct {
    bus: u32,
    vendor: u32,
    product: u32,
};

/// Parses the `HID_ID=0005:000028DE:00001303` line out of a uevent blob.
pub fn parseHidId(uevent: []const u8) ?HidId {
    var lines = std.mem.splitScalar(u8, uevent, '\n');
    while (lines.next()) |line| {
        const value = std.mem.cutPrefix(u8, line, "HID_ID=") orelse continue;
        var parts = std.mem.splitScalar(u8, value, ':');
        const bus_text = parts.next() orelse return null;
        const vendor_text = parts.next() orelse return null;
        const product_text = parts.next() orelse return null;
        return .{
            .bus = std.fmt.parseInt(u32, bus_text, 16) catch return null,
            .vendor = std.fmt.parseInt(u32, vendor_text, 16) catch return null,
            .product = std.fmt.parseInt(u32, product_text, 16) catch return null,
        };
    }
    return null;
}

test "parseHidId extracts bus, vendor, product" {
    const uevent =
        \\DRIVER=hid-generic
        \\HID_ID=0005:000028DE:00001303
        \\HID_NAME=SteamController
        \\HID_PHYS=aa:bb:cc:dd:ee:ff
        \\MODALIAS=hid:b0005g0001v000028DEp00001303
        \\
    ;
    const id = parseHidId(uevent).?;
    try std.testing.expectEqual(@as(u32, 0x0005), id.bus);
    try std.testing.expectEqual(@as(u32, 0x28de), id.vendor);
    try std.testing.expectEqual(@as(u32, 0x1303), id.product);
}

test "parseHidId returns null without HID_ID" {
    try std.testing.expectEqual(@as(?HidId, null), parseHidId("DRIVER=hid-generic\n"));
}

test "hid ioctl numbers match kernel hidraw.h" {
    // HIDIOCGFEATURE(256) computed against the C macro expansion.
    try std.testing.expectEqual(@as(u32, 0xc1004807), hidiocGFeature(256));
    try std.testing.expectEqual(@as(u32, 0xc1004806), hidiocSFeature(256));
}
