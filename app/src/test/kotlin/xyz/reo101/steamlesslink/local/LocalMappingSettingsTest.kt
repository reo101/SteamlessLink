package xyz.reo101.steamlesslink.local

import org.junit.Assert.*
import org.junit.Test

class LocalMappingSettingsTest {
    @Test fun defaultsPreserveTheBaselineMapping() {
        val defaults = LocalMappingSettings()
        assertFalse(defaults.touchGyro)
        assertFalse(defaults.rightPadStick)
        assertEquals(listOf(0, 0, 0, 0), listOf(defaults.l4, defaults.l5, defaults.r4, defaults.r5))
        assertEquals(LocalMappingSettings.BUTTON_LABELS.size, LocalMappingSettings.BUTTON_MASKS.size)
    }

    @Test fun rejectsUnsupportedBindingsAndUnsafeSensitivity() {
        for (make in listOf<() -> LocalMappingSettings>(
            { LocalMappingSettings(l4 = -1) }, { LocalMappingSettings(r5 = 0x800) },
            { LocalMappingSettings(gyroFullScaleDps = 0) }, { LocalMappingSettings(gyroFullScaleDps = 721) },
        )) {
            assertThrows(IllegalArgumentException::class.java) { make() }
        }
    }
}
