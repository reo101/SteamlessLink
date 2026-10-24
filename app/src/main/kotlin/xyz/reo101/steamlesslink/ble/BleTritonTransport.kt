package xyz.reo101.steamlesslink.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import xyz.reo101.steamlesslink.protocol.ExtendedGamepadProtocol
import xyz.reo101.steamlesslink.util.hex
import xyz.reo101.steamlesslink.util.u8
import xyz.reo101.steamlesslink.triton.CaptureLifecycle
import xyz.reo101.steamlesslink.triton.TritonTransport
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

@SuppressLint("MissingPermission")
class BleTritonTransport(
    private val context: Context,
    private val onReport: (ByteArray, Int) -> Unit,
    private val onStatus: (String) -> Unit,
    private val enableLizardModeRefresh: Boolean = true,
    private val enableImu: Boolean = false,
    private val onFailure: (String) -> Unit = {},
) : TritonTransport {
    private val bluetoothManager = context.getSystemService(BluetoothManager::class.java)
    private val adapter = bluetoothManager.adapter
    private var gatt: BluetoothGatt? = null
    private var reportCharacteristic: BluetoothGattCharacteristic? = null
    private val outputReportCharacteristics = mutableMapOf<Int, BluetoothGattCharacteristic>()
    private var inputCharacteristic: BluetoothGattCharacteristic? = null
    private val queuedOutputReports = ArrayDeque<ByteArray>()
    private val outputQueueLock = Object()
    private val outputExecutor = Executors.newSingleThreadExecutor { Thread(it, "ble-triton-output-writer") }
    private val outputClosed = AtomicBoolean(false)
    private var scanExecutor: ScheduledExecutorService? = null
    private var lizardExecutor: ScheduledExecutorService? = null
    private var scanning = false
    private var notificationCount = 0L
    private var lizardWriteCount = 0L
    private var droppedQueuedOutputReports = 0L
    private val reportIoLock = Any()
    private val pendingWrite = AtomicReference<PendingWrite?>(null)
    private val pendingRead = AtomicReference<PendingRead?>(null)
    private val lifecycle = CaptureLifecycle(onFailure)
    private var awaitingMtu = false
    private var lastNotificationStatusAtMs = 0L
    private var lastOutputDropStatusAtMs = 0L

    init {
        outputExecutor.execute(::outputWriteLoop)
    }

    override fun start() {
        val device = findBondedSteamController()
        if (device != null) {
            connect(device)
            return
        }
        startScan()
    }

    private fun findBondedSteamController(): BluetoothDevice? = adapter?.bondedDevices
        ?.filter { isSteamControllerCandidate(it) }
        ?.sortedBy { it.safeName() }
        ?.firstOrNull()

    private fun isSteamControllerCandidate(device: BluetoothDevice): Boolean {
        val name = device.safeName()
        val isLe = (device.type and BluetoothDevice.DEVICE_TYPE_LE) != 0 ||
            device.type == BluetoothDevice.DEVICE_TYPE_DUAL
        return isLe && isSteamControllerName(name)
    }

    private fun isSteamControllerName(name: String?): Boolean =
        name == "SteamController" || name?.startsWith("Steam Ctrl") == true

    private fun startScan() {
        val scanner = adapter?.bluetoothLeScanner
        if (scanner == null) {
            failCapture("BLE scanner unavailable; is Bluetooth enabled?")
            return
        }
        onStatus("No bonded Steam Controller found; scanning for BLE Steam Controller")
        scanning = true
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        scanner.startScan(null, settings, scanCallback)
        scanExecutor?.shutdownNow()
        scanExecutor = Executors.newSingleThreadScheduledExecutor { Thread(it, "ble-triton-scan-timeout") }
        scanExecutor?.schedule({
            if (scanning) {
                stopScan()
                failCapture("BLE scan timed out; pair the controller or wake it and retry")
            }
        }, SCAN_TIMEOUT_SECONDS, TimeUnit.SECONDS)
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            if (lifecycle.isClosed || !scanning) return
            val advertisedName = result.scanRecord?.deviceName ?: result.device.safeName()
            if (!isSteamControllerName(advertisedName)) return
            onStatus("Found BLE $advertisedName (${result.device.address}); connecting")
            stopScan()
            connect(result.device)
        }

        override fun onScanFailed(errorCode: Int) {
            scanning = false
            failCapture("BLE scan failed error=$errorCode")
        }
    }

    private fun stopScan() {
        if (!scanning) return
        scanning = false
        runCatching { adapter?.bluetoothLeScanner?.stopScan(scanCallback) }
    }

    private fun connect(device: BluetoothDevice) {
        if (lifecycle.isClosed) return
        onStatus("Connecting BLE ${device.safeName()} (${device.address})")
        gatt = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
        if (lifecycle.isClosed) closeGatt()
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (lifecycle.isClosed) { runCatching { gatt.close() }; return }
            if (status != BluetoothGatt.GATT_SUCCESS) {
                failCapture("BLE connection state failed status=$status state=$newState")
                return
            }
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    onStatus("BLE connected; discovering services")
                    if (!gatt.discoverServices()) failCapture("BLE service discovery could not start")
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    failCapture("BLE disconnected")
                }
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (lifecycle.isClosed) return
            if (status != BluetoothGatt.GATT_SUCCESS) {
                failCapture("BLE service discovery failed status=$status")
                return
            }

            val service = gatt.getService(STEAM_CONTROLLER_SERVICE)
            if (service == null) {
                failCapture("Valve BLE service not found; services=${gatt.services.joinToString { it.uuid.toString() }}")
                return
            }
            service.characteristics.forEach { characteristic ->
                onStatus(
                    "Valve char ${characteristic.uuid} props=0x%02x desc=${characteristic.descriptors.joinToString { it.uuid.toString() }}".format(
                        characteristic.properties,
                    ),
                )
            }

            val input = service.getCharacteristic(TRITON_TIMESTAMP_INPUT_CHARACTERISTIC)
                ?: service.getCharacteristic(TRITON_INPUT_CHARACTERISTIC)
            if (input == null) {
                failCapture("Triton BLE state characteristic not found")
                return
            }
            reportCharacteristic = service.getCharacteristic(REPORT_CHARACTERISTIC)
            outputReportCharacteristics.clear()
            service.characteristics.forEach { characteristic ->
                val reportId = reportIdFromCharacteristic(characteristic.uuid)
                if (reportId != null && reportId >= 0x80) outputReportCharacteristics[reportId] = characteristic
            }
            inputCharacteristic = input
            onStatus("Valve BLE state characteristic ${input.uuid}; enabling notifications")
            // GATT operations must not overlap MTU negotiation and CCC writes.
            awaitingMtu = true
            if (!gatt.requestMtu(517)) {
                awaitingMtu = false
                enableNotifications(gatt, input)
            }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            if (descriptor.uuid == CCC_DESCRIPTOR) completeNotificationSetup(status)
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            if (lifecycle.isClosed) return
            onStatus("BLE MTU changed mtu=$mtu status=$status")
            if (awaitingMtu) {
                awaitingMtu = false
                inputCharacteristic?.let { enableNotifications(gatt, it) }
            }
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            val pending = pendingWrite.getAndSet(null)
            pending?.complete(status)
            if (pending == null && status != BluetoothGatt.GATT_SUCCESS) {
                onStatus("Unexpected BLE write callback failure uuid=${characteristic.uuid} status=$status")
            }
        }

        @Deprecated("Deprecated by Android 13 but still called on older devices")
        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            if (characteristic.uuid == REPORT_CHARACTERISTIC) {
                @Suppress("DEPRECATION")
                pendingRead.getAndSet(null)?.complete(status, characteristic.value ?: ByteArray(0))
            }
        }

        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int,
        ) {
            if (characteristic.uuid == REPORT_CHARACTERISTIC) {
                pendingRead.getAndSet(null)?.complete(status, value)
            }
        }

        @Deprecated("Deprecated by Android 13 but still called on older devices")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            handleNotification(characteristic.uuid, characteristic.value ?: return)
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            handleNotification(characteristic.uuid, value)
        }
    }

    internal fun completeNotificationSetup(status: Int) {
        if (lifecycle.isClosed) return
        if (status != BluetoothGatt.GATT_SUCCESS) {
            failCapture("BLE notification descriptor write failed status=$status")
            return
        }
        if (!lifecycle.markReady()) return
        onStatus("BLE notifications enabled")
        if (enableLizardModeRefresh) startLizardModeRefresh()
    }

    private fun enableNotifications(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
        onStatus("Enabling BLE notifications for ${characteristic.uuid}")
        val localOk = gatt.setCharacteristicNotification(characteristic, true)
        if (!localOk) {
            failCapture("setCharacteristicNotification returned false")
            return
        }
        val descriptor = characteristic.getDescriptor(CCC_DESCRIPTOR)
        if (descriptor == null) {
            failCapture("Input characteristic has no CCC descriptor")
            return
        }
        val descriptorValue = if ((characteristic.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY) != 0) {
            BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        } else {
            BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
        }
        val queued = if (Build.VERSION.SDK_INT >= 33) {
            gatt.writeDescriptor(descriptor, descriptorValue) == BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            descriptor.value = descriptorValue
            @Suppress("DEPRECATION")
            gatt.writeDescriptor(descriptor)
        }
        if (!queued) failCapture("BLE notification descriptor write could not start")
    }

    private fun handleNotification(characteristicUuid: UUID, value: ByteArray) {
        if (lifecycle.isClosed || value.isEmpty()) return
        val reportId = reportIdFromCharacteristic(characteristicUuid) ?: return
        notificationCount += 1
        val now = System.currentTimeMillis()
        if (now - lastNotificationStatusAtMs >= NOTIFICATION_STATUS_INTERVAL_MS) {
            lastNotificationStatusAtMs = now
            onStatus(
                "BLE notifications: count=$notificationCount char=$characteristicUuid uuidId=0x%02x first=0x%02x len=${value.size} head=${value.hex(8)}".format(
                    reportId,
                    value.u8(0),
                ),
            )
        }
        val report = numberBleReport(reportId, value)
        onReport(report, report.size)
    }

    private fun startLizardModeRefresh() {
        lizardExecutor?.shutdownNow()
        lizardExecutor = Executors.newSingleThreadScheduledExecutor { Thread(it, "ble-triton-lizard-refresh") }
        lizardExecutor?.scheduleWithFixedDelay({ sendDisableLizardModeFeatureReport() }, 0, 3, TimeUnit.SECONDS)
    }

    private fun sendDisableLizardModeFeatureReport() {
        // USB feature report would be: 01 87 03 09 00 00 ...
        // Triton BLE feature writes omit the HID report id and do not need USB
        // feature padding, so send just the SetSettingsValues payload.
        val bleValue = if (enableImu) ExtendedGamepadProtocol.EXTENDED_BLE_SETTINGS else byteArrayOf(
            0x87.toByte(), // ID_SET_SETTINGS_VALUES
            0x03, // sizeof(ControllerSetting)
            0x09, // SETTING_LIZARD_MODE
            0x00, 0x00, // LIZARD_MODE_OFF, little endian u16
        )
        lizardWriteCount += 1
        if (lizardWriteCount == 1L) onStatus("Sending BLE lizard-mode-off feature report")
        if (!writeBleFeaturePayload(bleValue, timeoutMs = 1200)) onStatus("Failed BLE lizard-mode refresh")
    }

    fun writeHidFeatureReport(hidReport: ByteArray): Boolean {
        if (hidReport.isEmpty()) return false
        return writeBleFeaturePayload(hidReportPayloadForBle(hidReport), timeoutMs = 700)
    }

    fun writeHidOutputReport(hidReport: ByteArray): Boolean {
        if (hidReport.isEmpty()) return false
        val reportId = hidReport.u8(0)
        val characteristic = outputReportCharacteristics[reportId] ?: return false
        return writeBlePayload(characteristic, hidReportPayloadForBle(hidReport), timeoutMs = 2000)
    }

    fun enqueueHidOutputReport(hidReport: ByteArray): Boolean {
        if (hidReport.isEmpty() || outputClosed.get()) return false
        val copy = hidReport.copyOf()
        val reportId = copy.u8(0)
        synchronized(outputQueueLock) {
            if (outputClosed.get()) return false
            recordDroppedOutputReports(removeQueuedOutputReports(reportId))
            while (queuedOutputReports.size >= MAX_OUTPUT_REPORT_QUEUE) {
                queuedOutputReports.removeFirst()
                recordDroppedOutputReports(1)
            }
            queuedOutputReports.addLast(copy)
            outputQueueLock.notifyAll()
        }
        return true
    }

    private fun removeQueuedOutputReports(reportId: Int): Int {
        var removed = 0
        val kept = ArrayDeque<ByteArray>(queuedOutputReports.size)
        while (queuedOutputReports.isNotEmpty()) {
            val report = queuedOutputReports.removeFirst()
            if (report.u8(0) == reportId) {
                removed += 1
            } else {
                kept.addLast(report)
            }
        }
        queuedOutputReports.addAll(kept)
        return removed
    }

    private fun recordDroppedOutputReports(count: Int) {
        if (count <= 0) return
        droppedQueuedOutputReports += count.toLong()
        val now = System.currentTimeMillis()
        if (now - lastOutputDropStatusAtMs >= OUTPUT_DROP_STATUS_INTERVAL_MS) {
            lastOutputDropStatusAtMs = now
            onStatus("Dropped queued BLE output reports: count=$droppedQueuedOutputReports")
        }
    }

    private fun outputWriteLoop() {
        while (true) {
            val report = synchronized(outputQueueLock) {
                while (queuedOutputReports.isEmpty() && !outputClosed.get()) {
                    try {
                        outputQueueLock.wait()
                    } catch (_: InterruptedException) {
                        Thread.currentThread().interrupt()
                        return
                    }
                }
                if (outputClosed.get()) return
                queuedOutputReports.removeFirst()
            }

            runCatching { writeHidOutputReport(report) }
                .onSuccess { ok ->
                    if (!ok && !outputClosed.get()) {
                        onStatus("BLE output write failed len=${report.size} head=${report.hex(8)}")
                    }
                }
                .onFailure { error ->
                    if (!outputClosed.get()) {
                        onStatus("BLE output writer stopped: ${error.message ?: error::class.java.simpleName}")
                    }
                    return
                }
        }
    }

    private fun hidReportPayloadForBle(hidReport: ByteArray): ByteArray {
        // Steam/SDL HID writes include the report id and a trailing USB padding
        // byte. Triton BLE writes carry the report id in the characteristic UUID
        // or operation context and omit the padding byte.
        return if (hidReport.size >= 2) hidReport.copyOfRange(1, hidReport.size - 1) else ByteArray(0)
    }

    fun readHidFeatureReport(reportNumber: Int): ByteArray? {
        val payload = readBleFeaturePayload(timeoutMs = 2000) ?: return null
        return ByteArray(1 + payload.size).also { out ->
            out[0] = reportNumber.toByte()
            payload.copyInto(out, destinationOffset = 1)
        }
    }

    override fun awaitReady(timeoutMs: Long): Boolean = lifecycle.awaitReady(timeoutMs)

    override fun readHidReport(reportNumber: Int, reportType: Int): ByteArray? =
        if (reportType == 0) readHidFeatureReport(reportNumber) else null

    override fun writeHidReport(reportNumber: Int, reportType: Int, report: ByteArray): Boolean {
        if (reportType != 0) return false
        val written = writeHidFeatureReport(report)
        // Steam expects a successful feature ACK even when a BLE write fails.
        if (!written) onStatus("BLE feature write failed; acknowledging Steam for compatibility")
        return true
    }

    override fun sendOutputReport(reportType: Int, report: ByteArray): Boolean = enqueueHidOutputReport(report)

    private fun failCapture(reason: String) {
        if (lifecycle.isClosed) return
        onStatus(reason)
        if (lifecycle.fail(reason)) close()
    }

    private fun writeBleFeaturePayload(payload: ByteArray, timeoutMs: Long): Boolean {
        val characteristic = reportCharacteristic ?: return false
        return writeBlePayload(characteristic, payload, timeoutMs)
    }

    private fun writeBlePayload(
        characteristic: BluetoothGattCharacteristic,
        payload: ByteArray,
        timeoutMs: Long,
    ): Boolean = synchronized(reportIoLock) {
        val deadline = System.currentTimeMillis() + timeoutMs
        var attempts = 0
        var lastStatus = BluetoothGatt.GATT_FAILURE
        while (System.currentTimeMillis() < deadline) {
            val gatt = gatt ?: return@synchronized false
            val pending = PendingWrite()
            pendingWrite.set(pending)
            characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            val queued = if (Build.VERSION.SDK_INT >= 33) {
                gatt.writeCharacteristic(characteristic, payload, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                characteristic.value = payload
                @Suppress("DEPRECATION")
                gatt.writeCharacteristic(characteristic)
            }
            if (!queued) {
                pendingWrite.compareAndSet(pending, null)
                attempts += 1
                sleepBeforeRetry(deadline)
                continue
            }
            lastStatus = pending.await((deadline - System.currentTimeMillis()).coerceAtLeast(1))
            pendingWrite.compareAndSet(pending, null)
            if (lastStatus == BluetoothGatt.GATT_SUCCESS) return@synchronized true
            attempts += 1
            sleepBeforeRetry(deadline)
        }
        onStatus("BLE write exhausted retries uuid=${characteristic.uuid} attempts=$attempts status=$lastStatus len=${payload.size}")
        false
    }

    private fun readBleFeaturePayload(timeoutMs: Long): ByteArray? = synchronized(reportIoLock) {
        val characteristic = reportCharacteristic ?: return@synchronized null
        val deadline = System.currentTimeMillis() + timeoutMs
        var attempts = 0
        var lastStatus = BluetoothGatt.GATT_FAILURE
        while (System.currentTimeMillis() < deadline) {
            val gatt = gatt ?: return@synchronized null
            val pending = PendingRead()
            pendingRead.set(pending)
            if (!gatt.readCharacteristic(characteristic)) {
                pendingRead.compareAndSet(pending, null)
                attempts += 1
                sleepBeforeRetry(deadline)
                continue
            }
            val result = pending.awaitResult((deadline - System.currentTimeMillis()).coerceAtLeast(1))
            pendingRead.compareAndSet(pending, null)
            lastStatus = result.status
            if (result.status == BluetoothGatt.GATT_SUCCESS) return@synchronized result.value
            attempts += 1
            sleepBeforeRetry(deadline)
        }
        onStatus("BLE read exhausted retries uuid=${characteristic.uuid} attempts=$attempts status=$lastStatus")
        null
    }

    private fun sleepBeforeRetry(deadline: Long) {
        val remaining = deadline - System.currentTimeMillis()
        if (remaining > 0) Thread.sleep(remaining.coerceAtMost(GATT_RETRY_DELAY_MS))
    }

    override fun close() {
        if (!outputClosed.compareAndSet(false, true)) return
        lifecycle.close()
        pendingWrite.getAndSet(null)?.complete(BluetoothGatt.GATT_FAILURE)
        pendingRead.getAndSet(null)?.complete(BluetoothGatt.GATT_FAILURE, ByteArray(0))
        synchronized(outputQueueLock) {
            queuedOutputReports.clear()
            outputQueueLock.notifyAll()
        }
        outputExecutor.shutdownNow()
        stopScan()
        scanExecutor?.shutdownNow()
        lizardExecutor?.shutdownNow()
        closeGatt()
    }

    private fun closeGatt() {
        runCatching { gatt?.disconnect() }
        runCatching { gatt?.close() }
        gatt = null
        reportCharacteristic = null
        awaitingMtu = false
        outputReportCharacteristics.clear()
        inputCharacteristic = null
    }

    private fun reportIdFromCharacteristic(uuid: UUID): Int? {
        val text = uuid.toString().lowercase()
        if (!text.startsWith("100f6c") || !text.endsWith("-1735-4313-b402-38567131e5f3")) return null
        val encoded = text.substring(6, 8).toIntOrNull(16) ?: return null
        val reportId = encoded - 0x35
        return reportId.takeIf { it in 0..0xff }
    }

    private fun BluetoothDevice.safeName(): String = name ?: "(unnamed)"

    companion object {
        val STEAM_CONTROLLER_SERVICE: UUID = UUID.fromString("100f6c32-1735-4313-b402-38567131e5f3")
        val TRITON_INPUT_CHARACTERISTIC: UUID = UUID.fromString("100f6c7a-1735-4313-b402-38567131e5f3")
        val TRITON_TIMESTAMP_INPUT_CHARACTERISTIC: UUID = UUID.fromString("100f6c7c-1735-4313-b402-38567131e5f3")
        val REPORT_CHARACTERISTIC: UUID = UUID.fromString("100f6c34-1735-4313-b402-38567131e5f3")
        private val CCC_DESCRIPTOR: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        private const val SCAN_TIMEOUT_SECONDS = 15L
        private const val NOTIFICATION_STATUS_INTERVAL_MS = 1000L
        private const val GATT_RETRY_DELAY_MS = 30L
        private const val MAX_OUTPUT_REPORT_QUEUE = 4
        private const val OUTPUT_DROP_STATUS_INTERVAL_MS = 1000L
    }
}

private class PendingWrite {
    private val latch = CountDownLatch(1)
    @Volatile private var status: Int = BluetoothGatt.GATT_FAILURE

    fun complete(status: Int) {
        this.status = status
        latch.countDown()
    }

    fun await(timeoutMs: Long): Int =
        if (latch.await(timeoutMs, TimeUnit.MILLISECONDS)) status else BluetoothGatt.GATT_FAILURE
}

private class PendingRead {
    private val latch = CountDownLatch(1)
    @Volatile private var status: Int = BluetoothGatt.GATT_FAILURE
    @Volatile private var value: ByteArray = ByteArray(0)

    fun complete(status: Int, value: ByteArray) {
        this.status = status
        this.value = value.copyOf()
        latch.countDown()
    }

    fun awaitResult(timeoutMs: Long): PendingReadResult =
        if (latch.await(timeoutMs, TimeUnit.MILLISECONDS)) {
            PendingReadResult(status, value)
        } else {
            PendingReadResult(BluetoothGatt.GATT_FAILURE, ByteArray(0))
        }
}

private data class PendingReadResult(val status: Int, val value: ByteArray)

internal fun numberBleReport(reportId: Int, payload: ByteArray): ByteArray =
    ByteArray(payload.size + 1).also { report ->
        report[0] = reportId.toByte()
        payload.copyInto(report, destinationOffset = 1)
    }
