package xyz.reo101.steamlesslink.usb

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import java.io.Closeable
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import xyz.reo101.steamlesslink.protocol.ExtendedGamepadProtocol
import xyz.reo101.steamlesslink.protocol.RawProtocol
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class UsbTritonTransport(
    private val context: Context,
    private val onReport: (ByteArray, Int) -> Unit,
    private val onStatus: (String) -> Unit,
    private val enableImu: Boolean = false,
    private val enableLizardModeRefresh: Boolean = true,
) : Closeable {
    private val usbManager = context.getSystemService(Context.USB_SERVICE) as UsbManager
    private val running = AtomicBoolean(false)
    private val readyLatch = CountDownLatch(1)
    private val reportIoLock = Object()
    @Volatile private var ready = false
    @Volatile internal var deviceInfo: ByteArray? = null
        private set
    private val executor = Executors.newSingleThreadExecutor { Thread(it, "usb-triton-reader") }
    private var lizardExecutor: ScheduledExecutorService? = null
    private var connection: UsbDeviceConnection? = null
    private var claimedInterface: UsbInterface? = null
    private var inputEndpoint: UsbEndpoint? = null
    private var outputEndpoint: UsbEndpoint? = null
    private var permissionReceiver: BroadcastReceiver? = null

    fun start() {
        val device = findCandidateDevice()
        if (device == null) {
            onStatus("No supported Steam Controller USB device found")
            readyLatch.countDown()
            return
        }

        if (!usbManager.hasPermission(device)) {
            requestPermission(device)
            return
        }

        open(device)
    }

    private fun findCandidateDevice(): UsbDevice? =
        usbManager.deviceList.values
            .filter(::isSteamController)
            .minWithOrNull(compareBy({ it.productId }, { it.deviceName }))

    private fun requestPermission(device: UsbDevice) {
        onStatus("Requesting USB permission for ${device.deviceName}")
        val action = "${context.packageName}.USB_PERMISSION"
        unregisterPermissionReceiver()
        permissionReceiver = object : BroadcastReceiver() {
            override fun onReceive(receiverContext: Context, intent: Intent) {
                if (intent.action != action) return
                val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                val permittedDevice = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                }
                unregisterPermissionReceiver()
                if (granted && permittedDevice != null && isSteamController(permittedDevice)) {
                    onStatus("USB permission granted")
                    open(permittedDevice)
                } else {
                    onStatus("USB permission denied or unsupported device")
                    readyLatch.countDown()
                }
            }
        }
        val filter = IntentFilter(action)
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(permissionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            context.registerReceiver(permissionReceiver, filter)
        }
        val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
        val intent = PendingIntent.getBroadcast(context, 0, Intent(action).setPackage(context.packageName), flags)
        usbManager.requestPermission(device, intent)
    }

    private fun open(device: UsbDevice) {
        closeConnectionOnly()
        val openedConnection = usbManager.openDevice(device)
        if (openedConnection == null) {
            onStatus("Failed to open ${device.deviceName}")
            readyLatch.countDown()
            return
        }

        val ifaceAndEndpoint = findHidInput(device)
        if (ifaceAndEndpoint == null) {
            openedConnection.close()
            onStatus("No HID input endpoint on ${device.deviceName}")
            readyLatch.countDown()
            return
        }

        val (usbInterface, endpoint) = ifaceAndEndpoint
        if (!openedConnection.claimInterface(usbInterface, true)) {
            openedConnection.close()
            onStatus("Failed to claim HID interface ${usbInterface.id}")
            readyLatch.countDown()
            return
        }

        val descriptor = ByteArray(RawProtocol.MAX_REPORT_DESCRIPTOR_SIZE)
        val descriptorLength = openedConnection.controlTransfer(
            0x81, 0x06, 0x2200, usbInterface.id, // GET_DESCRIPTOR (HID report), interface recipient
            descriptor, descriptor.size, 1000,
        )
        if (descriptorLength <= 0) {
            openedConnection.releaseInterface(usbInterface)
            openedConnection.close()
            onStatus("Failed to read USB HID report descriptor ($descriptorLength)")
            readyLatch.countDown()
            return
        }
        deviceInfo = RawProtocol.encodeDeviceInfo(
            bus = 3, // BUS_USB
            vendor = device.vendorId,
            product = device.productId,
            descriptor = descriptor.copyOf(descriptorLength),
            name = "Steam Controller",
        )

        connection = openedConnection
        claimedInterface = usbInterface
        inputEndpoint = endpoint
        outputEndpoint = (0 until usbInterface.endpointCount).map(usbInterface::getEndpoint).firstOrNull {
            it.direction == UsbConstants.USB_DIR_OUT &&
                (it.type == UsbConstants.USB_ENDPOINT_XFER_INT || it.type == UsbConstants.USB_ENDPOINT_XFER_BULK)
        }
        running.set(true)
        onStatus("Opened ${device.deviceName} interface=${usbInterface.id} endpoint=${endpoint.endpointNumber}")
        if (enableLizardModeRefresh) startLizardModeRefresh(openedConnection, usbInterface)
        startReadLoop(openedConnection, endpoint)
    }

    private fun findHidInput(device: UsbDevice): Pair<UsbInterface, UsbEndpoint>? {
        for (i in 0 until device.interfaceCount) {
            val usbInterface = device.getInterface(i)
            val isHid = usbInterface.interfaceClass == UsbConstants.USB_CLASS_HID
            if (!isHid) continue
            for (e in 0 until usbInterface.endpointCount) {
                val endpoint = usbInterface.getEndpoint(e)
                if (endpoint.direction == UsbConstants.USB_DIR_IN &&
                    (endpoint.type == UsbConstants.USB_ENDPOINT_XFER_INT || endpoint.type == UsbConstants.USB_ENDPOINT_XFER_BULK)
                ) {
                    return usbInterface to endpoint
                }
            }
        }
        return null
    }

    private fun startReadLoop(openedConnection: UsbDeviceConnection, endpoint: UsbEndpoint) {
        executor.execute {
            val buffer = ByteArray(endpoint.maxPacketSize.coerceAtLeast(64))
            while (running.get()) {
                val read = openedConnection.bulkTransfer(endpoint, buffer, buffer.size, 1000)
                if (read > 0) {
                    ready = true
                    readyLatch.countDown()
                    onReport(buffer.copyOf(read), read)
                } else if (read < 0) {
                    if (running.get()) onStatus("USB read failed ($read); stopping")
                    running.set(false)
                    ready = false
                    readyLatch.countDown()
                }
            }
        }
    }

    private fun startLizardModeRefresh(openedConnection: UsbDeviceConnection, usbInterface: UsbInterface) {
        lizardExecutor?.shutdownNow()
        lizardExecutor = Executors.newSingleThreadScheduledExecutor { Thread(it, "triton-lizard-refresh") }
        lizardExecutor?.scheduleAtFixedRate({
            val sent = disableLizardMode(openedConnection, usbInterface.id)
            if (!sent) onStatus("Failed to refresh lizard-mode setting")
        }, 0, 3, TimeUnit.SECONDS)
    }

    private fun disableLizardMode(openedConnection: UsbDeviceConnection, interfaceId: Int): Boolean = synchronized(reportIoLock) {
        val report = if (enableImu) ExtendedGamepadProtocol.EXTENDED_USB_SETTINGS else ByteArray(64).also {
            it[0] = 0x01 // feature report id
            it[1] = 0x87.toByte() // ID_SET_SETTINGS_VALUES
            it[2] = 3
            it[3] = 0x09 // SETTING_LIZARD_MODE; remaining bytes are LIZARD_MODE_OFF
        }
        val sent = openedConnection.controlTransfer(
            0x21, // host-to-device | class | interface
            0x09, // SET_REPORT
            (3 shl 8) or 1, // feature report type + report id
            interfaceId,
            report,
            0,
            report.size,
            1000,
        )
        sent == report.size
    }

    fun awaitReady(timeoutMs: Long): Boolean {
        readyLatch.await(timeoutMs, TimeUnit.MILLISECONDS)
        return ready && running.get()
    }

    fun readHidReport(reportNumber: Int, reportType: Int): ByteArray? = synchronized(reportIoLock) {
        val value = hidReportValue(reportNumber, reportType) ?: return@synchronized null
        val conn = connection ?: return@synchronized null
        val iface = claimedInterface ?: return@synchronized null
        // Include the report ID. Return the actual USB length, not the buffer capacity.
        val report = ByteArray(65)
        val read = conn.controlTransfer(0xa1, 0x01, value, iface.id, report, report.size, 1000)
        if (read > 0) report.copyOf(read) else null
    }

    fun writeHidReport(reportNumber: Int, reportType: Int, report: ByteArray): Boolean = synchronized(reportIoLock) {
        val value = hidReportValue(reportNumber, reportType) ?: return@synchronized false
        if (reportType == 2 || report.isEmpty() || report.size > 65 ||
            (report[0].toInt() and 0xff) != reportNumber
        ) return@synchronized false
        val conn = connection ?: return@synchronized false
        val iface = claimedInterface ?: return@synchronized false
        // Unlike BLE, USB carries the report ID and padding in the transfer itself.
        // Triton accepts output on interrupt OUT, not control SET_REPORT.
        val endpoint = outputEndpoint
        val sent = if (reportType == 1 && endpoint != null) {
            conn.bulkTransfer(endpoint, report, report.size, 1000)
        } else {
            conn.controlTransfer(0x21, 0x09, value, iface.id, report, report.size, 1000)
        }
        sent == report.size
    }

    override fun close() {
        running.set(false)
        ready = false
        readyLatch.countDown()
        lizardExecutor?.shutdownNow()
        executor.shutdownNow()
        unregisterPermissionReceiver()
        closeConnectionOnly()
    }

    private fun unregisterPermissionReceiver() {
        permissionReceiver?.let { receiver ->
            runCatching { context.unregisterReceiver(receiver) }
        }
        permissionReceiver = null
    }

    private fun closeConnectionOnly() = synchronized(reportIoLock) {
        val iface = claimedInterface
        val conn = connection
        if (iface != null && conn != null) {
            runCatching { conn.releaseInterface(iface) }
        }
        runCatching { conn?.close() }
        claimedInterface = null
        connection = null
        inputEndpoint = null
        outputEndpoint = null
        deviceInfo = null
    }

    companion object {
        const val VALVE_VENDOR_ID = 0x28de
        const val TRITON_USB_PRODUCT_ID = 0x1302
        const val TRITON_BLE_PRODUCT_ID = 0x1303

        internal fun hidReportValue(reportNumber: Int, reportType: Int): Int? {
            if (reportNumber !in 0..0xff) return null
            // UHID: feature/output/input = 0/1/2; USB HID: input/output/feature = 1/2/3.
            val usbType = when (reportType) {
                0 -> 3
                1 -> 2
                2 -> 1
                else -> return null
            }
            return (usbType shl 8) or reportNumber
        }

        fun isSteamController(device: UsbDevice): Boolean =
            isSteamController(device.vendorId, device.productId)

        internal fun isSteamController(vendorId: Int, productId: Int): Boolean =
            vendorId == VALVE_VENDOR_ID &&
                (productId == TRITON_USB_PRODUCT_ID || productId == TRITON_BLE_PRODUCT_ID)
    }
}
