package xyz.reo101.steamlesslink.triton

import xyz.reo101.steamlesslink.util.putI16Le
import xyz.reo101.steamlesslink.util.putU32Le
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TritonReportParserTest {
    @Test
    fun parsesUsbStateReport() {
        val report = ByteArray(64)
        report[0] = 0x42
        report[1] = 0x7f
        report.putU32Le(2, SteamControllerButtons.A or SteamControllerButtons.DPAD_UP)
        report.putI16Le(6, 1234)
        report.putI16Le(8, 2345)
        report.putI16Le(10, -1000)
        report.putI16Le(12, 1000)
        report.putI16Le(14, -2000)
        report.putI16Le(16, 2000)
        report.putI16Le(18, 11)
        report.putI16Le(20, 22)
        report.putI16Le(22, 333)
        report.putI16Le(24, 44)
        report.putI16Le(26, 55)
        report.putI16Le(28, 666)

        val state = requireNotNull(TritonReportParser.parse(report))

        assertEquals(0x42, state.reportId)
        assertEquals(0x7f, state.sequence)
        assertEquals(SteamControllerButtons.A or SteamControllerButtons.DPAD_UP, state.buttons)
        assertEquals(1234.toShort(), state.leftTrigger)
        assertEquals(2345.toShort(), state.rightTrigger)
        assertEquals((-1000).toShort(), state.leftStickX)
        assertEquals(1000.toShort(), state.leftStickY)
        assertEquals((-2000).toShort(), state.rightStickX)
        assertEquals(2000.toShort(), state.rightStickY)
        assertEquals(11.toShort(), state.leftPadX)
        assertEquals(22.toShort(), state.leftPadY)
        assertEquals(333.toUShort(), state.leftPadPressure)
        assertEquals(44.toShort(), state.rightPadX)
        assertEquals(55.toShort(), state.rightPadY)
        assertEquals(666.toUShort(), state.rightPadPressure)
    }

    @Test
    fun parsesBleStateReportWithExplicitLength() {
        val report = ByteArray(64) { 0x55 }
        report[0] = TritonReportParser.REPORT_ID_BLE_STATE.toByte()
        report[1] = 0x20
        report.putU32Le(2, SteamControllerButtons.X)
        report.putI16Le(6, -1)
        report.putI16Le(8, 0x4000)
        report.putI16Le(10, Short.MIN_VALUE.toInt())
        report.putI16Le(12, Short.MAX_VALUE.toInt())
        report.putI16Le(14, -123)
        report.putI16Le(16, 456)

        val state = requireNotNull(TritonReportParser.parse(report, length = 46))

        assertEquals(TritonReportParser.REPORT_ID_BLE_STATE, state.reportId)
        assertEquals(0x20, state.sequence)
        assertEquals(SteamControllerButtons.X, state.buttons)
        assertEquals((-1).toShort(), state.leftTrigger)
        assertEquals(0x4000.toShort(), state.rightTrigger)
        assertEquals(Short.MIN_VALUE, state.leftStickX)
        assertEquals(Short.MAX_VALUE, state.leftStickY)
        assertEquals((-123).toShort(), state.rightStickX)
        assertEquals(456.toShort(), state.rightStickY)
        assertEquals(46, state.rawReport.size)
    }

    @Test
    fun ignoresUnknownOrShortReports() {
        assertNull(TritonReportParser.parse(byteArrayOf(0x01, 0x02)))
        assertNull(TritonReportParser.parse(ByteArray(18) { if (it == 0) 0x43 else 0 }))
    }

}
