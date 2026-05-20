package xyz.reo101.steamlesslink.raw

import xyz.reo101.steamlesslink.util.hex
import xyz.reo101.steamlesslink.util.i32Le
import xyz.reo101.steamlesslink.util.putI32Le
import xyz.reo101.steamlesslink.util.putU16Le
import xyz.reo101.steamlesslink.util.u8
import java.io.Closeable
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean

class UhidRawClient(
    host: String,
    port: Int,
    private val onStatus: (String) -> Unit,
    private val onGetReport: (requestId: Int, reportNumber: Int, reportType: Int) -> ByteArray?,
    private val onSetReport: (requestId: Int, reportNumber: Int, reportType: Int, data: ByteArray) -> Boolean,
    private val onOutputReport: (reportType: Int, data: ByteArray) -> Boolean,
) : Closeable {
    private val socket = Socket(host, port).apply {
        tcpNoDelay = true
        soTimeout = 0
    }
    private val input = DataInputStream(socket.getInputStream())
    private val output = DataOutputStream(socket.getOutputStream())
    private val closed = AtomicBoolean(false)
    private val reader = Thread(::readLoop, "steamless-uhid-raw-reader").apply {
        isDaemon = true
        start()
    }
    private var controlRequestCount = 0L

    fun sendInputReport(report: ByteArray, length: Int = report.size) {
        if (closed.get()) return
        val safeLength = length.coerceIn(0, report.size).coerceAtMost(65535)
        sendFrame(FRAME_INPUT, report.copyOf(safeLength))
    }

    private fun readLoop() {
        runCatching {
            while (!closed.get()) {
                val type = input.readUnsignedByte()
                val length = input.readUnsignedShort()
                val payload = ByteArray(length)
                input.readFully(payload)
                when (type) {
                    FRAME_OUTPUT -> handleOutputReport(payload)
                    FRAME_GET_REPORT -> handleGetReport(payload)
                    FRAME_SET_REPORT -> handleSetReport(payload)
                    else -> onStatus("UHID frame type=0x%02x len=$length".format(type))
                }
            }
        }.onFailure { error ->
            if (!closed.get()) onStatus("UHID raw reader stopped: ${error.message ?: error::class.java.simpleName}")
        }
    }

    private fun handleOutputReport(payload: ByteArray) {
        if (payload.isEmpty()) return
        val reportType = payload.u8(0)
        val data = payload.copyOfRange(1, payload.size)
        logControl("UHID output report rtype=$reportType len=${data.size} head=${data.hex(8)}")
        val ok = runCatching { onOutputReport(reportType, data) }.getOrDefault(false)
        if (!ok) logControl("UHID output report write failed rtype=$reportType len=${data.size}")
    }

    private fun handleGetReport(payload: ByteArray) {
        if (payload.size < 6) return
        val requestId = payload.i32Le(0)
        val reportNumber = payload.u8(4)
        val reportType = payload.u8(5)
        logControl("UHID get-report id=$requestId rnum=0x%02x rtype=$reportType".format(reportNumber))
        val report = runCatching { onGetReport(requestId, reportNumber, reportType) }.getOrNull()
        val err = if (report == null) 5 else 0
        val data = report ?: ByteArray(0)
        sendFrame(FRAME_GET_REPORT_REPLY, ByteArray(6 + data.size).also { out ->
            out.putI32Le(0, requestId)
            out.putU16Le(4, err)
            data.copyInto(out, destinationOffset = 6)
        })
    }

    private fun handleSetReport(payload: ByteArray) {
        if (payload.size < 6) return
        val requestId = payload.i32Le(0)
        val reportNumber = payload.u8(4)
        val reportType = payload.u8(5)
        val data = payload.copyOfRange(6, payload.size)
        logControl("UHID set-report id=$requestId rnum=0x%02x rtype=$reportType len=${data.size} head=${data.hex(8)}".format(reportNumber))
        val ok = runCatching { onSetReport(requestId, reportNumber, reportType, data) }.getOrDefault(false)
        sendFrame(FRAME_SET_REPORT_REPLY, ByteArray(6).also { out ->
            out.putI32Le(0, requestId)
            out.putU16Le(4, if (ok) 0 else 5)
        })
    }

    private fun sendFrame(type: Int, payload: ByteArray) {
        synchronized(output) {
            output.writeByte(type)
            output.writeShort(payload.size.coerceAtMost(65535))
            output.write(payload, 0, payload.size.coerceAtMost(65535))
            output.flush()
        }
    }

    private fun logControl(message: String) {
        controlRequestCount += 1
        if (controlRequestCount <= 8 || controlRequestCount % 100L == 0L) onStatus(message)
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        runCatching { socket.close() }
    }

    companion object {
        private const val FRAME_INPUT = 0x01
        private const val FRAME_GET_REPORT_REPLY = 0x02
        private const val FRAME_SET_REPORT_REPLY = 0x03
        private const val FRAME_OUTPUT = 0x81
        private const val FRAME_GET_REPORT = 0x82
        private const val FRAME_SET_REPORT = 0x83
    }
}
