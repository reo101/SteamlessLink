package xyz.reo101.steamlesslink.protocol

import xyz.reo101.steamlesslink.protocol.ExtendedGamepadProtocol as Profile
import xyz.reo101.steamlesslink.util.i32Le
import xyz.reo101.steamlesslink.util.putI32Le
import xyz.reo101.steamlesslink.util.u8

/** Per-connection HID sensor controls. Never forward these requests to Triton. */
internal class ExtendedGamepadSession {
    val deviceInfos = Profile.DESCRIPTORS.mapIndexed { index, descriptor ->
        RawProtocol.encodeDeviceInfo(
            GenericGamepadProtocol.BUS_USB, GenericGamepadProtocol.VENDOR_ID,
            GenericGamepadProtocol.PRODUCT_ID, descriptor, Profile.NAMES[index],
        )
    }
    private val features = Array(Profile.SENSOR_COUNT) { index ->
        ByteArray(Profile.SENSOR_FEATURE_SIZE).also {
            it[Profile.SENSOR_ID_OFFSET] = (index + Profile.SENSOR_FIRST_REPORT_ID).toByte()
            it[Profile.SENSOR_REPORTING_OFFSET] = Profile.SENSOR_NO_EVENTS.toByte()
            it[Profile.SENSOR_POWER_OFFSET] = Profile.SENSOR_POWER_OFF.toByte()
            it.putI32Le(Profile.SENSOR_INTERVAL_OFFSET, Profile.SENSOR_INTERVAL_MS)
        }
    }
    private val sensorReports = Array(Profile.SENSOR_COUNT) { index ->
        ByteArray(Profile.SENSOR_SIZE).also { it[Profile.SENSOR_ID_OFFSET] = (index + Profile.SENSOR_FIRST_REPORT_ID).toByte() }
    }

    @Synchronized
    fun getReport(device: Int, number: Int, type: Int): ByteArray? {
        val sensor = number - Profile.SENSOR_FIRST_REPORT_ID
        if (device != Profile.SENSOR_DEVICE || sensor !in features.indices) return null
        return when (type) {
            Profile.SENSOR_FEATURE_REPORT_TYPE -> features[sensor].copyOf()
            Profile.SENSOR_INPUT_REPORT_TYPE -> sensorReports[sensor].copyOf()
            else -> null
        }
    }

    @Synchronized
    fun setReport(device: Int, number: Int, type: Int, data: ByteArray): Boolean {
        val sensor = number - Profile.SENSOR_FIRST_REPORT_ID
        if (device != Profile.SENSOR_DEVICE || sensor !in features.indices || type != Profile.SENSOR_FEATURE_REPORT_TYPE) return false
        if (data.size != Profile.SENSOR_FEATURE_SIZE || data.u8(Profile.SENSOR_ID_OFFSET) != number) return false
        if (data.u8(Profile.SENSOR_REPORTING_OFFSET) !in Profile.SENSOR_NO_EVENTS..Profile.SENSOR_ALL_EVENTS) return false
        if (data.u8(Profile.SENSOR_POWER_OFFSET) !in Profile.SENSOR_FULL_POWER..Profile.SENSOR_POWER_OFF) return false
        if (data.i32Le(Profile.SENSOR_INTERVAL_OFFSET) != Profile.SENSOR_INTERVAL_MS) return false
        features[sensor] = data.copyOf()
        return true
    }

    @Synchronized
    fun map(report: ByteArray, length: Int): List<Pair<Int, ByteArray>> {
        val packet = ByteArray(Profile.PACKET_SIZE)
        check(NativeProtocol.tryMapTritonToExtendedGamepad(report, length, packet)) { "Zig protocol mapper is unavailable" }
        var offset = 0
        return buildList {
            for ((index, size) in Profile.REPORT_SIZES.withIndex()) {
                val data = packet.copyOfRange(offset, offset + size)
                offset += size
                val device = Profile.REPORT_DEVICES[index]
                if (device == Profile.SENSOR_DEVICE) {
                    val sensor = data.u8(Profile.SENSOR_ID_OFFSET) - Profile.SENSOR_FIRST_REPORT_ID
                    sensorReports[sensor] = data
                    // No-events/off suppress streaming; direct GET_INPUT still works.
                    if (features[sensor].u8(Profile.SENSOR_REPORTING_OFFSET) != Profile.SENSOR_ALL_EVENTS ||
                        features[sensor].u8(Profile.SENSOR_POWER_OFFSET) != Profile.SENSOR_FULL_POWER
                    ) continue
                }
                add(device to data)
            }
        }
    }
}
