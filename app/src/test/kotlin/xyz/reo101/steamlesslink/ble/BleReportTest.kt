package xyz.reo101.steamlesslink.ble

import org.junit.Assert.assertArrayEquals
import org.junit.Test

class BleReportTest {
    @Test
    fun prependsIdWhenPayloadStartsWithIt() {
        assertArrayEquals(
            byteArrayOf(0x45, 0x45, 0, 0),
            numberBleReport(0x45, byteArrayOf(0x45, 0, 0)),
        )
    }
}
