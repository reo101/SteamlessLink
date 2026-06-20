package xyz.reo101.steamlesslink.bridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.IBinder
import android.util.Log
import xyz.reo101.steamlesslink.R
import xyz.reo101.steamlesslink.ble.BleTritonTransport
import xyz.reo101.steamlesslink.local.LocalUinputXbox360Output
import xyz.reo101.steamlesslink.protocol.NativeProtocol
import xyz.reo101.steamlesslink.raw.UhidRawClient
import xyz.reo101.steamlesslink.raw.irohRawUhidConnection
import xyz.reo101.steamlesslink.triton.FakeTritonTransport
import xyz.reo101.steamlesslink.triton.TritonRawState
import xyz.reo101.steamlesslink.triton.TritonReportParser
import xyz.reo101.steamlesslink.usb.UsbTritonTransport
import xyz.reo101.steamlesslink.viiper.ViiperDeviceStream
import xyz.reo101.steamlesslink.viiper.Xbox360State
import xyz.reo101.steamlesslink.viiper.viiperClient
import java.io.Closeable
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

class ControllerBridgeService : Service() {
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { Thread(it, "controller-bridge") }
    private val streamRef = AtomicReference<ViiperDeviceStream?>(null)
    private val rawClientRef = AtomicReference<UhidRawClient?>(null)
    private val localUinputRef = AtomicReference<LocalUinputXbox360Output?>(null)
    private val bridgeGeneration = AtomicLong(0)
    private var tritonTransport: Closeable? = null
    private val closeables: MutableList<Closeable> = mutableListOf()
    private var lastReportStatusAtMs = 0L
    private var reportCount = 0L
    private var lastDroppedStatusAtMs = 0L
    private var processBoundToNetwork = false

    override fun onCreate() {
        super.onCreate()
        ensureNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val host = intent?.getStringExtra(EXTRA_HOST) ?: DEFAULT_HOST
        val port = intent?.getIntExtra(EXTRA_PORT, DEFAULT_PORT) ?: DEFAULT_PORT
        val transport = intent?.getStringExtra(EXTRA_TRANSPORT) ?: TRANSPORT_BLE
        val key = intent?.getStringExtra(EXTRA_KEY)
        val mode = intent?.getStringExtra(EXTRA_MODE) ?: MODE_UHID_RAW
        val irohTicket = intent?.getStringExtra(EXTRA_IROH_TICKET).orEmpty()
        val target = if (mode == MODE_UHID_RAW_IROH) "Iroh ticket" else "$host:$port"
        startForeground(NOTIFICATION_ID, notification("Starting $transport/$mode bridge to $target"))
        if (mode == MODE_UHID_RAW_IROH && irohTicket.isBlank()) {
            status("Iroh endpoint ticket is required")
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf(startId)
            return START_NOT_STICKY
        }
        if (host.isBlank() && mode != MODE_LOCAL_UINPUT_XBOX360 && mode != MODE_UHID_RAW_IROH) {
            status("Bridge host/IP is required")
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf(startId)
            return START_NOT_STICKY
        }
        startBridge(host, port, key, transport, mode, irohTicket)
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startBridge(host: String, port: Int, key: String?, transport: String, mode: String, irohTicket: String = "") {
        stopBridge()
        val generation = bridgeGeneration.incrementAndGet()
        status("Starting ${transport.lowercase()} capture")
        runCatching { startTritonCapture(transport, mode) }
            .onFailure { error ->
                status("Capture startup failed: ${error.message ?: error::class.java.simpleName}")
                Log.e(TAG, "Capture startup failed", error)
                return
            }

        worker.execute {
            runCatching {
                if (mode != MODE_LOCAL_UINPUT_XBOX360) bindProcessToWifiIfAvailable()
                if (!isCurrentBridge(generation)) return@runCatching
                if (!awaitCaptureReady(generation)) return@runCatching
                if (mode == MODE_UHID_RAW || mode == MODE_UHID_RAW_IROH) {
                    val connection = if (mode == MODE_UHID_RAW_IROH) {
                        status("Connecting to Steamless UHID raw bridge over Iroh")
                        irohRawUhidConnection(this@ControllerBridgeService, irohTicket)
                    } else {
                        status("Connecting to Steamless UHID raw bridge at $host:$port")
                        null
                    }
                    val raw = if (connection != null) {
                        UhidRawClient(
                            connection = connection,
                            onStatus = ::status,
                            onGetReport = ::handleRawGetReport,
                            onSetReport = ::handleRawSetReport,
                            onOutputReport = ::handleRawOutputReport,
                        )
                    } else {
                        UhidRawClient(
                            host = host,
                            port = port,
                            onStatus = ::status,
                            onGetReport = ::handleRawGetReport,
                            onSetReport = ::handleRawSetReport,
                            onOutputReport = ::handleRawOutputReport,
                        )
                    }
                    if (!isCurrentBridge(generation)) {
                        raw.close()
                        return@runCatching
                    }
                    rawClientRef.set(raw)
                    synchronized(closeables) { closeables.add(raw) }
                    status("UHID raw stream open; forwarding Triton reports")
                    return@runCatching
                }

                if (mode == MODE_LOCAL_UINPUT_XBOX360) {
                    status("Starting local uinput Xbox 360 output")
                    val local = LocalUinputXbox360Output.start(this@ControllerBridgeService, ::status)
                    if (!isCurrentBridge(generation)) {
                        local.close()
                        return@runCatching
                    }
                    localUinputRef.set(local)
                    synchronized(closeables) { closeables.add(local) }
                    status("Local uinput stream open; forwarding mapped Xbox 360 reports")
                    return@runCatching
                }

                val authText = if (key.isNullOrBlank()) "plaintext" else "authenticated"
                status("Connecting to VIIPER at $host:$port ($authText)")
                val viiper = runCatching {
                    viiperClient(host, port, key).also { it.ping() }
                }.getOrElse { error ->
                    if (!key.isNullOrBlank()) {
                        status("Authenticated VIIPER connect failed; retrying plaintext (${error.message ?: error::class.java.simpleName})")
                        viiperClient(host, port, null).also { it.ping() }
                    } else {
                        throw error
                    }
                }
                if (!isCurrentBridge(generation)) return@runCatching
                val ping = viiper.ping()
                status("VIIPER: ${ping.optString("server", "?")} ${ping.optString("version", "")}")
                val ref = viiper.createXbox360Device()
                status("Created VIIPER xbox360 device bus=${ref.busId} dev=${ref.devId}")
                val stream = viiper.openDeviceStream(ref)
                if (!isCurrentBridge(generation)) {
                    stream.close()
                    return@runCatching
                }
                streamRef.set(stream)
                synchronized(closeables) { closeables.add(stream) }
                status("VIIPER stream open; forwarding reports")
            }.onFailure { error ->
                val target = when (mode) {
                    MODE_UHID_RAW, MODE_UHID_RAW_IROH -> "UHID raw"
                    MODE_LOCAL_UINPUT_XBOX360 -> "local uinput"
                    else -> "VIIPER"
                }
                status("Capture is running, but $target connect failed: ${error.message ?: error::class.java.simpleName}")
                Log.e(TAG, "$target startup failed", error)
            }
        }
    }

    private fun startTritonCapture(transport: String, mode: String) {
        val closeable = when (transport) {
            TRANSPORT_USB -> UsbTritonTransport(
                context = this,
                onReport = ::handleTritonReport,
                onStatus = ::status,
            ).also { it.start() }
            TRANSPORT_BLE -> BleTritonTransport(
                context = this,
                onReport = ::handleTritonReport,
                onStatus = ::status,
                enableLizardModeRefresh = mode != MODE_UHID_RAW && mode != MODE_UHID_RAW_IROH,
            ).also { it.start() }
            TRANSPORT_FAKE -> {
                check(isDebuggable()) { "Fake Triton transport is only available in debuggable builds" }
                FakeTritonTransport(
                    onReport = ::handleTritonReport,
                    onStatus = ::status,
                ).also { it.start() }
            }
            else -> error("Unknown transport: $transport")
        }
        tritonTransport = closeable
        synchronized(closeables) { closeables.add(closeable) }
    }

    private fun handleRawGetReport(requestId: Int, reportNumber: Int, reportType: Int): ByteArray? {
        val transport = tritonTransport
        val report = when (transport) {
            is BleTritonTransport -> transport.readHidFeatureReport(reportNumber)
            is FakeTritonTransport -> transport.readHidFeatureReport(reportNumber)
            else -> {
                status("UHID get-report id=$requestId unsupported for transport ${transport?.javaClass?.simpleName ?: "none"}")
                return null
            }
        }
        if (report == null) status("HID feature read failed for UHID get-report id=$requestId rnum=0x%02x".format(reportNumber))
        return report
    }

    private fun handleRawOutputReport(reportType: Int, data: ByteArray): Boolean {
        val transport = tritonTransport
        val ok = when (transport) {
            is BleTritonTransport -> transport.enqueueHidOutputReport(data)
            is FakeTritonTransport -> transport.enqueueHidOutputReport(data)
            else -> {
                status("UHID output-report unsupported for transport ${transport?.javaClass?.simpleName ?: "none"}")
                return false
            }
        }
        if (!ok) status("HID output enqueue failed for UHID output-report rtype=$reportType len=${data.size}")
        return ok
    }

    private fun handleRawSetReport(requestId: Int, reportNumber: Int, reportType: Int, data: ByteArray): Boolean {
        val transport = tritonTransport
        val ok = when (transport) {
            is BleTritonTransport -> transport.writeHidFeatureReport(data)
            is FakeTritonTransport -> transport.writeHidFeatureReport(data)
            else -> {
                status("UHID set-report id=$requestId unsupported for transport ${transport?.javaClass?.simpleName ?: "none"}")
                return false
            }
        }
        if (!ok) {
            status(
                "HID feature write failed for UHID set-report id=$requestId rnum=0x%02x len=${data.size}; acking Steam anyway".format(
                    reportNumber,
                ),
            )
        }
        return true
    }

    private fun handleTritonReport(report: ByteArray, length: Int) {
        val triton = TritonReportParser.parse(report, length) ?: return
        reportCount += 1
        val now = System.currentTimeMillis()
        if (now - lastReportStatusAtMs >= REPORT_STATUS_INTERVAL_MS) {
            lastReportStatusAtMs = now
            status("Triton reports: count=$reportCount id=0x%02x seq=${triton.sequence} buttons=0x%08x len=$length".format(triton.reportId, triton.buttons.toLong()))
        }

        val rawClient = rawClientRef.get()
        if (rawClient != null) {
            runCatching {
                if (!rawClient.sendInputReport(triton.rawReport, triton.rawReport.size)) {
                    rawClientRef.compareAndSet(rawClient, null)
                    status("UHID raw stream is closed")
                }
            }.onFailure { error ->
                rawClientRef.compareAndSet(rawClient, null)
                status("UHID raw stream write failed: ${error.message ?: error::class.java.simpleName}")
                Log.e(TAG, "UHID raw stream write failed", error)
            }
            return
        }

        val localUinput = localUinputRef.get()
        if (localUinput != null) {
            runCatching { sendLocalUinputReport(localUinput, report, length, triton) }
                .onFailure { error ->
                    localUinputRef.compareAndSet(localUinput, null)
                    status("Local uinput stream write failed: ${error.message ?: error::class.java.simpleName}")
                    Log.e(TAG, "Local uinput stream write failed", error)
                }
            return
        }

        val stream = streamRef.get()
        if (stream == null) {
            if (now - lastDroppedStatusAtMs >= DROPPED_STATUS_INTERVAL_MS) {
                lastDroppedStatusAtMs = now
                status("Receiving Triton reports, but no output stream is open")
            }
            return
        }
        runCatching { sendViiperReport(stream, report, length, triton) }
            .onFailure { error ->
                streamRef.compareAndSet(stream, null)
                status("VIIPER stream write failed: ${error.message ?: error::class.java.simpleName}")
                Log.e(TAG, "VIIPER stream write failed", error)
            }
    }

    private fun sendViiperReport(
        stream: ViiperDeviceStream,
        report: ByteArray,
        length: Int,
        triton: TritonRawState,
    ) {
        val nativePacket = ByteArray(Xbox360State.PACKET_SIZE)
        if (NativeProtocol.tryMapTritonToViiper(report, length, nativePacket)) {
            stream.sendPacket(nativePacket)
            return
        }

        stream.send(TritonToXbox360Mapper.map(triton))
    }

    private fun sendLocalUinputReport(
        output: LocalUinputXbox360Output,
        report: ByteArray,
        length: Int,
        triton: TritonRawState,
    ) {
        val nativePacket = ByteArray(Xbox360State.PACKET_SIZE)
        if (NativeProtocol.tryMapTritonToViiper(report, length, nativePacket)) {
            output.sendPacket(nativePacket)
            return
        }

        output.send(TritonToXbox360Mapper.map(triton))
    }

    private fun awaitCaptureReady(generation: Long): Boolean {
        val ble = tritonTransport as? BleTritonTransport ?: return true
        status("Waiting for BLE notifications before opening output stream")
        val ready = ble.awaitReady(BLE_READY_TIMEOUT_MS)
        if (!isCurrentBridge(generation)) return false
        if (!ready) {
            status("BLE notifications were not ready; not opening output stream")
            return false
        }
        status("BLE capture ready")
        return true
    }

    private fun bindProcessToWifiIfAvailable() {
        val cm = getSystemService(ConnectivityManager::class.java)
        val networks = cm.allNetworks.mapNotNull { network ->
            cm.getNetworkCapabilities(network)?.let { capabilities -> network to capabilities }
        }
        val summary = networks.joinToString { (network, capabilities) ->
            val transports = buildList {
                if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) add("wifi")
                if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) add("cell")
                if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) add("vpn")
                if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH)) add("bt")
            }.joinToString("+")
            "$network:$transports"
        }
        status("Available networks: $summary")
        val wifi = networks.firstOrNull { (_, capabilities) ->
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
                capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        }?.first
        if (wifi != null) {
            val ok = cm.bindProcessToNetwork(wifi)
            if (ok) processBoundToNetwork = true
            status("Bound process networking to Wi-Fi $wifi: $ok")
        } else {
            status("No Wi-Fi internet network found; using default network")
        }
    }

    private fun clearProcessNetworkBinding() {
        if (!processBoundToNetwork) return
        val cm = getSystemService(ConnectivityManager::class.java)
        val ok = cm.bindProcessToNetwork(null)
        processBoundToNetwork = false
        status("Cleared process network binding: $ok")
    }

    private fun isCurrentBridge(generation: Long): Boolean = bridgeGeneration.get() == generation

    private fun isDebuggable(): Boolean = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

    private fun stopBridge() {
        bridgeGeneration.incrementAndGet()
        streamRef.getAndSet(null)
        rawClientRef.getAndSet(null)
        localUinputRef.getAndSet(null)
        clearProcessNetworkBinding()
        synchronized(closeables) {
            closeables.asReversed().forEach { closeable -> runCatching { closeable.close() } }
            closeables.clear()
        }
        tritonTransport = null
        reportCount = 0
        lastReportStatusAtMs = 0
        lastDroppedStatusAtMs = 0
    }

    private fun status(message: String) {
        Log.i(TAG, message)
        if (!shouldShowInNotification(message)) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, notification(message))
    }

    private fun shouldShowInNotification(message: String): Boolean {
        // Keep detailed diagnostics in logcat without turning the foreground
        // notification into a constantly changing debug console.
        return !DIAGNOSTIC_NOTIFICATION_PREFIXES.any { prefix -> message.startsWith(prefix) }
    }

    private fun notification(text: String): Notification {
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.drawable.ic_launcher)
            .setContentTitle("SteamlessLink")
            .setContentText(text)
            .setOngoing(true)
            .build()
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Controller bridge",
            NotificationManager.IMPORTANCE_MIN,
        ).apply {
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    override fun onDestroy() {
        stopBridge()
        worker.shutdownNow()
        super.onDestroy()
    }

    companion object {
        const val EXTRA_HOST = "xyz.reo101.steamlesslink.extra.HOST"
        const val EXTRA_PORT = "xyz.reo101.steamlesslink.extra.PORT"
        const val EXTRA_TRANSPORT = "xyz.reo101.steamlesslink.extra.TRANSPORT"
        const val EXTRA_KEY = "xyz.reo101.steamlesslink.extra.KEY"
        const val EXTRA_MODE = "xyz.reo101.steamlesslink.extra.MODE"
        const val EXTRA_IROH_TICKET = "xyz.reo101.steamlesslink.extra.IROH_TICKET"
        const val TRANSPORT_BLE = "ble"
        const val TRANSPORT_USB = "usb"
        const val TRANSPORT_FAKE = "fake"
        const val MODE_UHID_RAW = "uhid-raw"
        const val MODE_UHID_RAW_IROH = "uhid-raw-iroh"
        const val MODE_VIIPER_XBOX360 = "viiper-xbox360"
        const val MODE_LOCAL_UINPUT_XBOX360 = "local-uinput-xbox360"
        private const val DEFAULT_HOST = ""
        private const val DEFAULT_PORT = 3244
        private const val CHANNEL_ID = "controller_bridge_quiet"
        private const val NOTIFICATION_ID = 1001
        private const val REPORT_STATUS_INTERVAL_MS = 1000L
        private const val DROPPED_STATUS_INTERVAL_MS = 5000L
        private const val BLE_READY_TIMEOUT_MS = 12_000L
        private val DIAGNOSTIC_NOTIFICATION_PREFIXES = listOf(
            "Available networks:",
            "BLE MTU changed",
            "BLE notifications:",
            "Bound process networking",
            "Cleared process network binding",
            "Dropped queued BLE output reports",
            "Dropped queued UHID input reports",
            "Enabling BLE notifications for",
            "Ignoring BLE report",
            "Triton reports:",
            "UHID get-report",
            "UHID output report",
            "UHID set-report",
            "Valve char",
        )
        private const val TAG = "ControllerBridge"
    }
}
