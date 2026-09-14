package xyz.reo101.steamlesslink.raw

import xyz.reo101.steamlesslink.protocol.RawProtocol
import xyz.reo101.steamlesslink.util.hex
import xyz.reo101.steamlesslink.util.i32Le
import xyz.reo101.steamlesslink.util.putI32Le
import xyz.reo101.steamlesslink.util.putU16Le
import xyz.reo101.steamlesslink.util.u8
import java.io.Closeable
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

fun fetchIrohTicket(host: String, port: Int, connectTimeoutMs: Int = 10_000): String = Socket().use { socket ->
    socket.tcpNoDelay = true
    socket.soTimeout = connectTimeoutMs
    socket.connect(InetSocketAddress(host, port), connectTimeoutMs)
    val output = DataOutputStream(socket.getOutputStream())
    writeFrameHeader(output, RawProtocol.FRAME_GET_IROH_TICKET, 0)
    output.flush()

    val input = DataInputStream(socket.getInputStream())
    val type = input.readUnsignedByte()
    val length = input.readUnsignedShort()
    if (type != RawProtocol.FRAME_IROH_TICKET || length == 0) throw IOException("Iroh ticket is unavailable")
    ByteArray(length).also(input::readFully).toString(Charsets.UTF_8).trim().also { ticket ->
        if (ticket.isEmpty()) throw IOException("Iroh ticket is unavailable")
    }
}

private fun writeFrameHeader(output: DataOutputStream, type: Int, payloadLength: Int): Int {
    val header = RawProtocol.encodeFrameHeader(type, payloadLength)
    output.writeByte(header ushr 16)
    output.writeShort(header and RawProtocol.MAX_FRAME_PAYLOAD)
    return header and RawProtocol.MAX_FRAME_PAYLOAD
}

class UhidRawClient(
    private val connection: RawUhidConnection,
    private val onStatus: (String) -> Unit,
    private val onGetReport: (device: Int, requestId: Int, reportNumber: Int, reportType: Int) -> ByteArray?,
    private val onSetReport: (device: Int, requestId: Int, reportNumber: Int, reportType: Int, data: ByteArray) -> Boolean,
    private val onOutputReport: (device: Int, reportType: Int, data: ByteArray) -> Boolean,
    private val initialDeviceInfo: ByteArray? = null,
    private val initialDevices: List<ByteArray> = emptyList(),
) : Closeable {
    constructor(
        host: String,
        port: Int,
        onStatus: (String) -> Unit,
        onGetReport: (device: Int, requestId: Int, reportNumber: Int, reportType: Int) -> ByteArray?,
        onSetReport: (device: Int, requestId: Int, reportNumber: Int, reportType: Int, data: ByteArray) -> Boolean,
        onOutputReport: (device: Int, reportType: Int, data: ByteArray) -> Boolean,
        initialDeviceInfo: ByteArray? = null,
        initialDevices: List<ByteArray> = emptyList(),
        connectTimeoutMs: Int = 10_000,
    ) : this(
        connection = RawUhidConnection.tcp(host, port, connectTimeoutMs),
        onStatus = onStatus,
        onGetReport = onGetReport,
        onSetReport = onSetReport,
        onOutputReport = onOutputReport,
        initialDeviceInfo = initialDeviceInfo,
        initialDevices = initialDevices,
    )

    private val input = DataInputStream(connection.input)
    private val output = DataOutputStream(connection.output)
    private val closed = AtomicBoolean(false)
    private val closedLatch = CountDownLatch(1)
    private val inputQueueLock = Object()
    // Queue complete samples, not individual companion reports: congestion must
    // never starve the gamepad or drop every touch-release behind sensor traffic.
    private val queuedInputReports = ArrayDeque<List<Pair<Int, ByteArray>>>()
    private val bundleReady = CountDownLatch(1)
    @Volatile private var bundleAccepted = false

    init {
        try {
            require(initialDevices.size <= RawProtocol.MAX_DEVICES)
            require(initialDevices.isEmpty() || initialDeviceInfo == null)
            if (initialDevices.isNotEmpty()) {
                sendFrame(RawProtocol.FRAME_DEVICE_BUNDLE, RawProtocol.encodeDeviceBundle(initialDevices))
            }
            initialDeviceInfo?.let { payload ->
                require(payload.size <= RawProtocol.MAX_FRAME_PAYLOAD)
                sendFrame(RawProtocol.FRAME_DEVICE_INFO, payload)
            }
        } catch (error: Exception) {
            runCatching { connection.close() }
            throw error
        }
    }

    private val writer = Thread(::writeLoop, "steamless-link-writer").apply {
        isDaemon = true
        start()
    }
    private val reader = Thread(::readLoop, "steamless-link-reader").apply {
        isDaemon = true
        start()
    }
    private var controlRequestCount = 0L
    private var droppedInputReports = 0L
    private var lastInputDropStatusAtMs = 0L

    init {
        if (initialDevices.isNotEmpty()) {
            try {
                if (!bundleReady.await(5, TimeUnit.SECONDS) || !bundleAccepted) {
                    throw IOException("Host did not accept the device bundle; upgrade the host")
                }
            } catch (error: Exception) {
                close()
                throw error
            }
        }
    }

    fun sendInputReport(report: ByteArray, length: Int = report.size): Boolean {
        if (closed.get()) return false
        val safeLength = length.coerceIn(0, report.size).coerceAtMost(RawProtocol.MAX_FRAME_PAYLOAD)
        return sendInputReports(listOf(0 to report.copyOf(safeLength)))
    }

    fun sendInputReports(reports: List<Pair<Int, ByteArray>>): Boolean {
        require(reports.isNotEmpty())
        val payload = reports.map { (device, report) ->
            require(device in 0 until initialDevices.size.coerceAtLeast(1))
            require(report.size <= RawProtocol.MAX_FRAME_PAYLOAD - if (initialDevices.isEmpty()) 0 else RawProtocol.DEVICE_FRAME_HEADER_SIZE)
            device to report.copyOf()
        }
        synchronized(inputQueueLock) {
            if (closed.get()) return false
            while (queuedInputReports.size >= MAX_INPUT_REPORT_QUEUE) {
                queuedInputReports.removeFirst()
                recordDroppedInputReports(1)
            }
            queuedInputReports.addLast(payload)
            inputQueueLock.notifyAll()
        }
        return true
    }

    private fun writeLoop() {
        while (true) {
            val payload = synchronized(inputQueueLock) {
                while (queuedInputReports.isEmpty() && !closed.get()) {
                    try {
                        inputQueueLock.wait()
                    } catch (_: InterruptedException) {
                        Thread.currentThread().interrupt()
                        return
                    }
                }
                if (closed.get()) return
                queuedInputReports.removeFirst()
            }

            runCatching {
                for ((device, report) in payload) sendDeviceFrame(device, RawProtocol.FRAME_INPUT, report)
            }
                .onFailure { error ->
                    if (!closed.get()) onStatus("Steamless Link writer stopped: ${error.message ?: error::class.java.simpleName}")
                    close()
                    return
                }
        }
    }

    private fun recordDroppedInputReports(count: Int) {
        droppedInputReports += count.toLong()
        val now = System.currentTimeMillis()
        if (now - lastInputDropStatusAtMs >= INPUT_DROP_STATUS_INTERVAL_MS) {
            lastInputDropStatusAtMs = now
            onStatus("Dropped queued Steamless Link input reports: count=$droppedInputReports")
        }
    }

    private fun readLoop() {
        runCatching {
            while (!closed.get()) {
                var type = input.readUnsignedByte()
                val length = input.readUnsignedShort()
                var payload = ByteArray(length)
                input.readFully(payload)
                if (type == RawProtocol.FRAME_DEVICE_BUNDLE_READY) {
                    check(initialDevices.isNotEmpty() && !bundleAccepted)
                    check(payload.contentEquals(byteArrayOf(initialDevices.size.toByte())))
                    bundleAccepted = true
                    bundleReady.countDown()
                    continue
                }
                var device = 0
                if (initialDevices.isNotEmpty()) {
                    check(bundleAccepted && type == RawProtocol.FRAME_DEVICE_FRAME && payload.size >= RawProtocol.DEVICE_FRAME_HEADER_SIZE)
                    device = payload.u8(0)
                    check(device in initialDevices.indices)
                    type = payload.u8(RawProtocol.DEVICE_FRAME_TYPE_OFFSET)
                    payload = payload.copyOfRange(RawProtocol.DEVICE_FRAME_HEADER_SIZE, payload.size)
                }
                when (type) {
                    RawProtocol.FRAME_OUTPUT -> handleOutputReport(device, payload)
                    RawProtocol.FRAME_GET_REPORT -> handleGetReport(device, payload)
                    RawProtocol.FRAME_SET_REPORT -> handleSetReport(device, payload)
                    else -> onStatus("Steamless Link frame type=0x%02x len=$length".format(type))
                }
            }
        }.onFailure { error ->
            if (!closed.get()) onStatus("Steamless Link reader stopped: ${error.message ?: error::class.java.simpleName}")
        }
        close()
    }

    private fun handleOutputReport(device: Int, payload: ByteArray) {
        if (payload.isEmpty()) return
        val reportType = payload.u8(0)
        val data = payload.copyOfRange(1, payload.size)
        logControl("Steamless Link output report rtype=$reportType len=${data.size} head=${data.hex(8)}")
        val ok = runCatching { onOutputReport(device, reportType, data) }.getOrDefault(false)
        if (!ok) logControl("Steamless Link output report write failed rtype=$reportType len=${data.size}")
    }

    private fun handleGetReport(device: Int, payload: ByteArray) {
        if (payload.size < 6) return
        val requestId = payload.i32Le(0)
        val reportNumber = payload.u8(4)
        val reportType = payload.u8(5)
        logControl("Steamless Link get-report id=$requestId rnum=0x%02x rtype=$reportType".format(reportNumber))
        val report = runCatching { onGetReport(device, requestId, reportNumber, reportType) }.getOrNull()
        val err = if (report == null) 5 else 0
        val data = report ?: ByteArray(0)
        sendDeviceFrame(device, RawProtocol.FRAME_GET_REPORT_REPLY, ByteArray(6 + data.size).also { out ->
            out.putI32Le(0, requestId)
            out.putU16Le(4, err)
            data.copyInto(out, destinationOffset = 6)
        })
    }

    private fun handleSetReport(device: Int, payload: ByteArray) {
        if (payload.size < 6) return
        val requestId = payload.i32Le(0)
        val reportNumber = payload.u8(4)
        val reportType = payload.u8(5)
        val data = payload.copyOfRange(6, payload.size)
        logControl("Steamless Link set-report id=$requestId rnum=0x%02x rtype=$reportType len=${data.size} head=${data.hex(8)}".format(reportNumber))
        val ok = runCatching { onSetReport(device, requestId, reportNumber, reportType, data) }.getOrDefault(false)
        sendDeviceFrame(device, RawProtocol.FRAME_SET_REPORT_REPLY, ByteArray(6).also { out ->
            out.putI32Le(0, requestId)
            out.putU16Le(4, if (ok) 0 else 5)
        })
    }

    private fun sendDeviceFrame(device: Int, type: Int, payload: ByteArray) {
        if (initialDevices.isEmpty()) return sendFrame(type, payload)
        sendFrame(RawProtocol.FRAME_DEVICE_FRAME, byteArrayOf(device.toByte(), type.toByte()) + payload)
    }

    private fun sendFrame(type: Int, payload: ByteArray) {
        require(payload.size <= RawProtocol.MAX_FRAME_PAYLOAD)
        synchronized(output) {
            val length = writeFrameHeader(output, type, payload.size)
            output.write(payload, 0, length)
            output.flush()
        }
    }

    private fun logControl(message: String) {
        controlRequestCount += 1
        if (controlRequestCount <= 8 || controlRequestCount % 100L == 0L) onStatus(message)
    }

    fun awaitClosed(timeoutMs: Long): Boolean = closedLatch.await(timeoutMs, TimeUnit.MILLISECONDS)

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        closedLatch.countDown()
        bundleReady.countDown()
        synchronized(inputQueueLock) {
            queuedInputReports.clear()
            inputQueueLock.notifyAll()
        }
        runCatching { connection.close() }
        writer.interrupt()
    }

    companion object {
        private const val MAX_INPUT_REPORT_QUEUE = 8
        private const val INPUT_DROP_STATUS_INTERVAL_MS = 1000L
    }
}

class RawUhidConnection(
    val input: InputStream,
    val output: OutputStream,
    private val closeAction: () -> Unit,
) : Closeable {
    override fun close() = closeAction()

    companion object {
        fun tcp(host: String, port: Int, connectTimeoutMs: Int = 10_000): RawUhidConnection {
            val socket = Socket().apply {
                tcpNoDelay = true
                connect(InetSocketAddress(host, port), connectTimeoutMs)
                soTimeout = 0
            }
            return RawUhidConnection(socket.getInputStream(), socket.getOutputStream()) { socket.close() }
        }
    }
}
