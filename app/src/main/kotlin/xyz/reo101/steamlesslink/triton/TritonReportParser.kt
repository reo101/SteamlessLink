package xyz.reo101.steamlesslink.triton

import xyz.reo101.steamlesslink.util.i16Le
import xyz.reo101.steamlesslink.util.u16Le
import xyz.reo101.steamlesslink.util.u32Le
import xyz.reo101.steamlesslink.util.u8

object TritonReportParser {
    const val REPORT_ID_USB_STATE = 0x42
    const val REPORT_ID_BLE_STATE = 0x45
    const val REPORT_ID_BLE_TIMESTAMP_STATE = 0x47
    const val MIN_BASIC_REPORT_BYTES = 18

    fun parse(report: ByteArray, length: Int = report.size): TritonRawState? {
        if (length !in MIN_BASIC_REPORT_BYTES..report.size) return null
        val reportId = report.u8(0)
        if (reportId != REPORT_ID_USB_STATE && reportId != REPORT_ID_BLE_STATE && reportId != REPORT_ID_BLE_TIMESTAMP_STATE) return null

        val padOffset = if (reportId == REPORT_ID_BLE_TIMESTAMP_STATE) 20 else 18
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
            leftPadX = if (length >= padOffset + 12) report.i16Le(padOffset) else null,
            leftPadY = if (length >= padOffset + 12) report.i16Le(padOffset + 2) else null,
            leftPadPressure = if (length >= padOffset + 12) report.u16Le(padOffset + 4).toUShort() else null,
            rightPadX = if (length >= padOffset + 12) report.i16Le(padOffset + 6) else null,
            rightPadY = if (length >= padOffset + 12) report.i16Le(padOffset + 8) else null,
            rightPadPressure = if (length >= padOffset + 12) report.u16Le(padOffset + 10).toUShort() else null,
            rawReport = report.copyOf(length),
        )
    }
}
