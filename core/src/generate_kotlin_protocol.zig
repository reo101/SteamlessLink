const std = @import("std");
const generic_gamepad = @import("generic_gamepad.zig");
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
        \\// Generated from `core/src/generic_gamepad.zig`, `protocol.zig`, and `triton.zig`. Do not edit.
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
        \\    const val MAX_REPORT_DESCRIPTOR_SIZE = {d}
        \\    const val MAX_DEVICE_NAME_SIZE = {d}
        \\    const val DEVICE_INFO_HEADER_SIZE = {d}
        \\
        \\    fun encodeFrameHeader(type: Int, payloadLength: Int): Int {{
        \\        require(type in 0..0xff)
        \\        val safeLength = payloadLength.coerceIn(0, MAX_FRAME_PAYLOAD)
        \\        return (type shl 16) or safeLength
        \\    }}
        \\
        \\    fun encodeDeviceInfo(
        \\        bus: Int,
        \\        vendor: Int,
        \\        product: Int,
        \\        descriptor: ByteArray,
        \\        name: String = "",
        \\    ): ByteArray {{
        \\        require(vendor in 0..0xffff)
        \\        require(product in 0..0xffff)
        \\        require(descriptor.size in 1..MAX_REPORT_DESCRIPTOR_SIZE)
        \\        val nameBytes = name.toByteArray(Charsets.UTF_8)
        \\        require(nameBytes.size <= MAX_DEVICE_NAME_SIZE && nameBytes.none {{ it == 0.toByte() }})
        \\        val descriptorEnd = DEVICE_INFO_HEADER_SIZE + descriptor.size
        \\        val extensionSize = if (nameBytes.isEmpty()) 0 else 1 + nameBytes.size
        \\        return ByteArray(descriptorEnd + extensionSize).also {{ out ->
        \\            out[0] = bus.toByte()
        \\            out[1] = (bus ushr 8).toByte()
        \\            out[2] = (bus ushr 16).toByte()
        \\            out[3] = (bus ushr 24).toByte()
        \\            out[4] = vendor.toByte()
        \\            out[5] = (vendor ushr 8).toByte()
        \\            out[6] = product.toByte()
        \\            out[7] = (product ushr 8).toByte()
        \\            out[8] = descriptor.size.toByte()
        \\            out[9] = (descriptor.size ushr 8).toByte()
        \\            descriptor.copyInto(out, destinationOffset = DEVICE_INFO_HEADER_SIZE)
        \\            if (nameBytes.isNotEmpty()) {{
        \\                out[descriptorEnd] = nameBytes.size.toByte()
        \\                nameBytes.copyInto(out, destinationOffset = descriptorEnd + 1)
        \\            }}
        \\        }}
        \\    }}
        \\}}
        \\
        \\internal object Xbox360Protocol {{
        \\    const val PACKET_SIZE = {d}
        \\}}
        \\
        \\internal object GenericGamepadProtocol {{
        \\    const val BUS_USB = 0x{x:0>4}
        \\    const val VENDOR_ID = 0x{x:0>4}
        \\    const val PRODUCT_ID = 0x{x:0>4}
        \\    const val DEVICE_NAME = "{s}"
        \\    const val INPUT_REPORT_ID = 0x{x:0>2}
        \\    const val INPUT_REPORT_SIZE = {d}
        \\    val REPORT_DESCRIPTOR = byteArrayOf(
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
        protocol.MAX_REPORT_DESCRIPTOR_SIZE,
        protocol.MAX_DEVICE_NAME_SIZE,
        protocol.DEVICE_INFO_HEADER_SIZE,
        triton.XBOX360_PACKET_SIZE,
        generic_gamepad.BUS_USB,
        generic_gamepad.VENDOR_ID,
        generic_gamepad.PRODUCT_ID,
        generic_gamepad.NAME,
        generic_gamepad.INPUT_REPORT_ID,
        generic_gamepad.INPUT_REPORT_SIZE,
    });
    for (generic_gamepad.REPORT_DESCRIPTOR, 0..) |byte, index| {
        if (index != 0) try writer.interface.writeAll(", ");
        if (index != 0 and index % 8 == 0) try writer.interface.writeAll("\n        ");
        try writer.interface.print("0x{x:0>2}.toByte()", .{byte});
    }
    try writer.interface.writeAll("\n    )\n}\n");
    try writer.interface.flush();
}
