package xyz.reo101.steamlesslink

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast
import rikka.shizuku.Shizuku
import xyz.reo101.steamlesslink.bridge.ControllerBridgeService
import xyz.reo101.steamlesslink.usb.UsbTritonTransport

class MainActivity : Activity() {
    private val prefs by lazy { getSharedPreferences("steamlesslink", MODE_PRIVATE) }
    private lateinit var statusText: TextView
    private lateinit var hostInput: EditText
    private lateinit var portInput: EditText
    private lateinit var irohTicketInput: EditText
    private lateinit var keyInput: EditText
    private lateinit var modeSpinner: Spinner
    private lateinit var transportSwitch: Switch
    private val statusReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val message = intent?.getStringExtra(ControllerBridgeService.EXTRA_STATUS) ?: return
            appendStatus(message)
        }
    }

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
            setOnApplyWindowInsetsListener { view, insets ->
                view.setPadding(
                    32 + insets.systemWindowInsetLeft,
                    32 + insets.systemWindowInsetTop,
                    32 + insets.systemWindowInsetRight,
                    32 + insets.systemWindowInsetBottom,
                )
                insets
            }
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

        irohTicketInput = EditText(this).apply {
            hint = "Iroh endpoint ticket (Raw Iroh only)"
            setSingleLine(true)
            setText(prefs.getString(PREF_IROH_TICKET, ""))
        }
        root.addView(irohTicketInput)

        keyInput = EditText(this).apply {
            hint = "VIIPER key (unused for UHID raw)"
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD
            setSingleLine(true)
            setText(prefs.getString(PREF_KEY, ""))
        }
        root.addView(keyInput)

        modeSpinner = Spinner(this).apply {
            minimumHeight = dp(56)
            setPadding(paddingLeft, dp(12), paddingRight, dp(12))
            adapter = ArrayAdapter(
                this@MainActivity,
                android.R.layout.simple_spinner_item,
                MODE_LABELS,
            ).also { it.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item) }
            setSelection(modeIndex(prefs.getString(PREF_MODE, ControllerBridgeService.MODE_UHID_RAW)))
            onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
                override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) {
                    prefs.edit().putString(PREF_MODE, selectedMode()).apply()
                    updateInputAvailability()
                }

                override fun onNothingSelected(parent: AdapterView<*>?) = Unit
            }
        }
        root.addView(modeSpinner)

        transportSwitch = Switch(this).apply {
            text = if (prefs.getBoolean(PREF_TRANSPORT_USB, false)) "Transport: USB" else "Transport: BLE"
            isChecked = prefs.getBoolean(PREF_TRANSPORT_USB, false)
            setOnCheckedChangeListener { _, checked ->
                text = if (checked) "Transport: USB" else "Transport: BLE"
                prefs.edit().putBoolean(PREF_TRANSPORT_USB, checked).apply()
            }
        }
        root.addView(transportSwitch)

        val buttonRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        buttonRow.addView(Button(this).apply {
            text = "Start"
            setOnClickListener { startBridge(selectedTransport(), selectedMode()) }
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

        updateInputAvailability()
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
        if (::modeSpinner.isInitialized) modeSpinner.setSelection(modeIndex(mode))
        val transport = intent.getStringExtra(ControllerBridgeService.EXTRA_TRANSPORT) ?: ControllerBridgeService.TRANSPORT_BLE
        val defaultPort = if (mode == ControllerBridgeService.MODE_VIIPER_XBOX360) DEFAULT_VIIPER_PORT else DEFAULT_RAW_UHID_PORT
        val port = intent.getIntExtra(ControllerBridgeService.EXTRA_PORT, defaultPort)
        val key = intent.getStringExtra(ControllerBridgeService.EXTRA_KEY).orEmpty()
        val irohTicket = intent.getStringExtra(ControllerBridgeService.EXTRA_IROH_TICKET).orEmpty()
        startBridge(host, port, key, transport, mode, irohTicket)
    }

    private fun startBridge(transport: String, mode: String) {
        prefs.edit().putString(PREF_MODE, mode).apply()
        val host = sanitizeHost(hostInput.text.toString())
        val irohTicket = irohTicketInput.text.toString().trim()
        if (mode == ControllerBridgeService.MODE_UHID_RAW_IROH && irohTicket.isBlank()) {
            statusText.text = "Enter the Iroh endpoint ticket first.\n\n${statusText.text}"
            return
        }
        if (host.isBlank() && mode != ControllerBridgeService.MODE_LOCAL_UINPUT_XBOX360 && mode != ControllerBridgeService.MODE_UHID_RAW_IROH) {
            statusText.text = "Enter the bridge host/IP first.\n\n${statusText.text}"
            return
        }
        val typedPort = portInput.text.toString().toIntOrNull()
        val port = when {
            (mode == ControllerBridgeService.MODE_UHID_RAW || mode == ControllerBridgeService.MODE_UHID_RAW_IROH) && (typedPort == null || typedPort == DEFAULT_VIIPER_PORT) -> DEFAULT_RAW_UHID_PORT
            mode == ControllerBridgeService.MODE_VIIPER_XBOX360 && (typedPort == null || typedPort == DEFAULT_RAW_UHID_PORT) -> DEFAULT_VIIPER_PORT
            mode == ControllerBridgeService.MODE_LOCAL_UINPUT_XBOX360 -> 0
            else -> typedPort
        } ?: DEFAULT_RAW_UHID_PORT
        prefs.edit().putBoolean(PREF_TRANSPORT_USB, transport == ControllerBridgeService.TRANSPORT_USB).apply()
        startBridge(host, port, keyInput.text.toString(), transport, mode, irohTicket)
    }

    private fun startBridge(host: String, port: Int, key: String, transport: String, mode: String, irohTicket: String = "") {
        if (mode == ControllerBridgeService.MODE_UHID_RAW_IROH && irohTicket.isBlank()) {
            statusText.text = "Enter the Iroh endpoint ticket first.\n\n${statusText.text}"
            return
        }
        if (host.isBlank() && mode != ControllerBridgeService.MODE_LOCAL_UINPUT_XBOX360 && mode != ControllerBridgeService.MODE_UHID_RAW_IROH) {
            statusText.text = "Enter the bridge host/IP first.\n\n${statusText.text}"
            return
        }
        if (!maybeRequestShizukuPermission(mode)) return
        if (host.isNotBlank()) hostInput.setText(host)
        if (irohTicket.isNotBlank()) irohTicketInput.setText(irohTicket)
        if (mode != ControllerBridgeService.MODE_LOCAL_UINPUT_XBOX360) portInput.setText(port.toString())
        keyInput.setText(key)
        prefs.edit().apply {
            if (host.isNotBlank()) putString(PREF_HOST, host)
            if (irohTicket.isNotBlank()) putString(PREF_IROH_TICKET, irohTicket)
            if (mode != ControllerBridgeService.MODE_LOCAL_UINPUT_XBOX360) putInt(PREF_PORT, port)
            putString(PREF_KEY, key)
            putString(PREF_MODE, mode)
        }.apply()

        val serviceIntent = Intent(this, ControllerBridgeService::class.java)
            .putExtra(ControllerBridgeService.EXTRA_HOST, host)
            .putExtra(ControllerBridgeService.EXTRA_PORT, port)
            .putExtra(ControllerBridgeService.EXTRA_KEY, key)
            .putExtra(ControllerBridgeService.EXTRA_IROH_TICKET, irohTicket)
            .putExtra(ControllerBridgeService.EXTRA_TRANSPORT, transport)
            .putExtra(ControllerBridgeService.EXTRA_MODE, mode)
        if (Build.VERSION.SDK_INT >= 26) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }
        val target = when (mode) {
            ControllerBridgeService.MODE_LOCAL_UINPUT_XBOX360 -> "local uinput"
            ControllerBridgeService.MODE_UHID_RAW_IROH -> "Iroh ${irohTicket.take(24)}..."
            else -> "$host:$port"
        }
        appendStatus("Starting $transport/$mode bridge to $target...")
    }

    override fun onStart() {
        super.onStart()
        val filter = IntentFilter(ControllerBridgeService.ACTION_STATUS)
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(statusReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(statusReceiver, filter)
        }
    }

    override fun onStop() {
        unregisterReceiver(statusReceiver)
        super.onStop()
    }

    private fun appendStatus(message: String) {
        if (!::statusText.isInitialized) return
        statusText.text = "$message\n\n${statusText.text}"
    }

    private fun refreshControllers() {
        statusText.text = buildString {
            appendBluetoothStatus()
            appendLine()
            appendUsbStatus()
            appendLine()
            appendLine("Use the connection method dropdown and BLE/USB transport toggle, then tap Start.")
            appendLine("BLE path uses bonded devices named SteamController or Steam Ctrl*. Pair in Android Bluetooth settings first.")
            appendLine("Tip: raw UHID mode should point at a Steamless UHID bridge and should show up to Steam as a Valve HID device. Raw Iroh uses an endpoint ticket instead of host:port. Xbox fallback points at a VIIPER server.")
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

    private fun selectedTransport(): String = if (transportSwitch.isChecked) {
        ControllerBridgeService.TRANSPORT_USB
    } else {
        ControllerBridgeService.TRANSPORT_BLE
    }

    private fun selectedMode(): String = MODE_VALUES.getOrElse(modeSpinner.selectedItemPosition) {
        ControllerBridgeService.MODE_UHID_RAW
    }

    private fun updateInputAvailability() {
        val mode = selectedMode()
        val usesHostPort = mode == ControllerBridgeService.MODE_UHID_RAW || mode == ControllerBridgeService.MODE_VIIPER_XBOX360
        setInputAvailability(hostInput, usesHostPort, "Bridge host/IP is used by Raw UHID and VIIPER Xbox")
        setInputAvailability(portInput, usesHostPort, "Bridge port is used by Raw UHID and VIIPER Xbox")
        setInputAvailability(irohTicketInput, mode == ControllerBridgeService.MODE_UHID_RAW_IROH, "Iroh ticket is used by Raw Iroh")
        setInputAvailability(keyInput, mode == ControllerBridgeService.MODE_VIIPER_XBOX360, "VIIPER key is used by VIIPER Xbox")
    }

    private fun setInputAvailability(input: EditText, available: Boolean, message: String) {
        input.alpha = if (available) 1f else 0.45f
        input.isFocusable = available
        input.isFocusableInTouchMode = available
        input.isCursorVisible = available
        input.isLongClickable = available
        input.setOnTouchListener(if (available) null else View.OnTouchListener { _, event ->
            if (event.action == MotionEvent.ACTION_UP) Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
            true
        })
    }

    private fun modeIndex(mode: String?): Int = MODE_VALUES.indexOf(mode ?: "").takeIf { it >= 0 } ?: 0

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

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
        private const val PREF_IROH_TICKET = "iroh_ticket"
        private const val PREF_KEY = "key"
        private const val PREF_MODE = "mode"
        private const val PREF_TRANSPORT_USB = "transport_usb"
        private const val DEFAULT_RAW_UHID_PORT = 3244
        private const val DEFAULT_VIIPER_PORT = 3242
        private const val SHIZUKU_PERMISSION_REQUEST = 200
        private val MODE_LABELS = arrayOf("Raw UHID", "Raw Iroh", "VIIPER Xbox", "Local Xbox")
        private val MODE_VALUES = arrayOf(
            ControllerBridgeService.MODE_UHID_RAW,
            ControllerBridgeService.MODE_UHID_RAW_IROH,
            ControllerBridgeService.MODE_VIIPER_XBOX360,
            ControllerBridgeService.MODE_LOCAL_UINPUT_XBOX360,
        )
    }
}
