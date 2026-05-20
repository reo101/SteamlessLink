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
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class UsbTritonTransport(
    private val context: Context,
    private val onReport: (ByteArray, Int) -> Unit,
    private val onStatus: (String) -> Unit,
) : Closeable {
    private val usbManager = context.getSystemService(Context.USB_SERVICE) as UsbManager
    private val running = AtomicBoolean(false)
    private val executor = Executors.newSingleThreadExecutor { Thread(it, "usb-triton-reader") }
    private var lizardExecutor: ScheduledExecutorService? = null
    private var connection: UsbDeviceConnection? = null
    private var claimedInterface: UsbInterface? = null
    private var inputEndpoint: UsbEndpoint? = null
    private var permissionReceiver: BroadcastReceiver? = null

    fun start() {
        val device = findCandidateDevice()
        if (device == null) {
            onStatus("No Valve USB device found")
            return
        }

        if (!usbManager.hasPermission(device)) {
            requestPermission(device)
            return
        }

        open(device)
    }

    private fun findCandidateDevice(): UsbDevice? =
        usbManager.deviceList.values.firstOrNull { isValveDevice(it) }

    private fun requestPermission(device: UsbDevice) {
        onStatus("Requesting USB permission for ${device.deviceName}")
        val action = "${context.packageName}.USB_PERMISSION"
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
                if (granted && permittedDevice != null) {
                    onStatus("USB permission granted")
                    open(permittedDevice)
                } else {
                    onStatus("USB permission denied")
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
            return
        }

        val ifaceAndEndpoint = findHidInput(device)
        if (ifaceAndEndpoint == null) {
            openedConnection.close()
            onStatus("No HID input endpoint on ${device.deviceName}")
            return
        }

        val (usbInterface, endpoint) = ifaceAndEndpoint
        if (!openedConnection.claimInterface(usbInterface, true)) {
            openedConnection.close()
            onStatus("Failed to claim HID interface ${usbInterface.id}")
            return
        }

        connection = openedConnection
        claimedInterface = usbInterface
        inputEndpoint = endpoint
        running.set(true)
        onStatus("Opened ${device.deviceName} interface=${usbInterface.id} endpoint=${endpoint.endpointNumber}")
        startLizardModeRefresh(openedConnection, usbInterface)
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
                    onReport(buffer.copyOf(read), read)
                } else if (read < 0) {
                    onStatus("USB read failed ($read); stopping")
                    running.set(false)
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

    private fun disableLizardMode(openedConnection: UsbDeviceConnection, interfaceId: Int): Boolean {
        val report = ByteArray(64)
        report[0] = 0x01 // feature report id
        report[1] = 0x87.toByte() // ID_SET_SETTINGS_VALUES
        report[2] = 0x03 // sizeof(ControllerSetting)
        report[3] = 0x09 // SETTING_LIZARD_MODE
        report[4] = 0x00 // LIZARD_MODE_OFF, little endian u16
        report[5] = 0x00
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
        return sent == report.size
    }

    override fun close() {
        running.set(false)
        lizardExecutor?.shutdownNow()
        executor.shutdownNow()
        permissionReceiver?.let {
            runCatching { context.unregisterReceiver(it) }
        }
        closeConnectionOnly()
    }

    private fun closeConnectionOnly() {
        val iface = claimedInterface
        val conn = connection
        if (iface != null && conn != null) {
            runCatching { conn.releaseInterface(iface) }
        }
        runCatching { conn?.close() }
        claimedInterface = null
        connection = null
        inputEndpoint = null
    }

    companion object {
        const val VALVE_VENDOR_ID = 0x28de

        fun isValveDevice(device: UsbDevice): Boolean = device.vendorId == VALVE_VENDOR_ID
    }
}
