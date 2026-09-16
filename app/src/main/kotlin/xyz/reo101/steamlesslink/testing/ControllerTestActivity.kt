package xyz.reo101.steamlesslink.testing

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import android.widget.AdapterView
import xyz.reo101.steamlesslink.MainActivity
import xyz.reo101.steamlesslink.bridge.ControllerBridgeService
import xyz.reo101.steamlesslink.local.LocalMappingSettings
import xyz.reo101.steamlesslink.protocol.ExtendedGamepadProtocol
import xyz.reo101.steamlesslink.protocol.GenericGamepadProtocol
import xyz.reo101.steamlesslink.protocol.NativeProtocol
import xyz.reo101.steamlesslink.protocol.Xbox360Protocol
import xyz.reo101.steamlesslink.triton.SteamControllerButtons
import xyz.reo101.steamlesslink.util.i16Le
import xyz.reo101.steamlesslink.util.u32Le

/** Observes the running bridge. Only the explicit Start buttons change capture/output. */
class ControllerTestActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())
    private val prefs by lazy { getSharedPreferences("steamlesslink", MODE_PRIVATE) }
    private var mapping = LocalMappingSettings()
    private lateinit var heading: TextView
    private lateinit var capture: TextView
    private lateinit var translated: TextView
    private lateinit var received: TextView
    private val receiptEvents = ArrayDeque<String>()
    private val axes = linkedMapOf<Int, String>()
    private val heldKeys = linkedSetOf<Pair<Int, Int>>()
    private var keyEvents = 0L
    private var motionEvents = 0L
    private var lastReceiptMs: Long? = null
    private var frozen: ControllerTestFeed.Snapshot? = null
    private var paused = false
    private var selectedPage = 0
    private val refresh = object : Runnable {
        override fun run() {
            render()
            handler.postDelayed(this, 100)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        mapping = LocalMappingSettings.load(prefs)
        val root = column().apply {
            setPadding(24, 24, 24, 24)
            setOnApplyWindowInsetsListener { view, insets ->
                view.setPadding(24 + insets.systemWindowInsetLeft, 24 + insets.systemWindowInsetTop,
                    24 + insets.systemWindowInsetRight, 24 + insets.systemWindowInsetBottom)
                insets
            }
        }
        root.addView(text("Controller testing ground", 24f))
        heading = text("Waiting for capture", 13f)
        root.addView(heading)
        val actions = LinearLayout(this)
        actions.addView(button("Back") { finish() })
        actions.addView(button("Clear") {
            ControllerTestFeed.clear()
            receiptEvents.clear(); axes.clear(); heldKeys.clear()
            keyEvents = 0; motionEvents = 0; lastReceiptMs = null; frozen = null
        })
        val freeze = CheckBox(this).apply {
            text = "Freeze sample"
            setOnCheckedChangeListener { _, checked ->
                paused = checked
                frozen = if (checked) ControllerTestFeed.latest else null
            }
        }
        actions.addView(freeze)
        root.addView(actions)
        root.addView(text("Observe any running bridge, or start a test below. Capture-only creates no output device. Android receipt requires this screen in the foreground.", 13f))
        val starts = LinearLayout(this)
        starts.addView(button("Capture BLE") { start(ControllerBridgeService.MODE_CAPTURE_TEST, "ble") })
        starts.addView(button("Capture USB") { start(ControllerBridgeService.MODE_CAPTURE_TEST, "usb") })
        starts.addView(button("Stop") { stopService(Intent(this, ControllerBridgeService::class.java)) })
        root.addView(starts)

        capture = text("No captured sample", 14f)
        translated = text("No translated sample", 14f)
        received = text("No Android events received", 14f)
        val pages = listOf(capture, translated, received, profileView()).map { content ->
            ScrollView(this).apply { addView(content); visibility = View.GONE }
        }
        root.addView(Spinner(this).apply {
            adapter = ArrayAdapter(this@ControllerTestActivity, android.R.layout.simple_spinner_dropdown_item,
                arrayOf("Captured input", "Translated / outgoing", "Android receipt", "Local mapping profile"))
            onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
                override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) {
                    selectedPage = position
                    pages.forEachIndexed { index, page -> page.visibility = if (index == position) View.VISIBLE else View.GONE }
                }
                override fun onNothingSelected(parent: AdapterView<*>?) = Unit
            }
        })
        pages.forEach { root.addView(it, LinearLayout.LayoutParams(-1, 0, 1f)) }
        setContentView(root)
    }

    private fun profileView(): View {
        val root = column()
        root.addView(text("Local Xbox only. Raw and generic/extended HID forwarding remain unchanged. Save, then restart local output to apply. Previews use the saved profile immediately.", 14f))
        val grips = listOf("L4" to mapping.l4, "L5" to mapping.l5, "R4" to mapping.r4, "R5" to mapping.r5).map { (name, mask) ->
            root.addView(text(name))
            Spinner(this).apply {
                adapter = ArrayAdapter(this@ControllerTestActivity, android.R.layout.simple_spinner_dropdown_item, LocalMappingSettings.BUTTON_LABELS)
                setSelection(LocalMappingSettings.BUTTON_MASKS.indexOf(mask))
                root.addView(this)
            }
        }
        val pad = CheckBox(this).apply { text = "Right pad → right stick while touched"; isChecked = mapping.rightPadStick }
        val gyro = CheckBox(this).apply { text = "Right-pad touch activates gyro → right stick"; isChecked = mapping.touchGyro }
        root.addView(pad); root.addView(gyro)
        root.addView(text("Pad replaces the right stick while touched; gyro adds device-local yaw/pitch, clamped to stick range. Release touch to disengage. This is NOT a mouse, trackball, or native sensor passthrough.", 14f))
        root.addView(text("Gyro speed for full stick deflection (30–720 °/s; lower = more sensitive)"))
        val speed = EditText(this).apply {
            inputType = android.text.InputType.TYPE_CLASS_NUMBER
            setSingleLine(true)
            setText(mapping.gyroFullScaleDps.toString())
        }
        root.addView(speed)
        val saved = text("")
        root.addView(button("Save profile") {
            val value = speed.text.toString().toIntOrNull()
            if (value == null || value !in 30..720) { speed.error = "Use 30–720 degrees/s"; return@button }
            mapping = LocalMappingSettings(
                LocalMappingSettings.BUTTON_MASKS[grips[0].selectedItemPosition],
                LocalMappingSettings.BUTTON_MASKS[grips[1].selectedItemPosition],
                LocalMappingSettings.BUTTON_MASKS[grips[2].selectedItemPosition],
                LocalMappingSettings.BUTTON_MASKS[grips[3].selectedItemPosition],
                pad.isChecked, gyro.isChecked, value,
            )
            mapping.save(prefs)
            saved.text = "Saved. Restart local output to apply; previews now use this profile."
        })
        root.addView(saved)
        root.addView(button("Start local BLE (saved profile)") { start(ControllerBridgeService.MODE_LOCAL_UINPUT_XBOX360, "ble") })
        root.addView(button("Start local USB (saved profile)") { start(ControllerBridgeService.MODE_LOCAL_UINPUT_XBOX360, "usb") })
        root.addView(text("Local start opens the main screen for Shizuku/USB permission handling. Return here with Testing ground. The existing virtual Xbox device retains its ~12.5% stick flat zone; this prototype does not calibrate gyro bias.", 14f))
        return root
    }

    private fun start(mode: String, transport: String) {
        if (mode == ControllerBridgeService.MODE_CAPTURE_TEST) {
            startForegroundService(Intent(this, ControllerBridgeService::class.java)
                .putExtra(ControllerBridgeService.EXTRA_MODE, mode)
                .putExtra(ControllerBridgeService.EXTRA_TRANSPORT, transport))
        } else {
            startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(MainActivity.EXTRA_AUTOSTART, true)
                .putExtra(ControllerBridgeService.EXTRA_MODE, mode)
                .putExtra(ControllerBridgeService.EXTRA_TRANSPORT, transport))
        }
    }

    override fun onResume() {
        super.onResume()
        ControllerTestFeed.observing = true
        handler.post(refresh)
    }

    override fun onPause() {
        handler.removeCallbacks(refresh)
        ControllerTestFeed.observing = false
        // Focus loss may swallow releases. Do not present stale held inputs as live.
        heldKeys.clear(); axes.clear()
        super.onPause()
    }

    private fun render() {
        val sample = if (paused) frozen else ControllerTestFeed.latest
        val now = System.nanoTime() / 1_000_000
        val header = "${ControllerTestFeed.session}\n${ControllerTestFeed.status}\n" +
            (sample?.let { if (paused) "FROZEN sample; reports ${it.count} (capture continues)"
                else "Sample: age ${now - it.capturedAtMs} ms; reports ${it.count}" } ?: "No sample; start capture or wait for input")
        heading.show(header)
        if (selectedPage == 0) {
            val capturedText = sample?.let {
                val s = it.state
                buildString {
                    appendLine("CAPTURED TRITON STATE, before mapping (BLE normalized to HID)\nID 0x%02x  sequence %d  bytes %d".format(s.reportId, s.sequence, s.rawReport.size))
                    appendLine("Buttons 0x%08x\nSeen since Clear 0x%08x".format(s.buttons.toLong(), it.seenButtons.toLong()))
                    appendLine("Sticks L ${s.leftStickX}, ${s.leftStickY}  R ${s.rightStickX}, ${s.rightStickY}")
                    appendLine("Triggers L ${s.leftTrigger}  R ${s.rightTrigger}")
                    appendLine("Grips held: " + listOf("L4" to SteamControllerButtons.L4, "L5" to SteamControllerButtons.L5,
                        "R4" to SteamControllerButtons.R4, "R5" to SteamControllerButtons.R5)
                        .filter { (_, mask) -> s.buttons and mask != 0u }.joinToString { it.first })
                    appendLine("Pad L ${s.leftPadX}, ${s.leftPadY}  pressure ${s.leftPadPressure}  touch ${s.buttons and SteamControllerButtons.LEFT_TOUCHPAD_TOUCH != 0u}")
                    appendLine("Pad R ${s.rightPadX}, ${s.rightPadY}  pressure ${s.rightPadPressure}  touch ${s.buttons and SteamControllerButtons.RIGHT_TOUCHPAD_TOUCH != 0u}")
                    if (s.rawReport.size >= 46) {
                        appendLine("Accel raw XYZ: ${(34..38 step 2).map { offset -> s.rawReport.i16Le(offset) }}")
                        appendLine("Gyro raw XYZ: ${(40..44 step 2).map { offset -> s.rawReport.i16Le(offset) }}")
                        appendLine("Fields present does not prove IMU streaming is enabled. Capture-only enables it; observing raw forwarding does not change controller settings.")
                    } else appendLine("IMU fields absent")
                    appendLine("\nRaw report\n${hex(s.rawReport)}")
                }
            } ?: "No captured sample"
            capture.show(capturedText)
        }
        if (selectedPage == 1) {
            val translatedText = sample?.let {
                buildString {
                    appendLine("ACTUAL OUTPUT ATTEMPT\n${it.disposition}")
                    it.output.forEach { (slot, packet) -> appendLine("Slot $slot (${packet.size} bytes): ${hex(packet)}") }
                    appendLine("\nPREVIEWS ONLY, never sent by this screen")
                    appendLine("These are independent mappings of the same captured sample, not proof that an output device received them.")
                    val raw = it.state.rawReport
                    val xbox = ByteArray(Xbox360Protocol.PACKET_SIZE)
                    val generic = ByteArray(GenericGamepadProtocol.INPUT_REPORT_SIZE)
                    val extended = ByteArray(ExtendedGamepadProtocol.PACKET_SIZE)
                    runCatching {
                        check(NativeProtocol.tryMapTritonToXbox360(raw, raw.size, xbox)) { "Native mapper unavailable" }
                        appendLine("\nDefault Xbox: ${describeXbox(xbox)}\n${hex(xbox)}")
                        check(NativeProtocol.tryMapTritonToLocalXbox360(raw, raw.size, xbox, mapping)) { "Local mapper unavailable" }
                        appendLine("\nSaved local profile: ${describeXbox(xbox)}\n${hex(xbox)}")
                        check(NativeProtocol.tryMapTritonToGenericGamepad(raw, raw.size, generic)) { "Generic mapper unavailable" }
                        appendLine("\nGeneric HID: ${hex(generic)}")
                        check(NativeProtocol.tryMapTritonToExtendedGamepad(raw, raw.size, extended)) { "Extended mapper unavailable" }
                        appendLine("\nExtended HID (all reports, before host sensor gating)")
                        var offset = 0
                        ExtendedGamepadProtocol.REPORT_SIZES.forEachIndexed { index, size ->
                            appendLine("Slot ${ExtendedGamepadProtocol.REPORT_DEVICES[index]}: ${hex(extended.copyOfRange(offset, offset + size))}")
                            offset += size
                        }
                    }.onFailure { appendLine("Preview unavailable: ${it.message}") }
                }
            } ?: "No sample to translate"
            translated.show(translatedText)
        }
        if (selectedPage == 2) {
            heldKeys.removeAll { InputDevice.getDevice(it.first) == null }
            axes.keys.removeAll { InputDevice.getDevice(it) == null }
            val receivedText = buildString {
                appendLine("ANDROID FRAMEWORK RECEIPT\nOnly events delivered to THIS foreground activity. Not proof of another app or remote host receiving input. Freeze affects captured samples only.")
                appendLine("Key events $keyEvents; motion events $motionEvents")
                appendLine(lastReceiptMs?.let { "Last event ${now - it} ms ago" } ?: "No events received")
                appendLine("Held: ${heldKeys.joinToString { "device ${it.first}: ${KeyEvent.keyCodeToString(it.second)}" }}")
                axes.values.forEach { appendLine(it) }
                appendLine("\nRecent keys")
                receiptEvents.forEach { appendLine(it) }
                appendLine("\nEnumerated gamepads (enumeration is not receipt)")
                InputDevice.getDeviceIds().asSequence().mapNotNull(InputDevice::getDevice).filter { isGamepad(it) }.forEach { device ->
                    appendLine("${device.id}: ${device.name}\nVID:PID %04x:%04x; controller ${device.controllerNumber}".format(device.vendorId, device.productId))
                }
            }
            received.show(receivedText)
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (isGamepad(event.device)) {
            keyEvents++
            lastReceiptMs = System.nanoTime() / 1_000_000
            val key = event.deviceId to event.keyCode
            if (event.action == KeyEvent.ACTION_DOWN) heldKeys.add(key) else if (event.action == KeyEvent.ACTION_UP) heldKeys.remove(key)
            receiptEvents.addFirst("${event.deviceId} ${event.device?.name}: ${KeyEvent.keyCodeToString(event.keyCode)} ${if (event.action == KeyEvent.ACTION_UP) "UP" else "DOWN"}")
            while (receiptEvents.size > 12) receiptEvents.removeLast()
            return true // Keep test buttons from activating UI controls or leaving the tester.
        }
        return super.dispatchKeyEvent(event)
    }

    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean {
        if (event.isFromSource(InputDevice.SOURCE_JOYSTICK)) {
            motionEvents++
            lastReceiptMs = System.nanoTime() / 1_000_000
            axes[event.deviceId] = "${event.deviceId} ${event.device?.name}\n" +
                listOf(MotionEvent.AXIS_X, MotionEvent.AXIS_Y, MotionEvent.AXIS_Z, MotionEvent.AXIS_RZ,
                    MotionEvent.AXIS_LTRIGGER, MotionEvent.AXIS_RTRIGGER, MotionEvent.AXIS_HAT_X, MotionEvent.AXIS_HAT_Y)
                    .joinToString { axis -> "${MotionEvent.axisToString(axis)}=%.3f".format(event.getAxisValue(axis)) }
            return true
        }
        return super.dispatchGenericMotionEvent(event)
    }

    internal fun receivedKeyHistory(): List<String> = receiptEvents.toList()

    private fun isGamepad(device: InputDevice?): Boolean = device != null &&
        (device.supportsSource(InputDevice.SOURCE_GAMEPAD) || device.supportsSource(InputDevice.SOURCE_JOYSTICK))
    private fun TextView.show(value: String) { if (text.toString() != value) text = value }
    private fun column() = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
    private fun text(value: String, size: Float = 16f) = TextView(this).apply { text = value; textSize = size; setTextIsSelectable(true) }
    private fun button(label: String, action: () -> Unit) = Button(this).apply { text = label; setOnClickListener { action() } }
    private fun hex(bytes: ByteArray) = bytes.joinToString(" ") { "%02x".format(it.toInt() and 0xff) }
    private fun describeXbox(bytes: ByteArray) = "buttons 0x%04x; LT %d RT %d; L %d,%d R %d,%d".format(
        bytes.u32Le(0).toLong(), bytes[4].toInt() and 0xff, bytes[5].toInt() and 0xff,
        bytes.i16Le(6), bytes.i16Le(8), bytes.i16Le(10), bytes.i16Le(12))
}
