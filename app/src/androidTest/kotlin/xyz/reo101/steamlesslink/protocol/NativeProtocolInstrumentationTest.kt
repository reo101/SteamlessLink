package xyz.reo101.steamlesslink.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeProtocolInstrumentationTest {
    @Test
    fun mapsTritonReportThroughTheBundledZigLibrary() {
        val report = ByteArray(18)
        report[0] = 0x45
        report[2] = 0x01 // Steam Controller A
        report[8] = 0xff.toByte()
        report[9] = 0x7f // right trigger, little-endian 32767
        report[10] = 0x64 // left stick X, little-endian 100

        val packet = ByteArray(TritonProtocol.VIIPER_PACKET_SIZE)
        assertTrue(NativeProtocol.isAvailable)
        assertTrue(NativeProtocol.tryMapTritonToViiper(report, report.size, packet))
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
}
