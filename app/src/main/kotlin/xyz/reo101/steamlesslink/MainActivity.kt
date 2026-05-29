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
import rikka.shizuku.Shizuku
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
        maybeStartBridgeFromIntent(intent)
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
            text = "Default: BLE/USB Steam Controller/Triton -> raw UHID bridge. VIIPER xbox360 fallback and local uinput Xbox modes available."
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

        val localRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        localRow.addView(Button(this).apply {
            text = "Local Xbox BLE"
            setOnClickListener { startBridge(ControllerBridgeService.TRANSPORT_BLE, ControllerBridgeService.MODE_LOCAL_UINPUT_XBOX360) }
        })
        localRow.addView(Button(this).apply {
            text = "Local Xbox USB"
            setOnClickListener { startBridge(ControllerBridgeService.TRANSPORT_USB, ControllerBridgeService.MODE_LOCAL_UINPUT_XBOX360) }
        })
        root.addView(localRow)

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

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        setIntent(intent)
        maybeStartBridgeFromIntent(intent)
    }

    private fun maybeStartBridgeFromIntent(intent: Intent?) {
        if (intent?.getBooleanExtra(EXTRA_AUTOSTART, false) != true) return
        val host = sanitizeHost(intent.getStringExtra(ControllerBridgeService.EXTRA_HOST).orEmpty())
        val mode = intent.getStringExtra(ControllerBridgeService.EXTRA_MODE) ?: ControllerBridgeService.MODE_UHID_RAW
        val transport = intent.getStringExtra(ControllerBridgeService.EXTRA_TRANSPORT) ?: ControllerBridgeService.TRANSPORT_BLE
        val defaultPort = if (mode == ControllerBridgeService.MODE_VIIPER_XBOX360) DEFAULT_VIIPER_PORT else DEFAULT_RAW_UHID_PORT
        val port = intent.getIntExtra(ControllerBridgeService.EXTRA_PORT, defaultPort)
        val key = intent.getStringExtra(ControllerBridgeService.EXTRA_KEY).orEmpty()
        startBridge(host, port, key, transport, mode)
    }

    private fun startBridge(transport: String, mode: String) {
        val host = sanitizeHost(hostInput.text.toString())
        if (host.isBlank() && mode != ControllerBridgeService.MODE_LOCAL_UINPUT_XBOX360) {
            statusText.text = "Enter the bridge host/IP first.\n\n${statusText.text}"
            return
        }
        val typedPort = portInput.text.toString().toIntOrNull()
        val port = when {
            mode == ControllerBridgeService.MODE_UHID_RAW && (typedPort == null || typedPort == DEFAULT_VIIPER_PORT) -> DEFAULT_RAW_UHID_PORT
            mode == ControllerBridgeService.MODE_VIIPER_XBOX360 && (typedPort == null || typedPort == DEFAULT_RAW_UHID_PORT) -> DEFAULT_VIIPER_PORT
            mode == ControllerBridgeService.MODE_LOCAL_UINPUT_XBOX360 -> 0
            else -> typedPort
        } ?: DEFAULT_RAW_UHID_PORT
        startBridge(host, port, keyInput.text.toString(), transport, mode)
    }

    private fun startBridge(host: String, port: Int, key: String, transport: String, mode: String) {
        if (host.isBlank() && mode != ControllerBridgeService.MODE_LOCAL_UINPUT_XBOX360) {
            statusText.text = "Enter the bridge host/IP first.\n\n${statusText.text}"
            return
        }
        if (!maybeRequestShizukuPermission(mode)) return
        if (host.isNotBlank()) hostInput.setText(host)
        if (mode != ControllerBridgeService.MODE_LOCAL_UINPUT_XBOX360) portInput.setText(port.toString())
        keyInput.setText(key)
        prefs.edit().apply {
            if (host.isNotBlank()) putString(PREF_HOST, host)
            if (mode != ControllerBridgeService.MODE_LOCAL_UINPUT_XBOX360) putInt(PREF_PORT, port)
            putString(PREF_KEY, key)
        }.apply()

        val serviceIntent = Intent(this, ControllerBridgeService::class.java)
            .putExtra(ControllerBridgeService.EXTRA_HOST, host)
            .putExtra(ControllerBridgeService.EXTRA_PORT, port)
            .putExtra(ControllerBridgeService.EXTRA_KEY, key)
            .putExtra(ControllerBridgeService.EXTRA_TRANSPORT, transport)
            .putExtra(ControllerBridgeService.EXTRA_MODE, mode)
        if (Build.VERSION.SDK_INT >= 26) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }
        val target = if (mode == ControllerBridgeService.MODE_LOCAL_UINPUT_XBOX360) "local uinput" else "$host:$port"
        statusText.text = "Starting $transport/$mode bridge to $target...\n\n${statusText.text}"
    }

    private fun refreshControllers() {
        statusText.text = buildString {
            appendBluetoothStatus()
            appendLine()
            appendUsbStatus()
            appendLine()
            appendLine("BLE path uses bonded devices named SteamController or Steam Ctrl*. Pair in Android Bluetooth settings first.")
            appendLine("Tip: raw UHID mode should point at a Steamless UHID bridge and should show up to Steam as a Valve HID device. Xbox fallback points at a VIIPER server.")
            appendLine("Local Xbox mode creates a virtual Android gamepad through Shizuku shell or su/root; build the APK with -Psteamless.buildUinputHelper=true.")
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

    private fun maybeRequestShizukuPermission(mode: String): Boolean {
        if (mode != ControllerBridgeService.MODE_LOCAL_UINPUT_XBOX360) return true
        return runCatching {
            if (!Shizuku.pingBinder()) {
                statusText.text = "Shizuku is not running; local uinput will fall back to su/root.\n\n${statusText.text}"
                return@runCatching true
            }
            if (Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) {
                Shizuku.requestPermission(SHIZUKU_PERMISSION_REQUEST)
                statusText.text = "Requested Shizuku permission for local uinput mode. Tap Local Xbox again after granting it.\n\n${statusText.text}"
                return@runCatching false
            }
            true
        }.getOrElse { error ->
            statusText.text = "Could not request Shizuku permission: ${error.message ?: error::class.java.simpleName}; local uinput will try su/root.\n\n${statusText.text}"
            true
        }
    }

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
        const val EXTRA_AUTOSTART = "xyz.reo101.steamlesslink.extra.AUTOSTART"
        private const val PREF_HOST = "host"
        private const val PREF_PORT = "port"
        private const val PREF_KEY = "key"
        private const val DEFAULT_RAW_UHID_PORT = 3244
        private const val DEFAULT_VIIPER_PORT = 3242
        private const val SHIZUKU_PERMISSION_REQUEST = 200
    }
}
