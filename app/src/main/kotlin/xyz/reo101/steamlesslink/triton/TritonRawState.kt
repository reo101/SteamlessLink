package xyz.reo101.steamlesslink.triton

data class TritonRawState(
    val reportId: Int,
    val sequence: Int,
    val buttons: UInt,
    val leftTrigger: Short,
    val rightTrigger: Short,
    val leftStickX: Short,
    val leftStickY: Short,
    val rightStickX: Short,
    val rightStickY: Short,
    val leftPadX: Short? = null,
    val leftPadY: Short? = null,
    val leftPadPressure: UShort? = null,
    val rightPadX: Short? = null,
    val rightPadY: Short? = null,
    val rightPadPressure: UShort? = null,
    val rawReport: ByteArray,
) {
    override fun equals(other: Any?): Boolean =
        other is TritonRawState &&
            reportId == other.reportId &&
            sequence == other.sequence &&
            buttons == other.buttons &&
            leftTrigger == other.leftTrigger &&
            rightTrigger == other.rightTrigger &&
            leftStickX == other.leftStickX &&
            leftStickY == other.leftStickY &&
            rightStickX == other.rightStickX &&
            rightStickY == other.rightStickY &&
            leftPadX == other.leftPadX &&
            leftPadY == other.leftPadY &&
            leftPadPressure == other.leftPadPressure &&
            rightPadX == other.rightPadX &&
            rightPadY == other.rightPadY &&
            rightPadPressure == other.rightPadPressure &&
            rawReport.contentEquals(other.rawReport)

    override fun hashCode(): Int =
        listOf(
            reportId,
            sequence,
            buttons,
            leftTrigger,
            rightTrigger,
            leftStickX,
            leftStickY,
            rightStickX,
            rightStickY,
            leftPadX,
            leftPadY,
            leftPadPressure,
            rightPadX,
            rightPadY,
            rightPadPressure,
        ).hashCode() * 31 + rawReport.contentHashCode()
}
