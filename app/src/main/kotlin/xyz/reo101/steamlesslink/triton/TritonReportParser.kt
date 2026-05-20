package xyz.reo101.steamlesslink.triton

import xyz.reo101.steamlesslink.util.i16Le
import xyz.reo101.steamlesslink.util.u16Le
import xyz.reo101.steamlesslink.util.u32Le
import xyz.reo101.steamlesslink.util.u8

object TritonReportParser {
    const val REPORT_ID_USB_STATE = 0x42
    const val REPORT_ID_BLE_STATE = 0x45
    const val MIN_BASIC_REPORT_BYTES = 18
    const val MIN_PAD_REPORT_BYTES = 30

    fun parse(report: ByteArray, length: Int = report.size): TritonRawState? {
        if (length < MIN_BASIC_REPORT_BYTES) return null
        val reportId = report.u8(0)
        if (reportId != REPORT_ID_USB_STATE && reportId != REPORT_ID_BLE_STATE) return null

        return TritonRawState(
            reportId = reportId,
            sequence = report.u8(1),
            buttons = report.u32Le(2),
            leftTrigger = report.i16Le(6),
            rightTrigger = report.i16Le(8),
            leftStickX = report.i16Le(10),
            leftStickY = report.i16Le(12),
            rightStickX = report.i16Le(14),
            rightStickY = report.i16Le(16),
            leftPadX = if (length >= MIN_PAD_REPORT_BYTES) report.i16Le(18) else null,
            leftPadY = if (length >= MIN_PAD_REPORT_BYTES) report.i16Le(20) else null,
            leftPadPressure = if (length >= MIN_PAD_REPORT_BYTES) report.u16Le(22).toUShort() else null,
            rightPadX = if (length >= MIN_PAD_REPORT_BYTES) report.i16Le(24) else null,
            rightPadY = if (length >= MIN_PAD_REPORT_BYTES) report.i16Le(26) else null,
            rightPadPressure = if (length >= MIN_PAD_REPORT_BYTES) report.u16Le(28).toUShort() else null,
            rawReport = report.copyOf(length),
        )
    }
}
