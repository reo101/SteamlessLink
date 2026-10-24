package xyz.reo101.steamlesslink.triton

internal typealias SteamControllerButtons = xyz.reo101.steamlesslink.protocol.TritonButtons

fun UInt.hasButton(mask: UInt): Boolean = (this and mask) != 0u
