package xyz.reo101.steamlesslink.usb

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UsbTritonTransportTest {
    @Test
    fun acceptsOnlySupportedSteamControllerProductIds() {
        assertTrue(UsbTritonTransport.isSteamController(0x28de, 0x1302))
        assertTrue(UsbTritonTransport.isSteamController(0x28de, 0x1303))
        assertFalse(UsbTritonTransport.isSteamController(0x28de, 0x1205))
        assertFalse(UsbTritonTransport.isSteamController(0x045e, 0x1302))
    }
}
