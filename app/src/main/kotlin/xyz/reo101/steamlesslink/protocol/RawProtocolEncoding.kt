package xyz.reo101.steamlesslink.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder

internal fun RawProtocol.encodeFrameHeader(type: Int, payloadLength: Int): Int {
    require(type in 0..0xff)
    return (type shl 16) or payloadLength.coerceIn(0, MAX_FRAME_PAYLOAD)
}

internal fun RawProtocol.encodeDeviceBundle(devices: List<ByteArray>): ByteArray {
    require(devices.size in 1..MAX_DEVICES)
    val length = DEVICE_BUNDLE_HEADER_SIZE + devices.sumOf { DEVICE_BUNDLE_ENTRY_SIZE + it.size }
    require(length <= MAX_FRAME_PAYLOAD)
    val buffer = ByteBuffer.allocate(length).order(ByteOrder.LITTLE_ENDIAN)
    buffer.put(devices.size.toByte())
    for (info in devices) {
        require(info.size in 1..MAX_FRAME_PAYLOAD)
        buffer.putShort(info.size.toShort()).put(info)
    }
    return buffer.array()
}

internal fun RawProtocol.encodeDeviceInfo(bus: Int, vendor: Int, product: Int, descriptor: ByteArray, name: String = ""): ByteArray {
    require(vendor in 0..0xffff && product in 0..0xffff)
    require(descriptor.size in 1..MAX_REPORT_DESCRIPTOR_SIZE)
    val nameBytes = name.toByteArray(Charsets.UTF_8)
    require(nameBytes.size <= MAX_DEVICE_NAME_SIZE && nameBytes.none { it == 0.toByte() })
    val descriptorEnd = DEVICE_INFO_HEADER_SIZE + descriptor.size
    val extensionSize = if (nameBytes.isEmpty()) 0 else 1 + nameBytes.size
    val buffer = ByteBuffer.allocate(descriptorEnd + extensionSize).order(ByteOrder.LITTLE_ENDIAN)
    buffer.putInt(bus).putShort(vendor.toShort()).putShort(product.toShort())
        .putShort(descriptor.size.toShort()).put(descriptor)
    if (nameBytes.isNotEmpty()) buffer.put(nameBytes.size.toByte()).put(nameBytes)
    return buffer.array()
}
