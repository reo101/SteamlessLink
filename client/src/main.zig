//! steamless-link-controller: bridges a local hidraw controller to a
//! Steamless Link host over the raw framed protocol.
//!
//! Input reports read from /dev/hidrawN are forwarded as FRAME_INPUT.
//! Server-originated FRAME_OUTPUT / FRAME_GET_REPORT / FRAME_SET_REPORT are
//! applied to the local device and answered with the matching reply frames.

const std = @import("std");
const Io = std.Io;
const core = @import("steamless-core");
const protocol = core.protocol;
const bytes = core.bytes;
const LogLevel = core.log.LogLevel;
const hidraw = @import("hidraw.zig");

const Config = struct {
    device_path: ?[]const u8 = null,
    vendor: u32 = 0x28de,
    products: []const u32 = &.{0x1303},
    host: []const u8 = "127.0.0.1",
    port: u16 = 3244,
    reconnect_ms: u32 = 2000,
    once: bool = false,
    log_level: LogLevel = .info,

    fn log(config: *const Config, level: LogLevel, comptime format: []const u8, args: anytype) void {
        core.log.log(config.log_level, level, format, args);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const config = try parseArgs(argv, init.arena.allocator());

    while (true) {
        runOnce(io, &config) catch |err| switch (err) {
            error.Canceled => return,
            else => {
                config.log(.warning, "session ended: {s}", .{@errorName(err)});
                if (config.once) return err;
            },
        };
        if (config.once) return;
        try io.sleep(.fromMilliseconds(config.reconnect_ms), .awake);
    }
}

fn parseArgs(argv: []const []const u8, allocator: std.mem.Allocator) !Config {
    var config = Config{};
    var products: std.ArrayList(u32) = .empty;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--device")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgument;
            config.device_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--vid")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgument;
            config.vendor = try std.fmt.parseInt(u32, argv[i], 0);
        } else if (std.mem.eql(u8, arg, "--pid")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgument;
            try products.append(allocator, try std.fmt.parseInt(u32, argv[i], 0));
        } else if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgument;
            config.host = argv[i];
        } else if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgument;
            config.port = try std.fmt.parseInt(u16, argv[i], 0);
        } else if (std.mem.eql(u8, arg, "--reconnect-ms")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgument;
            config.reconnect_ms = try std.fmt.parseInt(u32, argv[i], 0);
        } else if (std.mem.eql(u8, arg, "--once")) {
            config.once = true;
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
    if (products.items.len != 0) config.products = products.items;
    return config;
}

test "parseArgs accepts repeated product IDs" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const config = try parseArgs(
        &.{ "steamless-link-controller", "--pid", "0x1302", "--pid", "0x1303" },
        fba.allocator(),
    );
    try std.testing.expectEqualSlices(u32, &.{ 0x1302, 0x1303 }, config.products);
}

fn printUsage() void {
    std.debug.print(
        \\Usage: steamless-link-controller [options]
        \\
        \\Options:
        \\  --device PATH        hidraw device, e.g. /dev/hidraw3
        \\                       (default: discover by VID/PID)
        \\  --vid VID            vendor ID to discover, default 0x28de
        \\  --pid PID            product ID to discover, repeat for alternatives
        \\  --host HOST          server address, default 127.0.0.1
        \\  --port PORT          server TCP port, default 3244
        \\  --reconnect-ms MS    delay between retries, default 2000
        \\  --once               exit after one session instead of retrying
        \\  --log-level LEVEL    debug, info, warning, or error
        \\
    , .{});
}

fn runOnce(io: Io, config: *const Config) !void {
    var path_buf: [32]u8 = undefined;
    const device_path = config.device_path orelse
        hidraw.discover(io, config.vendor, config.products, &path_buf) orelse {
        return error.DeviceNotFound;
    };

    var device = hidraw.Device.open(io, device_path) catch |err| {
        config.log(.warning, "open {s} failed: {s}", .{ device_path, @errorName(err) });
        return error.DeviceOpenFailed;
    };
    defer device.close(io);
    config.log(.info, "using device {s}", .{device_path});

    var stream = try connectToHost(io, config.host, config.port);
    defer stream.close(io);
    setTcpNoDelay(&stream);
    config.log(.info, "connected to {s}:{d}", .{ config.host, config.port });

    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buf);
    var stream_writer = stream.writer(io, &write_buf);
    var writer_mutex: Io.Mutex = .init;

    var descriptor: [hidraw.MAX_REPORT_DESCRIPTOR_SIZE]u8 = undefined;
    const device_info = try device.deviceInfo(&descriptor);
    var device_info_payload: [protocol.DEVICE_INFO_HEADER_SIZE + hidraw.MAX_REPORT_DESCRIPTOR_SIZE]u8 = undefined;
    const encoded_device_info = protocol.encodeDeviceInfo(.{
        .bus = device_info.bus,
        .vendor = device_info.vendor,
        .product = device_info.product,
        .descriptor = descriptor[0..device_info.descriptor_len],
    }, &device_info_payload) orelse return error.InvalidDeviceInfo;
    try protocol.sendFrame(&stream_writer.interface, .device_info, encoded_device_info);
    config.log(.info, "sent device info bus=0x{x:0>4} vid=0x{x:0>4} pid=0x{x:0>4} rd_size={d}", .{
        device_info.bus,
        device_info.vendor,
        device_info.product,
        device_info.descriptor_len,
    });

    var bridge = Bridge{
        .io = io,
        .config = config,
        .device = &device,
        .stream = &stream,
        .writer = &stream_writer.interface,
        .writer_mutex = &writer_mutex,
    };

    var input_future = try io.concurrent(Bridge.inputLoop, .{&bridge});
    defer {
        const input_result = input_future.cancel(io);
        input_result catch |err| switch (err) {
            error.Canceled => {},
            else => config.log(.debug, "input loop: {s}", .{@errorName(err)}),
        };
    }

    try bridge.controlLoop(&stream_reader.interface);
}

fn connectToHost(io: Io, host: []const u8, port: u16) !Io.net.Stream {
    if (Io.net.IpAddress.resolve(io, host, port)) |address| {
        return address.connect(io, .{ .mode = .stream });
    } else |_| {}

    const host_name = try Io.net.HostName.init(host);
    var result_buf: [32]Io.net.HostName.LookupResult = undefined;
    var results: Io.Queue(Io.net.HostName.LookupResult) = .init(&result_buf);
    try Io.net.HostName.lookup(host_name, io, &results, .{ .port = port });

    var had_address = false;
    while (results.getOne(io)) |result| {
        const address = switch (result) {
            .address => |value| value,
            .canonical_name => continue,
        };
        had_address = true;
        return address.connect(io, .{ .mode = .stream }) catch continue;
    } else |err| switch (err) {
        error.Closed => return if (had_address) error.ConnectFailed else error.UnknownHost,
        error.Canceled => return error.Canceled,
    }
}

fn setTcpNoDelay(stream: *const Io.net.Stream) void {
    const linux = std.os.linux;
    const one: c_int = 1;
    _ = linux.setsockopt(
        stream.socket.handle,
        linux.IPPROTO.TCP,
        linux.TCP.NODELAY,
        @ptrCast(&one),
        @sizeOf(c_int),
    );
}

const Bridge = struct {
    io: Io,
    config: *const Config,
    device: *hidraw.Device,
    stream: *const Io.net.Stream,
    writer: *Io.Writer,
    writer_mutex: *Io.Mutex,

    /// hidraw -> network. Runs concurrently with controlLoop.
    fn inputLoop(bridge: *Bridge) !void {
        const io = bridge.io;
        const config = bridge.config;
        // On exit, unblock controlLoop's socket read so the session tears down.
        defer bridge.stream.shutdown(io, .both) catch {};

        var reports: u64 = 0;
        var report_buf: [hidraw.MAX_REPORT_SIZE]u8 = undefined;
        while (true) {
            const n = try bridge.device.readReport(io, &report_buf);
            if (n == 0) return error.DeviceClosed;
            reports += 1;
            if (reports == 1) {
                var head_buf: [23]u8 = undefined;
                config.log(.info, "first input report len={d} head={s}", .{
                    n,
                    core.log.hexHead(report_buf[0..n], &head_buf),
                });
            }
            try bridge.sendFrame(.input, report_buf[0..n]);
        }
    }

    /// network -> hidraw. Runs on the main task; returns when the server
    /// disconnects or the socket is shut down by inputLoop.
    fn controlLoop(bridge: *Bridge, reader: *Io.Reader) !void {
        const io = bridge.io;
        const config = bridge.config;
        var payload_buf: [protocol.MAX_FRAME_PAYLOAD]u8 = undefined;
        while (true) {
            const frame = try protocol.readFrame(reader, &payload_buf) orelse return;
            switch (frame.frame_type) {
                .output => {
                    if (frame.payload.len < 2) continue;
                    const report_type = frame.payload[0];
                    const data = frame.payload[1..];
                    config.log(.debug, "output rtype={d} len={d}", .{ report_type, data.len });
                    bridge.device.writeReport(io, data) catch |err| {
                        config.log(.warning, "output write failed: {s}", .{@errorName(err)});
                    };
                },
                .get_report => {
                    if (frame.payload.len < 6) continue;
                    const request_id = bytes.readU32Le(frame.payload, 0);
                    const report_number = frame.payload[4];
                    const report_type = frame.payload[5];

                    var report_buf: [hidraw.MAX_REPORT_SIZE]u8 = undefined;
                    report_buf[0] = report_number;
                    const result = bridge.device.getReport(report_type, &report_buf);

                    var reply: [6 + hidraw.MAX_REPORT_SIZE]u8 = undefined;
                    bytes.writeU32Le(&reply, 0, request_id);
                    switch (result) {
                        .len => |len| {
                            config.log(.debug, "get_report id={d} rnum=0x{x:0>2} len={d}", .{ request_id, report_number, len });
                            bytes.writeU16Le(&reply, 4, 0);
                            @memcpy(reply[6 .. 6 + len], report_buf[0..len]);
                            try bridge.sendFrame(.get_report_reply, reply[0 .. 6 + len]);
                        },
                        .err => |errno| {
                            config.log(.warning, "get_report id={d} rnum=0x{x:0>2} errno={d}", .{ request_id, report_number, errno });
                            bytes.writeU16Le(&reply, 4, errno);
                            try bridge.sendFrame(.get_report_reply, reply[0..6]);
                        },
                    }
                },
                .set_report => {
                    if (frame.payload.len < 6) continue;
                    const request_id = bytes.readU32Le(frame.payload, 0);
                    const report_number = frame.payload[4];
                    const report_type = frame.payload[5];
                    const data = frame.payload[6..];

                    const errno = if (data.len == 0)
                        @as(u16, @intFromEnum(std.os.linux.E.INVAL))
                    else
                        bridge.device.setReport(io, report_type, data);
                    if (errno == 0) {
                        config.log(.debug, "set_report id={d} rnum=0x{x:0>2} len={d}", .{ request_id, report_number, data.len });
                    } else {
                        config.log(.warning, "set_report id={d} rnum=0x{x:0>2} errno={d}", .{ request_id, report_number, errno });
                    }

                    var reply: [6]u8 = undefined;
                    bytes.writeU32Le(&reply, 0, request_id);
                    bytes.writeU16Le(&reply, 4, errno);
                    try bridge.sendFrame(.set_report_reply, &reply);
                },
                else => config.log(.debug, "ignoring frame type=0x{x:0>2} len={d}", .{ @intFromEnum(frame.frame_type), frame.payload.len }),
            }
        }
    }

    fn sendFrame(bridge: *Bridge, frame_type: protocol.FrameType, payload: []const u8) !void {
        try bridge.writer_mutex.lock(bridge.io);
        defer bridge.writer_mutex.unlock(bridge.io);
        try protocol.sendFrame(bridge.writer, frame_type, payload);
    }
};

test {
    std.testing.refAllDecls(@This());
    _ = hidraw;
}
