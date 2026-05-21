package xyz.reo101.steamlesslink.util

import org.junit.Assert.assertEquals
import org.junit.Test

class BinaryTest {
    @Test
    fun readsUnsignedAndLittleEndianValues() {
        val bytes = byteArrayOf(
            0xef.toByte(),
            0xcd.toByte(),
            0xab.toByte(),
            0x89.toByte(),
            0x7f,
            0x80.toByte(),
        )

        assertEquals(0xef, bytes.u8(0))
        assertEquals(0xcdef, bytes.u16Le(0))
        assertEquals((-0x3211).toShort(), bytes.i16Le(0))
        assertEquals(0x89abcdef.toInt(), bytes.i32Le(0))
        assertEquals(0x89abcdefu, bytes.u32Le(0))
        assertEquals(0x7f, bytes.u8(4))
        assertEquals(0x80, bytes.u8(5))
    }

    @Test
    fun writesLittleEndianValues() {
        val bytes = ByteArray(12)

        bytes.putU16Le(0, 0xabcd)
        bytes.putI16Le(2, -2)
        bytes.putI32Le(4, 0x12345678)
        bytes.putU32Le(8, 0xff00aa55u)

        assertEquals("cd ab fe ff 78 56 34 12 55 aa 00 ff", bytes.hex())
    }

    @Test
    fun formatsHexWithLimit() {
        val bytes = byteArrayOf(0x00, 0x0f, 0x10, 0xff.toByte())

        assertEquals("00 0f 10 ff", bytes.hex())
        assertEquals("00 0f", bytes.hex(maxBytes = 2))
    }
}
