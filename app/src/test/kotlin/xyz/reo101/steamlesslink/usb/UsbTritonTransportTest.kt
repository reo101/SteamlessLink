package xyz.reo101.steamlesslink.usb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UsbTritonTransportTest {
    @Test
    fun convertsUhidReportTypesToUsbHidValues() {
        assertEquals(0x0301, UsbTritonTransport.hidReportValue(1, 0))
        assertEquals(0x0280, UsbTritonTransport.hidReportValue(0x80, 1))
        assertEquals(0x0142, UsbTritonTransport.hidReportValue(0x42, 2))
        assertEquals(0x0300, UsbTritonTransport.hidReportValue(0, 0))
        assertNull(UsbTritonTransport.hidReportValue(-1, 0))
        assertNull(UsbTritonTransport.hidReportValue(256, 0))
        assertNull(UsbTritonTransport.hidReportValue(1, -1))
        assertNull(UsbTritonTransport.hidReportValue(1, 3))
    }

    @Test
    fun acceptsOnlySupportedSteamControllerProductIds() {
        assertTrue(UsbTritonTransport.isSteamController(0x28de, 0x1302))
        assertTrue(UsbTritonTransport.isSteamController(0x28de, 0x1303))
        assertFalse(UsbTritonTransport.isSteamController(0x28de, 0x1205))
        assertFalse(UsbTritonTransport.isSteamController(0x045e, 0x1302))
    }
}
