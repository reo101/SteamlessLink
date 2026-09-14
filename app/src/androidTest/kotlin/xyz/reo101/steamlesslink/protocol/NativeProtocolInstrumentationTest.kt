package xyz.reo101.steamlesslink.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import xyz.reo101.steamlesslink.util.putI32Le
import xyz.reo101.steamlesslink.util.putU16Le
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
    fun extendedMapperAndSessionHonorIndependentSensorControls() {
        assertTrue(NativeProtocol.loadError?.stackTraceToString(), NativeProtocol.isAvailable)
        for (id in listOf(0x42, 0x45, 0x47)) {
            val report = ByteArray(46).also {
                it[0] = id.toByte()
                it.putI32Le(2, 0x02020080) // L4, R4, left pad touch
                val pad = if (id == 0x47) 20 else 18
                it.putU16Le(pad, 0x8000)
                it.putU16Le(pad + 2, 0x7fff)
                it.putU16Le(pad + 4, 1234)
                it.putU16Le(34, 16384) // acceleration X = 1g
                it.putU16Le(42, 0x8000) // angular velocity Z = +2000 deg/s after rotation
            }
            val session = ExtendedGamepadSession()
            val basic = session.map(report, report.size)
            assertEquals(listOf(0, 1, 2), basic.map { it.first })
            assertArrayEquals(byteArrayOf(1, 1, 0, 0, 0, 0, 0xd2.toByte(), 4), basic[1].second)
            val acceleration = byteArrayOf(1, 0x3a, 0xa3.toByte(), 0x95.toByte(), 0, 0, 0, 0, 0, 0, 0, 0, 0)
            assertArrayEquals(acceleration, session.getReport(3, 1, 2)) // direct reads work while powered off
            assertTrue(session.setReport(3, 1, 0, byteArrayOf(1, 2, 1, 4, 0, 0, 0)))
            assertEquals(4, session.map(report, report.size).size)
            assertTrue(session.setReport(3, 2, 0, byteArrayOf(2, 2, 1, 4, 0, 0, 0)))
            val all = session.map(report, report.size)
            assertEquals(listOf(0, 1, 2, 3, 3), all.map { it.first })
            assertArrayEquals(acceleration, all[3].second)
            assertTrue(session.setReport(3, 1, 0, byteArrayOf(1, 1, 1, 4, 0, 0, 0)))
            assertEquals(4, session.map(report, report.size).size)
            assertTrue(session.setReport(3, 2, 0, byteArrayOf(2, 2, 5, 4, 0, 0, 0)))
            assertEquals(3, session.map(report, report.size).size)
            assertThrows(IllegalArgumentException::class.java) {
                NativeProtocol.tryMapTritonToExtendedGamepad(report, 45, ByteArray(ExtendedGamepadProtocol.PACKET_SIZE))
            }
        }
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
