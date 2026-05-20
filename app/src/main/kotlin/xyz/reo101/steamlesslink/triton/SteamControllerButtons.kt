package xyz.reo101.steamlesslink.triton

object SteamControllerButtons {
    const val A: UInt = 0x0000_0001u
    const val B: UInt = 0x0000_0002u
    const val X: UInt = 0x0000_0004u
    const val Y: UInt = 0x0000_0008u
    const val QAM: UInt = 0x0000_0010u
    const val R3: UInt = 0x0000_0020u
    const val VIEW: UInt = 0x0000_0040u
    const val R4: UInt = 0x0000_0080u
    const val R5: UInt = 0x0000_0100u
    const val R: UInt = 0x0000_0200u
    const val DPAD_DOWN: UInt = 0x0000_0400u
    const val DPAD_RIGHT: UInt = 0x0000_0800u
    const val DPAD_LEFT: UInt = 0x0000_1000u
    const val DPAD_UP: UInt = 0x0000_2000u
    const val MENU: UInt = 0x0000_4000u
    const val L3: UInt = 0x0000_8000u
    const val STEAM: UInt = 0x0001_0000u
    const val L4: UInt = 0x0002_0000u
    const val L5: UInt = 0x0004_0000u
    const val L: UInt = 0x0008_0000u
    const val RIGHT_JOYSTICK_TOUCH: UInt = 0x0010_0000u
    const val RIGHT_TOUCHPAD_TOUCH: UInt = 0x0020_0000u
    const val RIGHT_TOUCHPAD_CLICK: UInt = 0x0040_0000u
    const val RIGHT_TRIGGER_CLICK: UInt = 0x0080_0000u
    const val LEFT_JOYSTICK_TOUCH: UInt = 0x0100_0000u
    const val LEFT_TOUCHPAD_TOUCH: UInt = 0x0200_0000u
    const val LEFT_TOUCHPAD_CLICK: UInt = 0x0400_0000u
    const val LEFT_TRIGGER_CLICK: UInt = 0x0800_0000u
    const val RIGHT_GRIP_TOUCH: UInt = 0x1000_0000u
    const val LEFT_GRIP_TOUCH: UInt = 0x2000_0000u
}

fun UInt.hasButton(mask: UInt): Boolean = (this and mask) != 0u
