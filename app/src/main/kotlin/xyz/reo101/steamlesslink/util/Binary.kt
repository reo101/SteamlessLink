package xyz.reo101.steamlesslink.util

/** Small endian/hex helpers for the wire protocols used by SteamlessLink.
 *
 * Kotlin/JVM has `ByteBuffer`, but using it at every fixed report offset makes
 * parsing noisy and allocates wrappers in hot report paths. These helpers keep
 * the signed-byte masking in one place while call sites stay explicit about
 * width and byte order.
 */
internal fun ByteArray.u8(offset: Int): Int = this[offset].toInt() and 0xff

internal fun ByteArray.u16Le(offset: Int): Int =
    u8(offset) or (u8(offset + 1) shl 8)

internal fun ByteArray.i16Le(offset: Int): Short = u16Le(offset).toShort()

internal fun ByteArray.i32Le(offset: Int): Int =
    u8(offset) or
        (u8(offset + 1) shl 8) or
        (u8(offset + 2) shl 16) or
        (u8(offset + 3) shl 24)

internal fun ByteArray.u32Le(offset: Int): UInt = i32Le(offset).toUInt()

internal fun ByteArray.putU16Le(offset: Int, value: Int) {
    this[offset] = value.toByte()
    this[offset + 1] = (value ushr 8).toByte()
}

internal fun ByteArray.putI16Le(offset: Int, value: Int) = putU16Le(offset, value)

internal fun ByteArray.putI32Le(offset: Int, value: Int) {
    this[offset] = value.toByte()
    this[offset + 1] = (value ushr 8).toByte()
    this[offset + 2] = (value ushr 16).toByte()
    this[offset + 3] = (value ushr 24).toByte()
}

internal fun ByteArray.putU32Le(offset: Int, value: UInt) = putI32Le(offset, value.toInt())

internal fun ByteArray.hex(maxBytes: Int = size): String =
    take(maxBytes).joinToString(" ") { "%02x".format(it.toInt() and 0xff) }
