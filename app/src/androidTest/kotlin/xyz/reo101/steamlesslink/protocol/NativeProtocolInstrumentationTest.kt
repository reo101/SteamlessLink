package xyz.reo101.steamlesslink.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeProtocolInstrumentationTest {
    @Test
    fun mapsTritonReportToTheBundledXbox360Packet() {
        val report = ByteArray(18)
        report[0] = 0x45
        report[2] = 0x01 // Steam Controller A
        report[8] = 0xff.toByte()
        report[9] = 0x7f // right trigger, little-endian 32767
        report[10] = 0x64 // left stick X, little-endian 100

        val packet = ByteArray(Xbox360Protocol.PACKET_SIZE)
        assertTrue(NativeProtocol.isAvailable)
        assertTrue(NativeProtocol.tryMapTritonToXbox360(report, report.size, packet))
        assertArrayEquals(
            byteArrayOf(
                0x00, 0x10, 0x00, 0x00, // Xbox A
                0x00, 0xff.toByte(), // triggers
                0x64, 0x00, // left stick X
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // remaining sticks
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            ),
            packet,
        )
    }

    @Test
    fun mapsTritonReportToTheBundledGenericGamepadProfile() {
        val report = ByteArray(18)
        report[0] = 0x45
        report[2] = 0x01 // Steam Controller A
        report[8] = 0xff.toByte()
        report[9] = 0x7f // right trigger, little-endian 32767
        report[10] = 0x64 // left stick X, little-endian 100

        val packet = ByteArray(GenericGamepadProtocol.INPUT_REPORT_SIZE)
        assertTrue(NativeProtocol.isAvailable)
        assertTrue(NativeProtocol.tryMapTritonToGenericGamepad(report, report.size, packet))
        assertArrayEquals(
            byteArrayOf(
                0x01, // report ID
                0x01, 0x00, // BTN_SOUTH
                0x08, // neutral hat switch
                0x80.toByte(), 0x80.toByte(), // left stick
                0x80.toByte(), 0x80.toByte(), // right stick
                0x00, 0xff.toByte(), // triggers
            ),
            packet,
        )
    }
}
