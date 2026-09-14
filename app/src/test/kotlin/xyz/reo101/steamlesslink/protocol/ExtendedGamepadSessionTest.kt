package xyz.reo101.steamlesslink.protocol

import org.junit.Assert.*
import org.junit.Test

class ExtendedGamepadSessionTest {
    @Test
    fun sensorControlsAreIndependentValidatedAndCopied() {
        val session = ExtendedGamepadSession()
        val defaults = byteArrayOf(1, 1, 5, 4, 0, 0, 0)
        assertArrayEquals(defaults, session.getReport(3, 1, 0))
        assertNull(session.getReport(2, 1, 0))
        assertNull(session.getReport(3, 0, 0))
        assertNull(session.getReport(3, 3, 0))
        assertNull(session.getReport(3, 1, 1))
        session.getReport(3, 1, 0)!![1] = 2
        assertArrayEquals(defaults, session.getReport(3, 1, 0))

        val enabled = byteArrayOf(1, 2, 1, 4, 0, 0, 0)
        assertTrue(session.setReport(3, 1, 0, enabled))
        enabled[1] = 1
        assertEquals(2, session.getReport(3, 1, 0)!![1].toInt())
        assertArrayEquals(byteArrayOf(2, 1, 5, 4, 0, 0, 0), session.getReport(3, 2, 0))
        assertFalse(session.setReport(0, 1, 0, defaults))
        assertFalse(session.setReport(3, 1, 2, defaults))
        assertFalse(session.setReport(3, 1, 0, defaults.copyOf(6)))
        assertFalse(session.setReport(3, 1, 0, defaults.copyOf(8)))
        for ((offset, value) in listOf(0 to 2, 1 to 0, 1 to 3, 2 to 0, 2 to 6, 3 to 5, 6 to 128)) {
            assertFalse(session.setReport(3, 1, 0, defaults.copyOf().also { it[offset] = value.toByte() }))
        }
        assertEquals(2, session.getReport(3, 1, 0)!![1].toInt())
        assertEquals(1, session.getReport(3, 1, 2)!![0].toInt())
        assertEquals(2, session.getReport(3, 2, 2)!![0].toInt())
    }
}
