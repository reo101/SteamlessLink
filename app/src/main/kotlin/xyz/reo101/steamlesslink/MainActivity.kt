package xyz.reo101.steamlesslink

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
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
import xyz.reo101.steamlesslink.raw.fetchIrohTicket
import xyz.reo101.steamlesslink.raw.IrohIdentity
import xyz.reo101.steamlesslink.raw.normalizeHost
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.atomic.AtomicReference
import xyz.reo101.steamlesslink.usb.UsbTritonTransport

class MainActivity : Activity() {
    private val prefs by lazy { getSharedPreferences("steamlesslink", MODE_PRIVATE) }
    private lateinit var statusText: TextView
    private lateinit var hostInput: EditText
    private lateinit var portInput: EditText
    private lateinit var irohTicketInput: EditText
    private lateinit var modeSpinner: Spinner
    private lateinit var transportSwitch: Switch
    private val bootstrapExecutor = Executors.newSingleThreadExecutor { Thread(it, "iroh-ticket-bootstrap") }
    private var bootstrapTask: Future<*>? = null
    private val bootstrapSocket = AtomicReference<Socket?>(null)
    private var bootstrapGeneration = 0L
    private var startConfirmation: AlertDialog? = null
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
            text = "Default: BLE/USB Steam Controller/Triton -> Steamless Link host. Generic HID and local Xbox modes are available."
            textSize = 14f
        })

        hostInput = EditText(this).apply {
            hint = "Bridge host or IP"
            setSingleLine(true)
            setText(prefs.getString(PREF_HOST, ""))
        }
        root.addView(hostInput)

        portInput = EditText(this).apply {
            hint = "Bridge port (Steamless Link: $DEFAULT_RAW_UHID_PORT)"
            inputType = android.text.InputType.TYPE_CLASS_NUMBER
            setSingleLine(true)
            setText(prefs.getInt(PREF_PORT, DEFAULT_RAW_UHID_PORT).toString())
        }
        root.addView(portInput)

        irohTicketInput = EditText(this).apply {
            hint = "Iroh endpoint ticket (Steamless Link Iroh only)"
            setSingleLine(true)
            setText(prefs.getString(PREF_IROH_TICKET, ""))
        }
        root.addView(irohTicketInput)
        root.addView(Button(this).apply {
            text = "Show Iroh controller ID"
            setOnClickListener {
                runCatching { IrohIdentity.publicId(this@MainActivity) }
                    .onSuccess { id ->
                        val clipboard = getSystemService(android.content.ClipboardManager::class.java)
                        clipboard.setPrimaryClip(android.content.ClipData.newPlainText("Iroh controller ID", id))
                        appendStatus("Iroh controller ID (copied): $id\nAdd this ID to the host allowlist.")
                    }
                    .onFailure { appendStatus("Iroh identity unavailable: ${it.message}") }
            }
        })

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
                    cancelBootstrap()
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
                cancelBootstrap()
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
            setOnClickListener {
                cancelBootstrap()
                stopService(Intent(this@MainActivity, ControllerBridgeService::class.java))
            }
        })
        root.addView(buttonRow)
        root.addView(Button(this).apply {
            text = "Testing ground"
            setOnClickListener { startActivity(Intent(this@MainActivity, xyz.reo101.steamlesslink.testing.ControllerTestActivity::class.java)) }
        })
        root.addView(Button(this).apply {
            text = "Fetch Iroh ticket & Start"
            setOnClickListener { fetchAndStartIroh() }
        })

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
        intent.removeExtra(EXTRA_AUTOSTART)
        val request = Intent(intent)
        startConfirmation?.dismiss()
        startConfirmation = AlertDialog.Builder(this)
            .setTitle("Start controller bridge?")
            .setMessage("An activity request supplied a bridge destination. This replaces the active bridge.\n\n" +
                "Host: ${request.getStringExtra(ControllerBridgeService.EXTRA_HOST).orEmpty()}:${request.getIntExtra(ControllerBridgeService.EXTRA_PORT, DEFAULT_RAW_UHID_PORT)}\n" +
                "Mode: ${request.getStringExtra(ControllerBridgeService.EXTRA_MODE).orEmpty()}\n" +
                "Transport: ${request.getStringExtra(ControllerBridgeService.EXTRA_TRANSPORT).orEmpty()}\n" +
                "Iroh ticket: ${request.getStringExtra(ControllerBridgeService.EXTRA_IROH_TICKET).orEmpty()}")
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Start") { _, _ -> startConfirmedRequest(request) }
            .show()
    }

    private fun startConfirmedRequest(intent: Intent) {
        val host = normalizeHost(intent.getStringExtra(ControllerBridgeService.EXTRA_HOST).orEmpty())
        val mode = intent.getStringExtra(ControllerBridgeService.EXTRA_MODE) ?: ControllerBridgeService.MODE_UHID_RAW
        if (::modeSpinner.isInitialized) modeSpinner.setSelection(modeIndex(mode))
        val transport = intent.getStringExtra(ControllerBridgeService.EXTRA_TRANSPORT) ?: ControllerBridgeService.TRANSPORT_BLE
        val port = intent.getIntExtra(ControllerBridgeService.EXTRA_PORT, DEFAULT_RAW_UHID_PORT)
        val irohTicket = intent.getStringExtra(ControllerBridgeService.EXTRA_IROH_TICKET).orEmpty()
        if (mode == ControllerBridgeService.MODE_UHID_RAW_IROH && irohTicket.isBlank() && host.isNotBlank()) {
            hostInput.setText(host)
            portInput.setText(port.toString())
            transportSwitch.isChecked = transport == ControllerBridgeService.TRANSPORT_USB
            fetchAndStartIroh(transport)
            return
        }
        startBridge(host, port, transport, mode, irohTicket)
    }

    private fun startBridge(transport: String, mode: String) {
        cancelBootstrap()
        prefs.edit().putString(PREF_MODE, mode).apply()
        val host = normalizeHost(hostInput.text.toString())
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
        val port = if (mode == ControllerBridgeService.MODE_LOCAL_UINPUT_XBOX360) {
            0
        } else {
            typedPort ?: DEFAULT_RAW_UHID_PORT
        }
        prefs.edit().putBoolean(PREF_TRANSPORT_USB, transport == ControllerBridgeService.TRANSPORT_USB).apply()
        startBridge(host, port, transport, mode, irohTicket)
    }

    private fun startBridge(host: String, port: Int, transport: String, mode: String, irohTicket: String = "") {
        cancelBootstrap()
        if (mode != ControllerBridgeService.MODE_LOCAL_UINPUT_XBOX360 && port !in 1..65535) {
            appendStatus("Use a TCP port from 1 to 65535")
            return
        }
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
        prefs.edit().apply {
            if (host.isNotBlank()) putString(PREF_HOST, host)
            if (irohTicket.isNotBlank()) putString(PREF_IROH_TICKET, irohTicket)
            if (mode != ControllerBridgeService.MODE_LOCAL_UINPUT_XBOX360) putInt(PREF_PORT, port)
            putString(PREF_MODE, mode)
            putBoolean(PREF_TRANSPORT_USB, transport == ControllerBridgeService.TRANSPORT_USB)
        }.apply()

        val serviceIntent = Intent(this, ControllerBridgeService::class.java)
            .putExtra(ControllerBridgeService.EXTRA_HOST, host)
            .putExtra(ControllerBridgeService.EXTRA_PORT, port)
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

    private fun fetchAndStartIroh(transport: String = selectedTransport()) {
        cancelBootstrap()
        val host = normalizeHost(hostInput.text.toString())
        val port = portInput.text.toString().toIntOrNull() ?: DEFAULT_RAW_UHID_PORT
        if (host.isBlank()) {
            statusText.text = "Enter the raw TCP bridge host/IP first.\n\n${statusText.text}"
            return
        }
        if (port !in 1..65535) { appendStatus("Use a TCP port from 1 to 65535"); return }
        val generation = bootstrapGeneration
        appendStatus("Fetching Iroh ticket from $host:$port...")
        bootstrapTask = bootstrapExecutor.submit {
            runCatching { fetchIrohTicket(host, port, onSocket = { socket ->
                bootstrapSocket.set(socket)
                if (Thread.currentThread().isInterrupted) socket.close()
            }) }
                .onSuccess { ticket ->
                    runOnUiThread {
                        if (generation != bootstrapGeneration || isFinishing || isDestroyed) return@runOnUiThread
                        irohTicketInput.setText(ticket)
                        modeSpinner.setSelection(modeIndex(ControllerBridgeService.MODE_UHID_RAW_IROH))
                        startBridge(host, port, transport, ControllerBridgeService.MODE_UHID_RAW_IROH, ticket)
                    }
                }
                .onFailure { error ->
                    runOnUiThread {
                        if (generation != bootstrapGeneration || isFinishing || isDestroyed) return@runOnUiThread
                        appendStatus("Could not fetch Iroh ticket: ${error.message ?: error::class.java.simpleName}")
                    }
                }
        }
    }

    private fun cancelBootstrap() {
        bootstrapGeneration += 1
        bootstrapTask?.cancel(true)
        bootstrapTask = null
        runCatching { bootstrapSocket.getAndSet(null)?.close() }
    }

    override fun onDestroy() {
        cancelBootstrap()
        bootstrapExecutor.shutdownNow()
        super.onDestroy()
    }

    // API 26-32 do not support RECEIVER_NOT_EXPORTED. The API 33 branch sets it.
    @android.annotation.SuppressLint("UnspecifiedRegisterReceiverFlag")
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
        cancelBootstrap()
        startConfirmation?.dismiss()
        startConfirmation = null
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
            appendLine("Tip: Steamless Link preserves the Valve HID device. Generic HID Gamepad creates a standard Linux gamepad on the Steamless Link host. Steamless Link Iroh uses an endpoint ticket instead of host:port.")
            appendLine("Extended Generic HID adds rear buttons, two touchpads and IIO motion sensors. Steam does not automatically associate these companions with the gamepad; an updated host is required.")
            appendLine("Local Xbox mode bundles a virtual Android gamepad helper; it needs Shizuku or su/root and /dev/uinput.")
            appendLine("Raw BLE and USB proxy Steam feature/output reports. USB forwards the wired controller identity and descriptor; grant USB access when prompted.")
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
            val valveMark = if (UsbTritonTransport.isSteamController(device)) "  <= Steam Controller candidate" else ""
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
        val isIroh = mode == ControllerBridgeService.MODE_UHID_RAW_IROH
        val usesHostPort = mode != ControllerBridgeService.MODE_LOCAL_UINPUT_XBOX360
        hostInput.hint = if (isIroh) "Bootstrap host or IP" else "Bridge host or IP"
        portInput.hint = if (isIroh) "Bootstrap raw TCP port" else "Bridge port (Steamless Link: $DEFAULT_RAW_UHID_PORT)"
        setInputAvailability(hostInput, usesHostPort, "Bridge host/IP is used by Steamless Link, Generic HID Gamepad, and Iroh bootstrap")
        setInputAvailability(portInput, usesHostPort, "Bridge port is used by Steamless Link, Generic HID Gamepad, and Iroh bootstrap")
        setInputAvailability(irohTicketInput, isIroh, "Iroh ticket is used by Steamless Link Iroh")
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
        val legacyScanPermission = Build.VERSION.SDK_INT <= 30 &&
            checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED
        val requested = if (legacyScanPermission) permissions + listOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION) else permissions
        if (requested.isNotEmpty()) requestPermissions(requested.toTypedArray(), 100)
    }

    // Both helpers are called only after appendBluetoothStatus checks CONNECT.
    @android.annotation.SuppressLint("MissingPermission")
    private fun BluetoothDevice.safeName(): String = name ?: "(unnamed)"

    @android.annotation.SuppressLint("MissingPermission")
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
        private const val PREF_MODE = "mode"
        private const val PREF_TRANSPORT_USB = "transport_usb"
        private const val DEFAULT_RAW_UHID_PORT = 3244
        private const val SHIZUKU_PERMISSION_REQUEST = 200
        private val MODE_LABELS = arrayOf("Steamless Link", "Steamless Link Iroh", "Generic HID Gamepad", "Extended Generic HID", "Local Xbox (Shizuku/root)")
        private val MODE_VALUES = arrayOf(
            ControllerBridgeService.MODE_UHID_RAW,
            ControllerBridgeService.MODE_UHID_RAW_IROH,
            ControllerBridgeService.MODE_UHID_GENERIC_GAMEPAD,
            ControllerBridgeService.MODE_UHID_EXTENDED_GAMEPAD,
            ControllerBridgeService.MODE_LOCAL_UINPUT_XBOX360,
        )
    }
}
