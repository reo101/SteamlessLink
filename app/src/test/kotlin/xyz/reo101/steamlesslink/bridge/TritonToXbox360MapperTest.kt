package xyz.reo101.steamlesslink.bridge

import xyz.reo101.steamlesslink.triton.SteamControllerButtons
import xyz.reo101.steamlesslink.triton.TritonRawState
import xyz.reo101.steamlesslink.viiper.Xbox360Buttons
import org.junit.Assert.assertEquals
import org.junit.Test

class TritonToXbox360MapperTest {
    @Test
    fun mapsBasicButtonsTriggersAndSticks() {
        val triton = TritonRawState(
            reportId = 0x42,
            sequence = 1,
            buttons = SteamControllerButtons.A or
                SteamControllerButtons.B or
                SteamControllerButtons.DPAD_UP or
                SteamControllerButtons.MENU or
                SteamControllerButtons.STEAM or
                SteamControllerButtons.L,
            leftTrigger = 0,
            rightTrigger = 32767,
            leftStickX = 100,
            leftStickY = 0,
            rightStickX = (-200).toShort(),
            rightStickY = 1234,
            rawReport = byteArrayOf(),
        )

        val xbox = TritonToXbox360Mapper.map(triton)

        assertEquals(
            Xbox360Buttons.A or
                Xbox360Buttons.B or
                Xbox360Buttons.DPAD_UP or
                Xbox360Buttons.START or
                Xbox360Buttons.GUIDE or
                Xbox360Buttons.LEFT_BUMPER,
            xbox.buttons,
        )
        assertEquals(0.toUByte(), xbox.leftTrigger)
        assertEquals(255.toUByte(), xbox.rightTrigger)
        assertEquals(100.toShort(), xbox.leftStickX)
        assertEquals(0.toShort(), xbox.leftStickY)
        assertEquals((-200).toShort(), xbox.rightStickX)
        assertEquals(1234.toShort(), xbox.rightStickY)
    }
}
