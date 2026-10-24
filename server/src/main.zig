const std = @import("std");
const c = @import("c");
const core = @import("steamless-core");
const protocol = core.protocol;
const uhid = @import("uhid.zig");
const descriptor_io = @import("descriptor_io.zig");
const readFd = descriptor_io.readFd;
const writeAllFd = descriptor_io.writeAllFd;
const closeFd = descriptor_io.closeFd;
const readU16Le = core.bytes.readU16Le;
const readU32Le = core.bytes.readU32Le;
const readU64Le = core.bytes.readU64Le;
const writeU16Le = core.bytes.writeU16Le;
const writeU32Le = core.bytes.writeU32Le;
const hexHead = core.log.hexHead;
const UhidDevice = uhid.Device;

const Allocator = std.mem.Allocator;
const AtomicBool = std.atomic.Value(bool);
const AtomicFd = std.atomic.Value(c_int);

const UHID_START = uhid.START;
const UHID_STOP = uhid.STOP;
const UHID_OPEN = uhid.OPEN;
const UHID_CLOSE = uhid.CLOSE;
const UHID_OUTPUT = uhid.OUTPUT;
const UHID_GET_REPORT = uhid.GET_REPORT;
const UHID_SET_REPORT = uhid.SET_REPORT;
const UHID_DATA_MAX = uhid.DATA_MAX;
const UHID_EVENT_SIZE = uhid.EVENT_SIZE;

const BUS_USB: u16 = 0x03;
const VALVE_VID: u32 = 0x28de;

const MAX_FRAME_PAYLOAD = protocol.MAX_FRAME_PAYLOAD;
const DEVICE_INFO_HEADER_SIZE = protocol.DEVICE_INFO_HEADER_SIZE;

const DeviceInfo = protocol.DeviceInfo;

const LogLevel = core.log.LogLevel;
const UhidIdentity = uhid.Identity;

const Config = struct {
    listen_host: []const u8 = "127.0.0.1",
    listen_port: u16 = 3244,
    uhid_path: []const u8 = "/dev/uhid",
    iroh_ticket_file: ?[]const u8 = null,
    identity: UhidIdentity = .{},
    log_level: LogLevel = .info,
};

const Frame = protocol.Frame;

var active_client_fd = AtomicFd.init(-1);

pub fn main(init: std.process.Init) !void {
    _ = c.signal(c.SIGPIPE, c.SIG_IGN);

    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var config = try parseArgs(argv);
    try runServer(init.io, allocator, &config);
}

fn parseArgs(argv: []const []const u8) !Config {
    var config = Config{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--listen-host")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgument;
            config.listen_host = argv[i];
        } else if (std.mem.eql(u8, arg, "--listen-port")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgument;
            config.listen_port = try std.fmt.parseInt(u16, argv[i], 0);
        } else if (std.mem.eql(u8, arg, "--uhid-path")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgument;
            config.uhid_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--iroh-ticket-file")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgument;
            config.iroh_ticket_file = argv[i];
        } else if (std.mem.eql(u8, arg, "--name")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgument;
            config.identity.name = argv[i];
        } else if (std.mem.eql(u8, arg, "--phys")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgument;
            config.identity.phys = argv[i];
        } else if (std.mem.eql(u8, arg, "--uniq")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgument;
            config.identity.uniq = argv[i];
        } else if (std.mem.eql(u8, arg, "--vid")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgument;
            config.identity.vendor = try std.fmt.parseInt(u32, argv[i], 0);
        } else if (std.mem.eql(u8, arg, "--pid")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgument;
            config.identity.product = try std.fmt.parseInt(u32, argv[i], 0);
        } else if (std.mem.eql(u8, arg, "--version")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgument;
            config.identity.version = try std.fmt.parseInt(u32, argv[i], 0);
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgument;
            config.log_level = LogLevel.parse(argv[i]) orelse return error.InvalidLogLevel;
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            printUsage();
            return error.UnknownArgument;
        }
    }
    return config;
}

fn printUsage() void {
    std.debug.print(
        \\Usage: steamless-link-host [options]
        \\
        \\Options:
        \\  --listen-host HOST   address to bind, default 127.0.0.1
        \\  --listen-port PORT   TCP port, default 3244
        \\  --uhid-path PATH     UHID device path, default /dev/uhid
        \\  --iroh-ticket-file PATH  path served to trusted raw-TCP bootstrap clients
        \\  --name NAME          UHID device name
        \\  --phys PHYS          UHID physical path
        \\  --uniq UNIQ          UHID unique path
        \\  --vid VID            vendor ID, default 0x28de
        \\  --pid PID            product ID, default 0x1303
        \\  --version VERSION    device version, default 0x0110
        \\  --log-level LEVEL    debug, info, warning, or error
        \\
    , .{});
}

fn runServer(io: std.Io, allocator: Allocator, config: *const Config) !void {
    const server_fd = try createListener(allocator, config);
    defer closeFd(server_fd);

    log(config, .info, "listening on {s}:{d}", .{ config.listen_host, config.listen_port });
    while (true) {
        const conn_fd = acceptClient(server_fd) catch |err| {
            log(config, .warning, "accept failed: {s}", .{@errorName(err)});
            continue;
        };
        const thread = std.Thread.spawn(.{}, handleClientThread, .{ conn_fd, config, io }) catch |err| {
            log(config, .warning, "client thread spawn failed: {s}", .{@errorName(err)});
            closeFd(conn_fd);
            continue;
        };
        thread.detach();
    }
}

fn handleClientThread(conn_fd: c_int, config: *const Config, io: std.Io) void {
    handleClient(conn_fd, config, io) catch |err| {
        log(config, .warning, "client failed: {s}", .{@errorName(err)});
    };
}

fn replaceActiveClient(conn_fd: c_int) void {
    const old_fd = active_client_fd.swap(conn_fd, .acq_rel);
    if (old_fd >= 0 and old_fd != conn_fd) {
        _ = c.shutdown(old_fd, c.SHUT_RDWR);
    }
}

fn clearActiveClient(conn_fd: c_int) void {
    _ = active_client_fd.cmpxchgStrong(conn_fd, -1, .acq_rel, .acquire);
}

fn createListener(allocator: Allocator, config: *const Config) !c_int {
    const host_z = try allocator.dupeSentinel(u8, config.listen_host, 0);
    defer allocator.free(host_z);

    const family: c_int = if (std.mem.indexOfScalar(u8, config.listen_host, ':') == null) c.AF_INET else c.AF_INET6;
    const fd = c.socket(family, c.SOCK_STREAM, 0);
    if (std.c.errno(fd) != .SUCCESS) return error.SocketCreateFailed;
    errdefer closeFd(fd);

    var one: c_int = 1;
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_REUSEADDR, &one, @sizeOf(c_int));

    if (family == c.AF_INET) {
        var addr: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
        addr.sin_family = c.AF_INET;
        addr.sin_port = c.htons(config.listen_port);
        if (c.inet_pton(c.AF_INET, host_z.ptr, &addr.sin_addr) != 1) return error.InvalidListenHost;
        try bindAndListen(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_in));
    } else {
        var addr: c.struct_sockaddr_in6 = std.mem.zeroes(c.struct_sockaddr_in6);
        addr.sin6_family = c.AF_INET6;
        addr.sin6_port = c.htons(config.listen_port);
        if (c.inet_pton(c.AF_INET6, host_z.ptr, &addr.sin6_addr) != 1) return error.InvalidListenHost;
        try bindAndListen(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_in6));
    }

    return fd;
}

fn bindAndListen(fd: c_int, addr: *const c.struct_sockaddr, len: c.socklen_t) !void {
    if (std.c.errno(c.bind(fd, addr, len)) != .SUCCESS) return error.BindFailed;
    if (std.c.errno(c.listen(fd, 4)) != .SUCCESS) return error.ListenFailed;
}

fn acceptClient(server_fd: c_int) !c_int {
    while (true) {
        var storage: c.struct_sockaddr_storage = undefined;
        var storage_len: c.socklen_t = @sizeOf(c.struct_sockaddr_storage);
        const conn_fd = c.accept(server_fd, @ptrCast(&storage), &storage_len);
        switch (std.c.errno(conn_fd)) {
            .SUCCESS => return conn_fd,
            .INTR => continue,
            else => return error.AcceptFailed,
        }
    }
}

fn handleClient(conn_fd: c_int, config: *const Config, io: std.Io) !void {
    var active = false;
    defer {
        if (active) clearActiveClient(conn_fd);
        closeFd(conn_fd);
    }

    var one: c_int = 1;
    _ = c.setsockopt(conn_fd, c.IPPROTO_TCP, c.TCP_NODELAY, &one, @sizeOf(c_int));
    log(config, .info, "client connected fd={d}", .{conn_fd});

    var payload_buf: [MAX_FRAME_PAYLOAD]u8 = undefined;
    var pending_frame: ?Frame = (try readFrame(conn_fd, &payload_buf)) orelse return;
    if (pending_frame.?.frame_type == .get_iroh_ticket) {
        if (pending_frame.?.payload.len != 0) {
            log(config, .warning, "invalid Iroh ticket request", .{});
            return;
        }
        const path = config.iroh_ticket_file orelse {
            log(config, .warning, "Iroh ticket requested but no ticket file is configured", .{});
            return;
        };
        const ticket = readIrohTicket(io, path, &payload_buf) catch |err| {
            log(config, .warning, "Iroh ticket unavailable: {s}", .{@errorName(err)});
            return;
        };
        try sendFrame(conn_fd, .iroh_ticket, ticket);
        log(config, .info, "served Iroh ticket to bootstrap client", .{});
        return;
    }

    replaceActiveClient(conn_fd);
    active = true;

    const bundled = pending_frame.?.frame_type == .device_bundle;
    var infos: [protocol.MAX_DEVICES]DeviceInfo = undefined;
    var bundle_infos: []DeviceInfo = &.{};
    var device_info: ?DeviceInfo = null;
    if (bundled) {
        bundle_infos = protocol.decodeDeviceBundle(pending_frame.?.payload, &infos) orelse return error.InvalidDeviceBundle;
        pending_frame = null;
    } else if (pending_frame.?.frame_type == .device_info) {
        const info = decodeDeviceInfo(pending_frame.?.payload) orelse {
            log(config, .warning, "invalid device-info frame", .{});
            return;
        };
        if (info.bus > std.math.maxInt(u16)) {
            log(config, .warning, "unsupported HID bus 0x{x}", .{info.bus});
            return;
        }
        device_info = info;
        pending_frame = null;
    }

    var devices: [protocol.MAX_DEVICES]UhidDevice = undefined;
    var device_count: usize = 0;
    defer for (devices[0..device_count]) |*dev| dev.destroy();
    if (bundled) {
        for (bundle_infos, 0..) |info, slot| {
            var slot_config = config.*;
            var phys: [64]u8 = undefined;
            var uniq: [64]u8 = undefined;
            slot_config.identity.phys = try std.fmt.bufPrint(&phys, "steamlesslink/input{d}", .{slot});
            slot_config.identity.uniq = try std.fmt.bufPrint(&uniq, "steamlesslink-extended-{d}", .{slot});
            devices[slot] = try openUhid(&slot_config, info);
            device_count += 1;
        }
        try sendFrame(conn_fd, .device_bundle_ready, &.{@intCast(device_count)});
    } else {
        devices[0] = try openUhid(config, device_info);
        device_count = 1;
    }

    var stop = AtomicBool.init(false);
    var reader_args = UhidReaderArgs{
        .devices = devices[0..device_count],
        .bundled = bundled,
        .conn_fd = conn_fd,
        .stop = &stop,
        .config = config,
    };
    const reader = try std.Thread.spawn(.{}, uhidReaderThread, .{&reader_args});

    var reports: u64 = 0;
    defer {
        stop.store(true, .release);
        _ = c.shutdown(conn_fd, c.SHUT_RDWR);
        reader.join();
        log(config, .info, "client disconnected fd={d} reports={d}", .{ conn_fd, reports });
    }

    var last_log_ns: i128 = 0;
    while (!stop.load(.acquire)) {
        var frame = if (pending_frame) |value| blk: {
            pending_frame = null;
            break :blk value;
        } else blk: {
            const maybe_frame = readFrame(conn_fd, &payload_buf) catch |err| {
                log(config, .warning, "client frame read failed: {s}", .{@errorName(err)});
                break;
            };
            break :blk maybe_frame orelse break;
        };
        var slot: usize = 0;
        if (frame.frame_type == .device_frame) {
            if (!bundled or frame.payload.len < protocol.DEVICE_FRAME_HEADER_SIZE or frame.payload[0] >= device_count) return error.InvalidDeviceFrame;
            slot = frame.payload[0];
            frame = .{
                .frame_type = @fromBackingInt(@intCast(frame.payload[protocol.DEVICE_FRAME_TYPE_OFFSET])),
                .payload = frame.payload[protocol.DEVICE_FRAME_HEADER_SIZE..],
            };
            switch (frame.frame_type) {
                .input, .get_report_reply, .set_report_reply => {},
                else => return error.InvalidDeviceFrame,
            }
        } else if (bundled) return error.ExpectedDeviceFrame;
        const dev = &devices[slot];
        switch (frame.frame_type) {
            .input => {
                reports += 1;
                const now = monotonicNs();
                if (now - last_log_ns >= std.time.ns_per_s) {
                    last_log_ns = now;
                    var head_buf: [23]u8 = undefined;
                    const report_id: u8 = if (frame.payload.len > 0) frame.payload[0] else 0;
                    log(
                        config,
                        .info,
                        "input reports={d} id=0x{x:0>2} len={d} head={s}",
                        .{ reports, report_id, frame.payload.len, hexHead(frame.payload, &head_buf) },
                    );
                }
                try dev.inputReport(frame.payload);
            },
            .get_report_reply => {
                if (frame.payload.len < 6) continue;
                const request_id = readU32Le(frame.payload, 0);
                const err = readU16Le(frame.payload, 4);
                try dev.getReportReply(request_id, err, frame.payload[6..]);
            },
            .set_report_reply => {
                if (frame.payload.len < 6) continue;
                const request_id = readU32Le(frame.payload, 0);
                const err = readU16Le(frame.payload, 4);
                try dev.setReportReply(request_id, err);
            },
            .device_info => log(config, .warning, "ignoring late device-info frame", .{}),
            else => log(config, .debug, "ignoring client frame type=0x{x:0>2} len={d}", .{ @backingInt(frame.frame_type), frame.payload.len }),
        }
    }
}

const UhidReaderArgs = struct {
    devices: []UhidDevice,
    bundled: bool,
    conn_fd: c_int,
    stop: *AtomicBool,
    config: *const Config,

    fn send(args: *UhidReaderArgs, slot: usize, frame_type: protocol.FrameType, payload: []const u8) !void {
        if (!args.bundled) return sendFrame(args.conn_fd, frame_type, payload);
        var buffer: [protocol.DEVICE_FRAME_HEADER_SIZE + 6 + UHID_DATA_MAX]u8 = undefined;
        buffer[0] = @intCast(slot);
        buffer[protocol.DEVICE_FRAME_TYPE_OFFSET] = @backingInt(frame_type);
        @memcpy(buffer[protocol.DEVICE_FRAME_HEADER_SIZE..][0..payload.len], payload);
        try sendFrame(args.conn_fd, .device_frame, buffer[0 .. protocol.DEVICE_FRAME_HEADER_SIZE + payload.len]);
    }
};

fn uhidReaderThread(args: *UhidReaderArgs) void {
    uhidReader(args) catch |err| {
        if (!args.stop.load(.acquire)) {
            log(args.config, .warning, "UHID reader failed: {s}", .{@errorName(err)});
        }
    };
    args.stop.store(true, .release);
    _ = c.shutdown(args.conn_fd, c.SHUT_RDWR);
}

fn uhidReader(args: *UhidReaderArgs) !void {
    var control_events: u64 = 0;
    var event_buf: [UHID_EVENT_SIZE]u8 = undefined;
    while (!args.stop.load(.acquire)) {
        var pollfds: [protocol.MAX_DEVICES]c.struct_pollfd = undefined;
        const fds = pollfds[0..args.devices.len];
        for (args.devices, fds) |dev, *fd| fd.* = .{ .fd = dev.fd, .events = c.POLLIN, .revents = 0 };
        const poll_rc = c.poll(fds.ptr, @intCast(fds.len), 250);
        switch (std.c.errno(poll_rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.PollFailed,
        }
        if (poll_rc == 0) continue;
        for (fds, 0..) |fd, slot| {
            if ((fd.revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL)) != 0) return;
            if ((fd.revents & c.POLLIN) == 0) continue;

            const read = try readFd(fd.fd, &event_buf);
            if (read < 4) continue;
            const event_type = readU32Le(event_buf[0..read], 0);
            const payload = event_buf[4..read];
            switch (event_type) {
                UHID_START => {
                    const flags = if (payload.len >= 8) readU64Le(payload, 0) else 0;
                    log(args.config, .info, "UHID start flags=0x{x}", .{flags});
                },
                UHID_STOP, UHID_OPEN, UHID_CLOSE => log(args.config, .info, "UHID event type={d}", .{event_type}),
                UHID_OUTPUT => {
                    if (payload.len < UHID_DATA_MAX + 3) continue;
                    control_events += 1;
                    const size = @min(readU16Le(payload, UHID_DATA_MAX), UHID_DATA_MAX);
                    const report_type = payload[UHID_DATA_MAX + 2];
                    const data = payload[0..size];
                    logControlEvent(args.config, control_events, "UHID output rtype={d} len={d}", .{ report_type, size });
                    var frame_payload: [1 + UHID_DATA_MAX]u8 = undefined;
                    frame_payload[0] = report_type;
                    @memcpy(frame_payload[1 .. 1 + data.len], data);
                    try args.send(slot, .output, frame_payload[0 .. 1 + data.len]);
                },
                UHID_GET_REPORT => {
                    if (payload.len < 6) continue;
                    control_events += 1;
                    const request_id = readU32Le(payload, 0);
                    const report_number = payload[4];
                    const report_type = payload[5];
                    logControlEvent(
                        args.config,
                        control_events,
                        "UHID get_report id={d} rnum=0x{x:0>2} rtype={d}",
                        .{ request_id, report_number, report_type },
                    );
                    var frame_payload: [6]u8 = undefined;
                    writeU32Le(&frame_payload, 0, request_id);
                    frame_payload[4] = report_number;
                    frame_payload[5] = report_type;
                    try args.send(slot, .get_report, &frame_payload);
                },
                UHID_SET_REPORT => {
                    if (payload.len < 8) continue;
                    control_events += 1;
                    const request_id = readU32Le(payload, 0);
                    const report_number = payload[4];
                    const report_type = payload[5];
                    const size = @min(readU16Le(payload, 6), @as(u16, UHID_DATA_MAX));
                    const data_end = @min(@as(usize, 8) + size, payload.len);
                    const data = payload[8..data_end];
                    logControlEvent(
                        args.config,
                        control_events,
                        "UHID set_report id={d} rnum=0x{x:0>2} rtype={d} len={d}",
                        .{ request_id, report_number, report_type, data.len },
                    );
                    var frame_payload: [6 + UHID_DATA_MAX]u8 = undefined;
                    writeU32Le(&frame_payload, 0, request_id);
                    frame_payload[4] = report_number;
                    frame_payload[5] = report_type;
                    @memcpy(frame_payload[6 .. 6 + data.len], data);
                    try args.send(slot, .set_report, frame_payload[0 .. 6 + data.len]);
                },
                else => log(args.config, .debug, "UHID event type={d}", .{event_type}),
            }
        }
    }
}

fn openUhid(config: *const Config, info: ?DeviceInfo) !UhidDevice {
    const dev = try UhidDevice.open(config.uhid_path, config.identity, info);
    log(config, .info, "created UHID device name={s} bus=0x{x:0>4} vid=0x{x:0>4} pid=0x{x:0>4} rd_size={d}", .{
        if (info) |value| (if (value.name.len != 0) value.name else config.identity.name) else config.identity.name,
        if (info) |value| value.bus else config.identity.bus,
        if (info) |value| value.vendor else config.identity.vendor,
        if (info) |value| value.product else config.identity.product,
        if (info) |value| value.descriptor.len else uhid.REPORT_DESCRIPTOR_SIZE,
    });
    return dev;
}

fn sendFrame(fd: c_int, frame_type: protocol.FrameType, payload: []const u8) !void {
    var header: [protocol.FRAME_HEADER_SIZE]u8 = undefined;
    const safe_len = protocol.encodeFrameHeader(&header, frame_type, payload.len);
    try writeAllFd(fd, &header);
    try writeAllFd(fd, payload[0..safe_len]);
}

fn readFrame(fd: c_int, payload_buf: *[MAX_FRAME_PAYLOAD]u8) !?Frame {
    var header: [protocol.FRAME_HEADER_SIZE]u8 = undefined;
    if (!try recvExact(fd, &header)) return null;
    const decoded = protocol.decodeFrameHeader(&header) orelse unreachable;
    if (!try recvExact(fd, payload_buf[0..decoded.payload_len])) return null;
    return .{ .frame_type = decoded.frame_type, .payload = payload_buf[0..decoded.payload_len] };
}

fn readIrohTicket(io: std.Io, path: []const u8, buffer: *[MAX_FRAME_PAYLOAD]u8) ![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const len = try file.readPositionalAll(io, buffer, 0);
    if (len == buffer.len and try file.readPositional(io, &.{buffer[0..1]}, len) != 0) return error.TicketTooLarge;
    const ticket = std.mem.trim(u8, buffer[0..len], " \t\r\n");
    if (ticket.len == 0) return error.TicketUnavailable;
    return ticket;
}

fn recvExact(fd: c_int, out: []u8) !bool {
    var offset: usize = 0;
    while (offset < out.len) {
        const read = try readFd(fd, out[offset..]);
        if (read == 0) return false;
        offset += read;
    }
    return true;
}

fn decodeDeviceInfo(payload: []const u8) ?DeviceInfo {
    return protocol.decodeDeviceInfo(payload);
}

fn monotonicNs() i128 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(i128, ts.tv_sec) * std.time.ns_per_s + ts.tv_nsec;
}

fn log(config: *const Config, level: LogLevel, comptime format: []const u8, args: anytype) void {
    core.log.log(config.log_level, level, format, args);
}

fn logControlEvent(config: *const Config, count: u64, comptime format: []const u8, args: anytype) void {
    const level: LogLevel = if (count <= 20 or count % 100 == 0) .info else .debug;
    log(config, level, format, args);
}

test "device info decoder preserves descriptor" {
    const descriptor = [_]u8{ 1, 2, 3, 4 };
    var payload: [DEVICE_INFO_HEADER_SIZE + descriptor.len]u8 = undefined;
    writeU32Le(&payload, 0, BUS_USB);
    writeU16Le(&payload, 4, VALVE_VID);
    writeU16Le(&payload, 6, 0x1302);
    writeU16Le(&payload, 8, @intCast(descriptor.len));
    @memcpy(payload[DEVICE_INFO_HEADER_SIZE..], &descriptor);

    const info = decodeDeviceInfo(&payload).?;
    try std.testing.expectEqual(@as(u32, BUS_USB), info.bus);
    try std.testing.expectEqual(@as(u16, VALVE_VID), info.vendor);
    try std.testing.expectEqual(@as(u16, 0x1302), info.product);
    try std.testing.expectEqualSlices(u8, &descriptor, info.descriptor);
}

test {
    _ = uhid;
}
