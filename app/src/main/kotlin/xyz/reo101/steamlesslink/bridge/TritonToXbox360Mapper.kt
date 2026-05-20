package xyz.reo101.steamlesslink.bridge

import xyz.reo101.steamlesslink.triton.SteamControllerButtons
import xyz.reo101.steamlesslink.triton.TritonRawState
import xyz.reo101.steamlesslink.triton.hasButton
import xyz.reo101.steamlesslink.viiper.Xbox360Buttons
import xyz.reo101.steamlesslink.viiper.Xbox360State
import kotlin.math.roundToInt

object TritonToXbox360Mapper {
    fun map(state: TritonRawState): Xbox360State {
        var buttons = 0u
        fun button(src: UInt, dst: UInt) {
            if (state.buttons.hasButton(src)) buttons = buttons or dst
        }

        button(SteamControllerButtons.A, Xbox360Buttons.A)
        button(SteamControllerButtons.B, Xbox360Buttons.B)
        button(SteamControllerButtons.X, Xbox360Buttons.X)
        button(SteamControllerButtons.Y, Xbox360Buttons.Y)
        button(SteamControllerButtons.L, Xbox360Buttons.LEFT_BUMPER)
        button(SteamControllerButtons.R, Xbox360Buttons.RIGHT_BUMPER)
        button(SteamControllerButtons.L3, Xbox360Buttons.LEFT_STICK)
        button(SteamControllerButtons.R3, Xbox360Buttons.RIGHT_STICK)
        button(SteamControllerButtons.MENU, Xbox360Buttons.START)
        button(SteamControllerButtons.VIEW, Xbox360Buttons.BACK)
        button(SteamControllerButtons.STEAM, Xbox360Buttons.GUIDE)
        button(SteamControllerButtons.DPAD_UP, Xbox360Buttons.DPAD_UP)
        button(SteamControllerButtons.DPAD_DOWN, Xbox360Buttons.DPAD_DOWN)
        button(SteamControllerButtons.DPAD_LEFT, Xbox360Buttons.DPAD_LEFT)
        button(SteamControllerButtons.DPAD_RIGHT, Xbox360Buttons.DPAD_RIGHT)

        return Xbox360State(
            buttons = buttons,
            leftTrigger = scaleTrigger(state.leftTrigger),
            rightTrigger = scaleTrigger(state.rightTrigger),
            leftStickX = state.leftStickX,
            leftStickY = state.leftStickY,
            rightStickX = state.rightStickX,
            rightStickY = state.rightStickY,
        )
    }

    private fun scaleTrigger(raw: Short): UByte {
        val value = raw.toInt().coerceIn(0, 32767)
        return ((value / 32767.0) * 255.0).roundToInt().coerceIn(0, 255).toUByte()
    }
}
