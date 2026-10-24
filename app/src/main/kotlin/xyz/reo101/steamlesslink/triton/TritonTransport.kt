package xyz.reo101.steamlesslink.triton

import java.io.Closeable

/** Normalized numbered HID reports. Report types use Linux UHID numbering. */
interface TritonTransport : Closeable {
    val deviceInfo: ByteArray? get() = null
    fun start()
    fun awaitReady(timeoutMs: Long): Boolean
    fun readHidReport(reportNumber: Int, reportType: Int): ByteArray?
    fun writeHidReport(reportNumber: Int, reportType: Int, report: ByteArray): Boolean
    fun sendOutputReport(reportType: Int, report: ByteArray): Boolean =
        report.isNotEmpty() && writeHidReport(report[0].toInt() and 0xff, reportType, report)
}
