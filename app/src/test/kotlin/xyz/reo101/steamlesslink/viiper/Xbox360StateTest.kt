package xyz.reo101.steamlesslink.viiper

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class Xbox360StateTest {
    @Test
    fun encodesViiperPacketInLittleEndianOrder() {
        val state = Xbox360State(
            buttons = 0x11223344u,
            leftTrigger = 0x55u,
            rightTrigger = 0x66u,
            leftStickX = 0x1234,
            leftStickY = (-2).toShort(),
            rightStickX = Short.MIN_VALUE,
            rightStickY = Short.MAX_VALUE,
        )

        val packet = state.toViiperPacket()

        assertEquals(Xbox360State.PACKET_SIZE, packet.size)
        assertArrayEquals(
            byteArrayOf(
                0x44, 0x33, 0x22, 0x11,
                0x55, 0x66,
                0x34, 0x12,
                0xfe.toByte(), 0xff.toByte(),
                0x00, 0x80.toByte(),
                0xff.toByte(), 0x7f,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            ),
            packet,
        )
    }
}
