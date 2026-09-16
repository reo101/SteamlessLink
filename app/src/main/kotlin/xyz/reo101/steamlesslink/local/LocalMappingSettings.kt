package xyz.reo101.steamlesslink.local

import android.content.SharedPreferences

/** One local test profile. Raw and generic HID outputs never apply these settings. */
internal data class LocalMappingSettings(
    val l4: Int = 0,
    val l5: Int = 0,
    val r4: Int = 0,
    val r5: Int = 0,
    val rightPadStick: Boolean = false,
    val touchGyro: Boolean = false,
    val gyroFullScaleDps: Int = 180,
) {
    init {
        require(listOf(l4, l5, r4, r5).all { it in BUTTON_MASKS })
        require(gyroFullScaleDps in 30..720)
    }

    fun save(prefs: SharedPreferences) {
        prefs.edit().putInt("local_l4", l4).putInt("local_l5", l5)
            .putInt("local_r4", r4).putInt("local_r5", r5)
            .putBoolean("local_pad_stick", rightPadStick).putBoolean("local_touch_gyro", touchGyro)
            .putInt("local_gyro_dps", gyroFullScaleDps).apply()
    }

    companion object {
        val BUTTON_LABELS = arrayOf("Unbound", "A", "B", "X", "Y", "LB", "RB", "L3", "R3", "Start", "Select", "Guide", "Up", "Down", "Left", "Right")
        val BUTTON_MASKS = listOf(0, 0x1000, 0x2000, 0x4000, 0x8000, 0x100, 0x200, 0x40, 0x80, 0x10, 0x20, 0x400, 1, 2, 4, 8)

        fun load(prefs: SharedPreferences): LocalMappingSettings = LocalMappingSettings(
            l4 = prefs.getInt("local_l4", 0).takeIf { it in BUTTON_MASKS } ?: 0,
            l5 = prefs.getInt("local_l5", 0).takeIf { it in BUTTON_MASKS } ?: 0,
            r4 = prefs.getInt("local_r4", 0).takeIf { it in BUTTON_MASKS } ?: 0,
            r5 = prefs.getInt("local_r5", 0).takeIf { it in BUTTON_MASKS } ?: 0,
            rightPadStick = prefs.getBoolean("local_pad_stick", false),
            touchGyro = prefs.getBoolean("local_touch_gyro", false),
            gyroFullScaleDps = prefs.getInt("local_gyro_dps", 180).coerceIn(30, 720),
        )
    }
}
