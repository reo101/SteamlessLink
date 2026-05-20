package xyz.reo101.steamlesslink.viiper

import java.nio.ByteBuffer
import java.nio.ByteOrder

data class Xbox360State(
    val buttons: UInt = 0u,
    val leftTrigger: UByte = 0u,
    val rightTrigger: UByte = 0u,
    val leftStickX: Short = 0,
    val leftStickY: Short = 0,
    val rightStickX: Short = 0,
    val rightStickY: Short = 0,
) {
    fun toViiperPacket(): ByteArray = ByteBuffer.allocate(PACKET_SIZE)
        .order(ByteOrder.LITTLE_ENDIAN)
        .putInt(buttons.toInt())
        .put(leftTrigger.toByte())
        .put(rightTrigger.toByte())
        .putShort(leftStickX)
        .putShort(leftStickY)
        .putShort(rightStickX)
        .putShort(rightStickY)
        .put(ByteArray(6))
        .array()

    companion object {
        const val PACKET_SIZE = 20
    }
}
