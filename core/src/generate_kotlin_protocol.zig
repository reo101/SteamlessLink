const std = @import("std");
const extended_gamepad = @import("extended_gamepad.zig");
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
        \\// Generated from `core/src/{{extended_gamepad,generic_gamepad,protocol,triton}}.zig`. Do not edit.
        \\package xyz.reo101.steamlesslink.protocol
        \\
        \\internal object RawProtocol {{
    , .{});
    inline for (@typeInfo(protocol.FrameType).@"enum".fields) |field| {
        var name: [field.name.len]u8 = undefined;
        for (field.name, 0..) |byte, index| name[index] = std.ascii.toUpper(byte);
        try writer.interface.print("\n    const val FRAME_{s} = 0x{x:0>2}", .{ name, field.value });
    }
    inline for (.{ "DEVICE_FRAME_HEADER_SIZE", "DEVICE_FRAME_TYPE_OFFSET", "DEVICE_BUNDLE_HEADER_SIZE", "DEVICE_BUNDLE_ENTRY_SIZE" }) |name| {
        try writer.interface.print("\n    const val {s} = {d}", .{ name, @field(protocol, name) });
    }
    try writer.interface.print(
        \\
        \\    const val FRAME_HEADER_SIZE = {d}
        \\    const val MAX_FRAME_PAYLOAD = {d}
        \\    const val MAX_DEVICES = {d}
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
        \\    fun encodeDeviceBundle(devices: List<ByteArray>): ByteArray {{
        \\        require(devices.size in 1..MAX_DEVICES)
        \\        val length = DEVICE_BUNDLE_HEADER_SIZE + devices.sumOf {{ DEVICE_BUNDLE_ENTRY_SIZE + it.size }}
        \\        require(length <= MAX_FRAME_PAYLOAD)
        \\        val buffer = java.nio.ByteBuffer.allocate(length).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        \\        buffer.put(devices.size.toByte())
        \\        for (info in devices) {{
        \\            require(info.size in 1..MAX_FRAME_PAYLOAD)
        \\            buffer.putShort(info.size.toShort()).put(info)
        \\        }}
        \\        return buffer.array()
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
        protocol.FRAME_HEADER_SIZE,
        protocol.MAX_FRAME_PAYLOAD,
        protocol.MAX_DEVICES,
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
    try writer.interface.print(
        \\
        \\internal object ExtendedGamepadProtocol {{
        \\    const val PACKET_SIZE = {d}
        \\    const val SENSOR_SIZE = {d}
    , .{ extended_gamepad.PACKET_SIZE, extended_gamepad.SENSOR_SIZE });
    inline for (@typeInfo(extended_gamepad.Sensor).@"struct".decls) |decl| {
        try writer.interface.print("\n    const val SENSOR_{s} = {d}", .{ decl.name, @field(extended_gamepad.Sensor, decl.name) });
    }
    try writer.interface.writeAll("\n    val REPORT_SIZES = intArrayOf(");
    for (extended_gamepad.REPORT_SIZES) |size| try writer.interface.print("{d}, ", .{size});
    try writer.interface.writeAll(")\n    val REPORT_DEVICES = intArrayOf(");
    for (extended_gamepad.REPORT_DEVICES) |device| try writer.interface.print("{d}, ", .{device});
    try writer.interface.writeAll(")\n    val NAMES = arrayOf(");
    for (extended_gamepad.NAMES) |name| try writer.interface.print("\n        \"{s}\",", .{name});
    try writer.interface.writeAll("\n    )\n    val DESCRIPTORS = arrayOf(\n");
    for (extended_gamepad.DESCRIPTORS) |descriptor| {
        try writer.interface.writeAll("        byteArrayOf(");
        for (descriptor, 0..) |byte, index| {
            if (index != 0) try writer.interface.writeAll(", ");
            if (index % 8 == 0) try writer.interface.writeAll("\n            ");
            try writer.interface.print("0x{x:0>2}.toByte()", .{byte});
        }
        try writer.interface.writeAll("\n        ),\n");
    }
    try writer.interface.writeAll("    )\n");
    inline for (.{ "EXTENDED_BLE_SETTINGS", "EXTENDED_USB_SETTINGS" }) |name| {
        try writer.interface.print("    val {s} = byteArrayOf(", .{name});
        for (@field(triton, name)) |byte| try writer.interface.print("0x{x:0>2}.toByte(), ", .{byte});
        try writer.interface.writeAll(")\n");
    }
    try writer.interface.writeAll("}\n");
    try writer.interface.flush();
}
