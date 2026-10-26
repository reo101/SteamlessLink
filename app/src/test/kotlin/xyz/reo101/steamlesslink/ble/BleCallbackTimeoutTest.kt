package xyz.reo101.steamlesslink.ble

import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

class BleCallbackTimeoutTest {
    private val expected = UUID.fromString("100f6c34-1735-4313-b402-38567131e5f3")
    private val other = UUID.fromString("100f6c32-1735-4313-b402-38567131e5f3")

    @Test fun wrongCharacteristicCannotCompleteWrite() {
        val pending = PendingWrite(expected)
        assertFalse(pending.complete(other, 0))
        assertTrue(pending.complete(expected, 0))
        assertEquals(0, pending.await(0))
        assertFalse(pending.complete(expected, 257))
    }

    @Test fun timeoutsRejectLateWriteAndReadCallbacks() {
        val write = PendingWrite(expected)
        assertNull(write.await(0))
        assertFalse(write.complete(expected, 0))
        val read = PendingRead(expected)
        assertNull(read.awaitResult(0))
        assertFalse(read.complete(expected, 0, byteArrayOf(42)))
    }

    @Test fun readMatchesCharacteristicAndCopiesCallbackValue() {
        val read = PendingRead(expected)
        val bytes = byteArrayOf(42)
        assertFalse(read.complete(other, 0, bytes))
        assertTrue(read.complete(expected, 0, bytes))
        bytes[0] = 0
        assertArrayEquals(byteArrayOf(42), read.awaitResult(0)!!.value)
    }
}
