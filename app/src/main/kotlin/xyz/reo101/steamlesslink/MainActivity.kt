package xyz.reo101.steamlesslink

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import xyz.reo101.steamlesslink.bridge.ControllerBridgeService
import xyz.reo101.steamlesslink.usb.UsbTritonTransport

class MainActivity : Activity() {
    private val prefs by lazy { getSharedPreferences("steamlesslink", MODE_PRIVATE) }
    private lateinit var statusText: TextView
    private lateinit var hostInput: EditText
    private lateinit var portInput: EditText
    private lateinit var keyInput: EditText

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        maybeRequestRuntimePermissions()
        setContentView(makeContentView())
        refreshControllers()
    }

    private fun makeContentView(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(32, 32, 32, 32)
        }

        root.addView(TextView(this).apply {
            text = "SteamlessLink"
            textSize = 28f
        })

        root.addView(TextView(this).apply {
            text = "Default: BLE/USB Steam Controller/Triton -> raw UHID bridge. VIIPER xbox360 fallback available."
            textSize = 14f
        })

        hostInput = EditText(this).apply {
            hint = "Bridge host or IP"
            setSingleLine(true)
            setText(prefs.getString(PREF_HOST, ""))
        }
        root.addView(hostInput)

        portInput = EditText(this).apply {
            hint = "Bridge port (raw: $DEFAULT_RAW_UHID_PORT, VIIPER: $DEFAULT_VIIPER_PORT)"
            inputType = android.text.InputType.TYPE_CLASS_NUMBER
            setSingleLine(true)
            setText(prefs.getInt(PREF_PORT, DEFAULT_RAW_UHID_PORT).toString())
        }
        root.addView(portInput)

        keyInput = EditText(this).apply {
            hint = "VIIPER key (unused for UHID raw)"
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD
            setSingleLine(true)
            setText(prefs.getString(PREF_KEY, ""))
        }
        root.addView(keyInput)

        val buttonRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        buttonRow.addView(Button(this).apply {
            text = "Start Raw BLE"
            setOnClickListener { startBridge(ControllerBridgeService.TRANSPORT_BLE, ControllerBridgeService.MODE_UHID_RAW) }
        })
        buttonRow.addView(Button(this).apply {
            text = "Raw USB (input only)"
            setOnClickListener { startBridge(ControllerBridgeService.TRANSPORT_USB, ControllerBridgeService.MODE_UHID_RAW) }
        })
        buttonRow.addView(Button(this).apply {
            text = "Xbox BLE"
            setOnClickListener { startBridge(ControllerBridgeService.TRANSPORT_BLE, ControllerBridgeService.MODE_VIIPER_XBOX360) }
        })
        buttonRow.addView(Button(this).apply {
            text = "Stop"
            setOnClickListener { stopService(Intent(this@MainActivity, ControllerBridgeService::class.java)) }
        })
        root.addView(buttonRow)

        root.addView(Button(this).apply {
            text = "Refresh controllers"
            setOnClickListener { refreshControllers() }
        })

        statusText = TextView(this).apply {
            textSize = 13f
            setTextIsSelectable(true)
        }
        root.addView(ScrollView(this).apply { addView(statusText) })

        return root
    }

    private fun startBridge(transport: String, mode: String) {
        val host = sanitizeHost(hostInput.text.toString())
        if (host.isBlank()) {
            statusText.text = "Enter the bridge host/IP first.\n\n${statusText.text}"
            return
        }
        hostInput.setText(host)
        val typedPort = portInput.text.toString().toIntOrNull()
        val port = when {
            mode == ControllerBridgeService.MODE_UHID_RAW && (typedPort == null || typedPort == DEFAULT_VIIPER_PORT) -> DEFAULT_RAW_UHID_PORT
            mode == ControllerBridgeService.MODE_VIIPER_XBOX360 && (typedPort == null || typedPort == DEFAULT_RAW_UHID_PORT) -> DEFAULT_VIIPER_PORT
            else -> typedPort
        } ?: DEFAULT_RAW_UHID_PORT
        portInput.setText(port.toString())
        val key = keyInput.text.toString()
        prefs.edit().putString(PREF_HOST, host).putInt(PREF_PORT, port).putString(PREF_KEY, key).apply()

        val intent = Intent(this, ControllerBridgeService::class.java)
            .putExtra(ControllerBridgeService.EXTRA_HOST, host)
            .putExtra(ControllerBridgeService.EXTRA_PORT, port)
            .putExtra(ControllerBridgeService.EXTRA_KEY, key)
            .putExtra(ControllerBridgeService.EXTRA_TRANSPORT, transport)
            .putExtra(ControllerBridgeService.EXTRA_MODE, mode)
        if (Build.VERSION.SDK_INT >= 26) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
        statusText.text = "Starting $transport/$mode bridge to $host:$port...\n\n${statusText.text}"
    }

    private fun refreshControllers() {
        statusText.text = buildString {
            appendBluetoothStatus()
            appendLine()
            appendUsbStatus()
            appendLine()
            appendLine("BLE path uses bonded devices named SteamController or Steam Ctrl*. Pair in Android Bluetooth settings first.")
            appendLine("Tip: raw UHID mode should point at a Steamless UHID bridge and should show up to Steam as a Valve HID device. Xbox fallback points at a VIIPER server.")
            appendLine("Raw USB currently forwards input only; Steam feature/output proxying is implemented for BLE.")
        }
    }

    private fun StringBuilder.appendBluetoothStatus() {
        if (Build.VERSION.SDK_INT >= 31 && checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) {
            appendLine("Bluetooth: BLUETOOTH_CONNECT permission not granted")
            return
        }

        val bluetoothManager = getSystemService(BluetoothManager::class.java)
        val devices = bluetoothManager.adapter?.bondedDevices.orEmpty()
            .sortedBy { it.safeName() }
        appendLine("Bonded Bluetooth devices (${devices.size}):")
        devices.forEach { device ->
            val mark = if (isSteamControllerCandidate(device)) "  <= Steam candidate" else ""
            appendLine("- ${device.safeName()} ${device.address} type=${device.type}$mark")
        }
    }

    private fun StringBuilder.appendUsbStatus() {
        val usbManager = getSystemService(USB_SERVICE) as UsbManager
        val devices = usbManager.deviceList.values
            .sortedWith(compareBy({ it.vendorId }, { it.productId }, { it.deviceName }))
        appendLine("USB devices (${devices.size}):")
        devices.forEach { device ->
            val valveMark = if (UsbTritonTransport.isValveDevice(device)) "  <= Valve candidate" else ""
            appendLine(
                "- ${device.deviceName} vid=%04x pid=%04x ifaces=${device.interfaceCount}%s".format(
                    device.vendorId,
                    device.productId,
                    valveMark,
                ),
            )
        }
    }

    private fun sanitizeHost(raw: String): String = raw
        .trim()
        .removePrefix("https://")
        .removePrefix("http://")
        .trimStart('/')
        .substringBefore('/')
        .substringBefore(':')

    private fun maybeRequestRuntimePermissions() {
        val permissions = buildList {
            if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                add(Manifest.permission.POST_NOTIFICATIONS)
            }
            if (Build.VERSION.SDK_INT >= 31) {
                if (checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) {
                    add(Manifest.permission.BLUETOOTH_CONNECT)
                }
                if (checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) != PackageManager.PERMISSION_GRANTED) {
                    add(Manifest.permission.BLUETOOTH_SCAN)
                }
            }
        }
        if (permissions.isNotEmpty()) requestPermissions(permissions.toTypedArray(), 100)
    }

    private fun BluetoothDevice.safeName(): String = name ?: "(unnamed)"

    private fun isSteamControllerCandidate(device: BluetoothDevice): Boolean {
        val name = device.safeName()
        val isLe = (device.type and BluetoothDevice.DEVICE_TYPE_LE) != 0 ||
            device.type == BluetoothDevice.DEVICE_TYPE_DUAL
        return isLe && (name == "SteamController" || name.startsWith("Steam Ctrl"))
    }

    companion object {
        private const val PREF_HOST = "host"
        private const val PREF_PORT = "port"
        private const val PREF_KEY = "key"
        private const val DEFAULT_RAW_UHID_PORT = 3244
        private const val DEFAULT_VIIPER_PORT = 3242
    }
}
