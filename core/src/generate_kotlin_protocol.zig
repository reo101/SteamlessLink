const std = @import("std");
const protocol = @import("protocol.zig");
const triton = @import("triton.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.InvalidArgument;

    const file = try std.Io.Dir.cwd().createFile(init.io, args[1], .{});
    defer file.close(init.io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(init.io, &buffer);
    try writer.interface.print(
        \\// Generated from `core/src/protocol.zig` and `core/src/triton.zig`. Do not edit.
        \\package xyz.reo101.steamlesslink.protocol
        \\
        \\internal object RawProtocol {{
        \\    const val FRAME_INPUT = 0x{x:0>2}
        \\    const val FRAME_GET_REPORT_REPLY = 0x{x:0>2}
        \\    const val FRAME_SET_REPORT_REPLY = 0x{x:0>2}
        \\    const val FRAME_DEVICE_INFO = 0x{x:0>2}
        \\    const val FRAME_GET_IROH_TICKET = 0x{x:0>2}
        \\    const val FRAME_OUTPUT = 0x{x:0>2}
        \\    const val FRAME_GET_REPORT = 0x{x:0>2}
        \\    const val FRAME_SET_REPORT = 0x{x:0>2}
        \\    const val FRAME_IROH_TICKET = 0x{x:0>2}
        \\    const val FRAME_HEADER_SIZE = {d}
        \\    const val MAX_FRAME_PAYLOAD = {d}
        \\
        \\    fun encodeFrameHeader(type: Int, payloadLength: Int): Int {{
        \\        require(type in 0..0xff)
        \\        val safeLength = payloadLength.coerceIn(0, MAX_FRAME_PAYLOAD)
        \\        return (type shl 16) or safeLength
        \\    }}
        \\}}
        \\
        \\internal object TritonProtocol {{
        \\    const val VIIPER_PACKET_SIZE = {d}
        \\}}
        \\
    , .{
        protocol.FRAME_INPUT,
        protocol.FRAME_GET_REPORT_REPLY,
        protocol.FRAME_SET_REPORT_REPLY,
        protocol.FRAME_DEVICE_INFO,
        protocol.FRAME_GET_IROH_TICKET,
        protocol.FRAME_OUTPUT,
        protocol.FRAME_GET_REPORT,
        protocol.FRAME_SET_REPORT,
        protocol.FRAME_IROH_TICKET,
        protocol.FRAME_HEADER_SIZE,
        protocol.MAX_FRAME_PAYLOAD,
        triton.VIIPER_PACKET_SIZE,
    });
    try writer.interface.flush();
}
