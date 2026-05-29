const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const UINPUT_PATH = "/dev/uinput";
const PACKET_SIZE = 20;

const EV_SYN: u16 = 0x00;
const EV_KEY: u16 = 0x01;
const EV_ABS: u16 = 0x03;
const SYN_REPORT: u16 = 0;

const BUS_USB: u16 = 0x03;

const ABS_X: u16 = 0x00;
const ABS_Y: u16 = 0x01;
const ABS_Z: u16 = 0x02;
const ABS_RX: u16 = 0x03;
const ABS_RY: u16 = 0x04;
const ABS_RZ: u16 = 0x05;
const ABS_HAT0X: u16 = 0x10;
const ABS_HAT0Y: u16 = 0x11;

const BTN_A: u16 = 0x130;
const BTN_B: u16 = 0x131;
const BTN_X: u16 = 0x133;
const BTN_Y: u16 = 0x134;
const BTN_TL: u16 = 0x136;
const BTN_TR: u16 = 0x137;
const BTN_SELECT: u16 = 0x13a;
const BTN_START: u16 = 0x13b;
const BTN_MODE: u16 = 0x13c;
const BTN_THUMBL: u16 = 0x13d;
const BTN_THUMBR: u16 = 0x13e;

const X_DPAD_UP: u32 = 0x0001;
const X_DPAD_DOWN: u32 = 0x0002;
const X_DPAD_LEFT: u32 = 0x0004;
const X_DPAD_RIGHT: u32 = 0x0008;
const X_START: u32 = 0x0010;
const X_BACK: u32 = 0x0020;
const X_LEFT_STICK: u32 = 0x0040;
const X_RIGHT_STICK: u32 = 0x0080;
const X_LEFT_BUMPER: u32 = 0x0100;
const X_RIGHT_BUMPER: u32 = 0x0200;
const X_GUIDE: u32 = 0x0400;
const X_A: u32 = 0x1000;
const X_B: u32 = 0x2000;
const X_X: u32 = 0x4000;
const X_Y: u32 = 0x8000;

const UI_DEV_CREATE: u32 = 0x5501;
const UI_DEV_DESTROY: u32 = 0x5502;
const UI_DEV_SETUP: u32 = 0x405c5503;
const UI_ABS_SETUP: u32 = 0x401c5504;
const UI_SET_EVBIT: u32 = 0x40045564;
const UI_SET_KEYBIT: u32 = 0x40045565;
const UI_SET_ABSBIT: u32 = 0x40045567;

const InputId = extern struct {
    bustype: u16,
    vendor: u16,
    product: u16,
    version: u16,
};

const UinputSetup = extern struct {
    id: InputId,
    name: [80]u8,
    ff_effects_max: u32,
};

const InputAbsInfo = extern struct {
    value: i32,
    minimum: i32,
    maximum: i32,
    fuzz: i32,
    flat: i32,
    resolution: i32,
};

const UinputAbsSetup = extern struct {
    code: u16,
    filler: u16 = 0,
    absinfo: InputAbsInfo,
};

const InputEvent = extern struct {
    sec: isize = 0,
    usec: isize = 0,
    type: u16,
    code: u16,
    value: i32,
};

pub fn main() !void {
    const fd = try openUinput();
    defer _ = linux.close(fd);

    try setupDevice(fd);
    defer destroyDevice(fd);

    log("steamless-uinput: ready\n");

    var packet: [PACKET_SIZE]u8 = undefined;
    while (true) {
        const got = try readExactOrEof(0, &packet);
        if (!got) break;
        try emitPacket(fd, &packet);
    }
}

fn openUinput() !i32 {
    const flags = linux.O{ .ACCMODE = .RDWR, .NONBLOCK = true };
    const rc = linux.open(UINPUT_PATH, flags, 0);
    if (posix.errno(rc) != .SUCCESS) {
        log("steamless-uinput: failed to open /dev/uinput\n");
        return error.OpenUinputFailed;
    }
    return @intCast(rc);
}

fn setupDevice(fd: i32) !void {
    try ioctlInt(fd, UI_SET_EVBIT, EV_KEY);
    try ioctlInt(fd, UI_SET_EVBIT, EV_ABS);

    const keys = [_]u16{ BTN_A, BTN_B, BTN_X, BTN_Y, BTN_TL, BTN_TR, BTN_SELECT, BTN_START, BTN_MODE, BTN_THUMBL, BTN_THUMBR };
    for (keys) |key| try ioctlInt(fd, UI_SET_KEYBIT, key);

    try setupAbs(fd, ABS_X, -32768, 32767, 4096);
    try setupAbs(fd, ABS_Y, -32768, 32767, 4096);
    try setupAbs(fd, ABS_RX, -32768, 32767, 4096);
    try setupAbs(fd, ABS_RY, -32768, 32767, 4096);
    try setupAbs(fd, ABS_Z, 0, 255, 0);
    try setupAbs(fd, ABS_RZ, 0, 255, 0);
    try setupAbs(fd, ABS_HAT0X, -1, 1, 0);
    try setupAbs(fd, ABS_HAT0Y, -1, 1, 0);

    var setup = std.mem.zeroes(UinputSetup);
    setup.id = .{
        .bustype = BUS_USB,
        .vendor = 0x045e,
        .product = 0x028e,
        .version = 0x0114,
    };
    copyZ(&setup.name, "SteamlessLink Virtual Xbox 360 Controller");
    try ioctlPtr(fd, UI_DEV_SETUP, &setup);
    try ioctlNoArg(fd, UI_DEV_CREATE);
    sleepMs(200);
}

fn setupAbs(fd: i32, code: u16, minimum: i32, maximum: i32, flat: i32) !void {
    try ioctlInt(fd, UI_SET_ABSBIT, code);
    var setup = UinputAbsSetup{
        .code = code,
        .absinfo = .{
            .value = 0,
            .minimum = minimum,
            .maximum = maximum,
            .fuzz = 0,
            .flat = flat,
            .resolution = 0,
        },
    };
    try ioctlPtr(fd, UI_ABS_SETUP, &setup);
}

fn destroyDevice(fd: i32) void {
    _ = linux.ioctl(fd, UI_DEV_DESTROY, 0);
    sleepMs(100);
}

fn emitPacket(fd: i32, packet: *const [PACKET_SIZE]u8) !void {
    const buttons = leU32(packet[0..4]);
    const lt: i32 = packet[4];
    const rt: i32 = packet[5];
    const lx: i32 = leI16(packet[6..8]);
    const ly: i32 = leI16(packet[8..10]);
    const rx: i32 = leI16(packet[10..12]);
    const ry: i32 = leI16(packet[12..14]);

    try emitAbs(fd, ABS_X, lx);
    try emitAbs(fd, ABS_Y, -ly);
    try emitAbs(fd, ABS_RX, rx);
    try emitAbs(fd, ABS_RY, -ry);
    try emitAbs(fd, ABS_Z, lt);
    try emitAbs(fd, ABS_RZ, rt);
    try emitAbs(fd, ABS_HAT0X, if ((buttons & X_DPAD_LEFT) != 0) -1 else if ((buttons & X_DPAD_RIGHT) != 0) 1 else 0);
    try emitAbs(fd, ABS_HAT0Y, if ((buttons & X_DPAD_UP) != 0) -1 else if ((buttons & X_DPAD_DOWN) != 0) 1 else 0);

    try emitKey(fd, BTN_A, buttons & X_A);
    try emitKey(fd, BTN_B, buttons & X_B);
    try emitKey(fd, BTN_X, buttons & X_X);
    try emitKey(fd, BTN_Y, buttons & X_Y);
    try emitKey(fd, BTN_TL, buttons & X_LEFT_BUMPER);
    try emitKey(fd, BTN_TR, buttons & X_RIGHT_BUMPER);
    try emitKey(fd, BTN_SELECT, buttons & X_BACK);
    try emitKey(fd, BTN_START, buttons & X_START);
    try emitKey(fd, BTN_MODE, buttons & X_GUIDE);
    try emitKey(fd, BTN_THUMBL, buttons & X_LEFT_STICK);
    try emitKey(fd, BTN_THUMBR, buttons & X_RIGHT_STICK);
    try emit(fd, EV_SYN, SYN_REPORT, 0);
}

fn emitAbs(fd: i32, code: u16, value: i32) !void {
    try emit(fd, EV_ABS, code, value);
}

fn emitKey(fd: i32, code: u16, bit: u32) !void {
    try emit(fd, EV_KEY, code, if (bit != 0) 1 else 0);
}

fn emit(fd: i32, event_type: u16, code: u16, value: i32) !void {
    var ev = InputEvent{ .type = event_type, .code = code, .value = value };
    try writeAll(fd, std.mem.asBytes(&ev));
}

fn readExactOrEof(fd: i32, out: *[PACKET_SIZE]u8) !bool {
    var offset: usize = 0;
    while (offset < out.len) {
        const rc = linux.read(fd, out[offset..].ptr, out.len - offset);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return offset != 0;
                offset += n;
            },
            .INTR => {},
            else => return error.ReadFailed,
        }
    }
    return true;
}

fn ioctlNoArg(fd: i32, request: u32) !void {
    const rc = linux.ioctl(fd, request, 0);
    if (posix.errno(rc) != .SUCCESS) return error.IoctlFailed;
}

fn ioctlInt(fd: i32, request: u32, value: u16) !void {
    const rc = linux.ioctl(fd, request, value);
    if (posix.errno(rc) != .SUCCESS) return error.IoctlFailed;
}

fn ioctlPtr(fd: i32, request: u32, ptr: anytype) !void {
    const rc = linux.ioctl(fd, request, @intFromPtr(ptr));
    if (posix.errno(rc) != .SUCCESS) return error.IoctlFailed;
}

fn writeAll(fd: i32, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = linux.write(fd, bytes[offset..].ptr, bytes.len - offset);
        switch (posix.errno(rc)) {
            .SUCCESS => offset += @intCast(rc),
            .INTR => {},
            else => return error.WriteFailed,
        }
    }
}

fn copyZ(dest: *[80]u8, source: []const u8) void {
    const len = @min(dest.len - 1, source.len);
    @memcpy(dest[0..len], source[0..len]);
    dest[len] = 0;
}

fn leU32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

fn leI16(bytes: []const u8) i16 {
    const value = @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
    return @bitCast(value);
}

fn sleepMs(ms: u64) void {
    var ts = linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = linux.nanosleep(&ts, null);
}

fn log(message: []const u8) void {
    _ = linux.write(2, message.ptr, message.len);
}
