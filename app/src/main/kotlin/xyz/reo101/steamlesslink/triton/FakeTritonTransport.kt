package xyz.reo101.steamlesslink.triton

import java.io.Closeable
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Debug/test transport that behaves like a tiny Steam Controller report source.
 *
 * It lets emulator tests exercise the Android service, TCP raw UHID client, and
 * lifecycle without requiring BLE or USB controller hardware in the emulator.
 */
class FakeTritonTransport(
    private val onReport: (report: ByteArray, length: Int) -> Unit,
    private val onStatus: (String) -> Unit,
    private val intervalMs: Long = DEFAULT_INTERVAL_MS,
) : Closeable {
    private val closed = AtomicBoolean(false)
    private val thread = Thread(::runLoop, "fake-triton-transport").apply {
        isDaemon = true
    }
    private var sequence = 0
    private var outputReportCount = 0L
    private var featureWriteCount = 0L

    fun start() {
        onStatus("Fake Triton transport started interval=${intervalMs}ms")
        thread.start()
    }

    fun readHidFeatureReport(reportNumber: Int): ByteArray {
        onStatus("Fake feature read report=0x%02x".format(reportNumber))
        return ByteArray(FEATURE_REPORT_SIZE).also { report ->
            report[0] = reportNumber.toByte()
        }
    }

    fun writeHidFeatureReport(data: ByteArray): Boolean {
        featureWriteCount += 1
        if (featureWriteCount <= 8 || featureWriteCount % 100L == 0L) {
            onStatus("Fake feature write count=$featureWriteCount len=${data.size}")
        }
        return true
    }

    fun enqueueHidOutputReport(data: ByteArray): Boolean {
        outputReportCount += 1
        if (outputReportCount <= 8 || outputReportCount % 100L == 0L) {
            onStatus("Fake output report count=$outputReportCount len=${data.size}")
        }
        return true
    }

    private fun runLoop() {
        while (!closed.get()) {
            val report = makeReport(sequence)
            onReport(report, report.size)
            sequence = (sequence + 1) and 0xff
            try {
                Thread.sleep(intervalMs)
            } catch (_: InterruptedException) {
                if (closed.get()) return
            }
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        thread.interrupt()
        onStatus("Fake Triton transport stopped")
    }

    companion object {
        const val DEFAULT_INTERVAL_MS = 4L
        const val INPUT_REPORT_ID = 0x45
        const val INPUT_REPORT_SIZE = 46
        private const val FEATURE_REPORT_SIZE = 16
        fun makeReport(sequence: Int): ByteArray = ByteArray(INPUT_REPORT_SIZE).also { report ->
            report[0] = INPUT_REPORT_ID.toByte()
            for (index in 1 until report.size) report[index] = index.toByte()
            report[1] = sequence.toByte()
        }
    }
}
