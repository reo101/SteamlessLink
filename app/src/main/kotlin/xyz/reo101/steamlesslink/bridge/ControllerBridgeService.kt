package xyz.reo101.steamlesslink.bridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import java.io.Closeable
import java.io.IOException
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference
import xyz.reo101.steamlesslink.R
import xyz.reo101.steamlesslink.ble.BleTritonTransport
import xyz.reo101.steamlesslink.local.LocalMappingSettings
import xyz.reo101.steamlesslink.local.LocalUinputXbox360Output
import xyz.reo101.steamlesslink.protocol.ExtendedGamepadSession
import xyz.reo101.steamlesslink.protocol.GenericGamepadProtocol
import xyz.reo101.steamlesslink.protocol.NativeProtocol
import xyz.reo101.steamlesslink.protocol.RawProtocol
import xyz.reo101.steamlesslink.protocol.encodeDeviceInfo
import xyz.reo101.steamlesslink.protocol.Xbox360Protocol
import xyz.reo101.steamlesslink.raw.RawUhidConnection
import xyz.reo101.steamlesslink.raw.UhidRawClient
import xyz.reo101.steamlesslink.raw.irohRawUhidConnection
import xyz.reo101.steamlesslink.testing.ControllerTestFeed
import xyz.reo101.steamlesslink.triton.FakeTritonTransport
import xyz.reo101.steamlesslink.triton.TritonReportParser
import xyz.reo101.steamlesslink.triton.TritonTransport
import xyz.reo101.steamlesslink.usb.UsbTritonTransport

class ControllerBridgeService : Service() {
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "controller-bridge") }
    private val main = Handler(Looper.getMainLooper())
    private val currentSession = AtomicReference<BridgeSession?>(null)
    private var latestStartId = 0
    private var destroyed = false
    private var terminalFailure = false

    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Controller bridge", NotificationManager.IMPORTANCE_MIN).apply { setShowBadge(false) },
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        latestStartId = startId
        terminalFailure = false
        val host = intent?.getStringExtra(EXTRA_HOST).orEmpty()
        val port = intent?.getIntExtra(EXTRA_PORT, DEFAULT_PORT) ?: DEFAULT_PORT
        val transport = intent?.getStringExtra(EXTRA_TRANSPORT) ?: TRANSPORT_BLE
        val mode = intent?.getStringExtra(EXTRA_MODE) ?: MODE_UHID_RAW
        val ticket = intent?.getStringExtra(EXTRA_IROH_TICKET).orEmpty()
        startForeground(NOTIFICATION_ID, notification("Starting $transport / $mode"))
        val invalid = when {
            mode == MODE_UHID_RAW_IROH && ticket.isBlank() -> "Iroh endpoint ticket is required"
            mode !in setOf(MODE_LOCAL_UINPUT_XBOX360, MODE_UHID_RAW_IROH, MODE_CAPTURE_TEST) && host.isBlank() -> "Bridge host/IP is required"
            mode in setOf(MODE_UHID_GENERIC_GAMEPAD, MODE_UHID_EXTENDED_GAMEPAD, MODE_LOCAL_UINPUT_XBOX360) && !NativeProtocol.isAvailable -> "Bundled Zig protocol library failed to load"
            else -> null
        }
        if (invalid != null) {
            status(invalid)
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf(startId)
            return START_NOT_STICKY
        }
        startBridge(startId, host, port, transport, mode, ticket,
            intent?.getIntExtra(EXTRA_FAKE_FAILURE_AFTER_REPORTS, 0) ?: 0,
            intent?.getIntExtra(EXTRA_FAKE_REPORT_ID, FakeTritonTransport.INPUT_REPORT_ID) ?: FakeTritonTransport.INPUT_REPORT_ID)
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startBridge(startId: Int, host: String, port: Int, transport: String, mode: String, ticket: String, failureAfterReports: Int, fakeReportId: Int) {
        stopBridge()
        val feedGeneration = ControllerTestFeed.begin("$transport / $mode")
        val session = BridgeSession(startId, mode, LocalMappingSettings.load(getSharedPreferences("steamlesslink", MODE_PRIVATE)), feedGeneration) { resource ->
            resourceCloser.execute { runCatching { resource.close() }.onFailure { Log.w(TAG, "Resource close failed", it) } }
        }
        currentSession.set(session)
        status(session, "Starting ${transport.lowercase()} capture")
        val task = worker.submit {
            try {
                val capture = createCapture(session, transport, failureAfterReports, fakeReportId)
                if (!session.attach(capture)) return@submit
                session.transport = capture
                capture.start()
                val timeout = if (transport == TRANSPORT_USB) USB_READY_TIMEOUT_MS else BLE_READY_TIMEOUT_MS
                if (!capture.awaitReady(timeout)) throw IOException("$transport capture did not become ready")
                if (!isCurrent(session)) return@submit
                when (mode) {
                    MODE_CAPTURE_TEST -> status(session, "Capture-only tester ready; no output device or remote connection")
                    MODE_LOCAL_UINPUT_XBOX360 -> {
                        val output = LocalUinputXbox360Output.start(this) { status(session, it) }
                        if (session.attach(output)) {
                            session.localOutput.set(output)
                            status(session, "Connected to local uinput; forwarding mapped Xbox 360 reports")
                        }
                    }
                    MODE_UHID_RAW, MODE_UHID_RAW_IROH, MODE_UHID_GENERIC_GAMEPAD, MODE_UHID_EXTENDED_GAMEPAD ->
                        runRawBridge(session, host, port, ticket)
                    else -> throw IOException("Unknown bridge mode: $mode")
                }
            } catch (error: Exception) {
                if (isCurrent(session)) {
                    Log.e(TAG, "Bridge session failed", error)
                    failSession(session, error.message ?: error::class.java.simpleName)
                }
            }
        }
        // Interrupt startup waits and runBlocking calls before a successor starts.
        session.attach(Closeable { task.cancel(true) })
    }

    private fun createCapture(session: BridgeSession, transport: String, failureAfterReports: Int, fakeReportId: Int): TritonTransport {
        val onReport: (ByteArray, Int) -> Unit = { report, length ->
            if (isCurrent(session)) handleTritonReport(session, report, length)
        }
        val onStatus: (String) -> Unit = { status(session, it) }
        val onFailure: (String) -> Unit = { failSession(session, it) }
        val enableImu = session.mode == MODE_UHID_EXTENDED_GAMEPAD || session.mode == MODE_CAPTURE_TEST ||
            (session.mode == MODE_LOCAL_UINPUT_XBOX360 && session.mapping.touchGyro)
        val refresh = session.mode != MODE_UHID_RAW && session.mode != MODE_UHID_RAW_IROH
        return when (transport) {
            TRANSPORT_USB -> UsbTritonTransport(this, onReport, onStatus, enableImu, refresh, onFailure)
            TRANSPORT_BLE -> BleTritonTransport(this, onReport, onStatus, refresh, enableImu, onFailure)
            TRANSPORT_FAKE -> {
                check((applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0) { "Fake transport requires a debuggable build" }
                require(fakeReportId in 0..0xff)
                FakeTritonTransport(onReport, onStatus, onFailure = onFailure, failureAfterReports = failureAfterReports,
                    reportFactory = { sequence -> FakeTritonTransport.makeReport(sequence).also { it[0] = fakeReportId.toByte() } })
            }
            else -> throw IOException("Unknown transport: $transport")
        }
    }

    private fun runRawBridge(session: BridgeSession, host: String, port: Int, ticket: String) {
        val capture = session.transport ?: return
        val wifi = if (session.mode == MODE_UHID_RAW_IROH) null else wifiNetwork()
        while (isCurrent(session)) {
            var raw: UhidRawClient? = null
            var connection: RawUhidConnection? = null
            var socket: Socket? = null
            val extended = if (session.mode == MODE_UHID_EXTENDED_GAMEPAD) ExtendedGamepadSession() else null
            try {
                status(session, "Connecting to Steamless Link host")
                connection = if (session.mode == MODE_UHID_RAW_IROH) {
                    irohRawUhidConnection(this, ticket, onStatus = { status(session, it) })
                } else {
                    RawUhidConnection.tcp(host, port, onSocket = { pending ->
                        socket = pending
                        if (!session.attach(pending)) throw IOException("Session stopped during connect")
                        wifi?.bindSocket(pending)
                    })
                }
                if (!session.attach(connection)) return
                raw = UhidRawClient(
                    connection = connection,
                    onStatus = { status(session, it) },
                    onGetReport = { device, _, number, type ->
                        if (!isCurrent(session)) null
                        else if (extended != null) extended.getReport(device, number, type)
                        else capture.readHidReport(number, type)
                    },
                    onSetReport = { device, _, number, type, data ->
                        isCurrent(session) && (extended?.setReport(device, number, type, data) ?: capture.writeHidReport(number, type, data))
                    },
                    onOutputReport = { _, type, data -> isCurrent(session) && extended == null && capture.sendOutputReport(type, data) },
                    initialDeviceInfo = when (session.mode) {
                        MODE_UHID_GENERIC_GAMEPAD -> genericGamepadDeviceInfo()
                        MODE_UHID_RAW, MODE_UHID_RAW_IROH -> capture.deviceInfo
                        else -> null
                    },
                    initialDevices = extended?.deviceInfos.orEmpty(),
                )
                if (!session.attach(raw)) return
                session.extended = extended
                session.rawClient.set(raw)
                status(session, "Connected to Steamless Link host; forwarding controller reports")
                while (isCurrent(session) && !raw.awaitClosed(RAW_CONNECTION_WAIT_MS)) Unit
            } catch (error: Exception) {
                if (isCurrent(session)) status(session, "Steamless Link connection failed: ${error.message ?: error::class.java.simpleName}")
            } finally {
                raw?.let { session.rawClient.compareAndSet(it, null); session.release(it) }
                connection?.let(session::release)
                socket?.let(session::release)
            }
            if (isCurrent(session)) {
                status(session, "Steamless Link stream disconnected; retrying")
                Thread.sleep(RAW_RECONNECT_DELAY_MS)
            }
        }
    }

    private fun handleTritonReport(session: BridgeSession, report: ByteArray, length: Int) {
        val raw = session.rawClient.get()
        val rawMode = session.mode == MODE_UHID_RAW || session.mode == MODE_UHID_RAW_IROH
        // Interpretation is optional in raw mode: preserve every numbered HID report.
        val state = TritonReportParser.parse(report, length)
        if (!rawMode && state == null) return
        session.reportCount += 1
        val now = System.currentTimeMillis()
        if (state != null && now - session.lastReportStatusAtMs >= 1000) {
            session.lastReportStatusAtMs = now
            status(session, "Triton reports: count=${session.reportCount} id=0x%02x seq=${state.sequence} buttons=0x%08x len=$length".format(state.reportId, state.buttons.toLong()))
        }
        if (raw == null && session.localOutput.get() == null && session.mode != MODE_CAPTURE_TEST && now - session.lastDroppedStatusAtMs >= 5000) {
            session.lastDroppedStatusAtMs = now
            status(session, "Receiving Triton reports, but no output stream is open")
        }
        try {
            var output = emptyList<Pair<Int, ByteArray>>()
            val disposition = when {
                raw != null -> {
                    val extended = session.extended
                    output = when {
                        rawMode -> listOf(0 to report.copyOf(length))
                        extended != null -> extended.map(report, length)
                        else -> listOf(0 to mapGeneric(report, length))
                    }
                    if (raw.sendInputReports(output)) "Accepted by remote send queue; host receipt NOT verified"
                    else {
                        session.rawClient.compareAndSet(raw, null)
                        session.release(raw)
                        "Remote send queue rejected sample"
                    }
                }
                session.localOutput.get() != null -> {
                    val packet = ByteArray(Xbox360Protocol.PACKET_SIZE)
                    check(NativeProtocol.tryMapTritonToLocalXbox360(report, length, packet, session.mapping)) { "Native mapper unavailable" }
                    session.localOutput.get()?.sendPacket(packet) ?: return
                    output = listOf(0 to packet)
                    "Written to local helper pipe; see Android receipt below"
                }
                session.mode == MODE_CAPTURE_TEST -> "Capture only; previews are NOT sent"
                else -> "No output stream open"
            }
            if (state != null) ControllerTestFeed.record(state, session.reportCount, output, disposition, sessionId = session.feedGeneration)
        } catch (error: Exception) {
            // A local output failure ends the session. Remote failures reconnect.
            if (raw != null) {
                session.rawClient.compareAndSet(raw, null)
                session.release(raw)
                status(session, "Remote write failed: ${error.message}")
            } else failSession(session, "Local output failed: ${error.message}")
        }
    }

    private fun mapGeneric(report: ByteArray, length: Int): ByteArray = ByteArray(GenericGamepadProtocol.INPUT_REPORT_SIZE).also {
        check(NativeProtocol.tryMapTritonToGenericGamepad(report, length, it)) { "Native mapper unavailable" }
    }

    private fun genericGamepadDeviceInfo(): ByteArray = RawProtocol.encodeDeviceInfo(
        GenericGamepadProtocol.BUS_USB, GenericGamepadProtocol.VENDOR_ID, GenericGamepadProtocol.PRODUCT_ID,
        GenericGamepadProtocol.REPORT_DESCRIPTOR, GenericGamepadProtocol.DEVICE_NAME,
    )

    private fun wifiNetwork(): Network? {
        val manager = getSystemService(ConnectivityManager::class.java)
        return manager.allNetworks.firstOrNull { network ->
            manager.getNetworkCapabilities(network)?.let {
                it.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) && it.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            } == true
        }
    }

    private fun isCurrent(session: BridgeSession): Boolean = session.isActive && currentSession.get() === session

    private fun failSession(session: BridgeSession, reason: String) {
        if (!currentSession.compareAndSet(session, null)) return
        session.close()
        main.post {
            if (!destroyed && latestStartId == session.startId && currentSession.get() == null) {
                terminalFailure = true
                ControllerTestFeed.stop()
                status("Bridge stopped: $reason. Tap Start to retry.")
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf(session.startId)
            }
        }
    }

    private fun stopBridge() {
        currentSession.getAndSet(null)?.close()
        ControllerTestFeed.stop()
    }

    private fun status(session: BridgeSession, message: String) {
        main.post { if (isCurrent(session)) status(message) }
    }

    private fun status(message: String) {
        Log.i(TAG, message)
        if (DIAGNOSTIC_NOTIFICATION_PREFIXES.any(message::startsWith)) return
        ControllerTestFeed.status(message)
        sendBroadcast(Intent(ACTION_STATUS).setPackage(packageName).putExtra(EXTRA_STATUS, message))
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(message))
    }

    private fun notification(text: String): Notification = Notification.Builder(this, CHANNEL_ID)
        .setSmallIcon(R.drawable.ic_launcher).setContentTitle("SteamlessLink").setContentText(text).setOngoing(true).build()

    override fun onDestroy() {
        destroyed = true
        currentSession.getAndSet(null)?.close()
        if (!terminalFailure) ControllerTestFeed.stop()
        worker.shutdownNow()
        super.onDestroy()
    }

    companion object {
        const val EXTRA_HOST = "xyz.reo101.steamlesslink.extra.HOST"
        const val EXTRA_PORT = "xyz.reo101.steamlesslink.extra.PORT"
        const val EXTRA_TRANSPORT = "xyz.reo101.steamlesslink.extra.TRANSPORT"
        const val EXTRA_MODE = "xyz.reo101.steamlesslink.extra.MODE"
        const val EXTRA_IROH_TICKET = "xyz.reo101.steamlesslink.extra.IROH_TICKET"
        const val EXTRA_FAKE_FAILURE_AFTER_REPORTS = "xyz.reo101.steamlesslink.extra.FAKE_FAILURE_AFTER_REPORTS"
        const val EXTRA_FAKE_REPORT_ID = "xyz.reo101.steamlesslink.extra.FAKE_REPORT_ID"
        const val ACTION_STATUS = "xyz.reo101.steamlesslink.action.STATUS"
        const val EXTRA_STATUS = "xyz.reo101.steamlesslink.extra.STATUS"
        const val TRANSPORT_BLE = "ble"
        const val TRANSPORT_USB = "usb"
        const val TRANSPORT_FAKE = "fake"
        const val MODE_UHID_RAW = "uhid-raw"
        const val MODE_UHID_RAW_IROH = "uhid-raw-iroh"
        const val MODE_UHID_GENERIC_GAMEPAD = "uhid-generic-gamepad"
        const val MODE_UHID_EXTENDED_GAMEPAD = "uhid-extended-gamepad"
        const val MODE_LOCAL_UINPUT_XBOX360 = "local-uinput-xbox360"
        const val MODE_CAPTURE_TEST = "capture-test"
        private const val DEFAULT_PORT = 3244
        private const val CHANNEL_ID = "controller_bridge_quiet"
        private const val NOTIFICATION_ID = 1001
        private const val BLE_READY_TIMEOUT_MS = 12_000L
        private const val USB_READY_TIMEOUT_MS = 30_000L
        private const val RAW_CONNECTION_WAIT_MS = 500L
        private const val RAW_RECONNECT_DELAY_MS = 2_000L
        // Process-owned: late startup results still need disposal after onDestroy.
        private val resourceCloser = Executors.newCachedThreadPool { Thread(it, "bridge-resource-close").apply { isDaemon = true } }
        private val DIAGNOSTIC_NOTIFICATION_PREFIXES = listOf(
            "Triton reports:", "BLE MTU changed", "BLE notifications:", "Dropped queued", "Enabling BLE notifications for", "Ignoring BLE report",
            "UHID get-report", "UHID output report", "UHID set-report", "Steamless Link frame", "Steamless Link get-report",
            "Steamless Link output report", "Steamless Link set-report", "Valve char",
        )
        private const val TAG = "ControllerBridge"
    }
}
