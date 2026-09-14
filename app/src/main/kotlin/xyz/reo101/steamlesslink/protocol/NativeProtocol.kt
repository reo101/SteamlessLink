package xyz.reo101.steamlesslink.protocol

internal object NativeProtocol {
    val loadError: Throwable? = runCatching {
        System.loadLibrary("steamless_protocol")
    }.exceptionOrNull()

    @Volatile
    private var disabled = false

    val isAvailable: Boolean
        get() = loadError == null && !disabled

    /**
     * Maps a raw Triton input report directly into a 20-byte Xbox 360 packet.
     * Returns `false` only when the native library is unavailable; protocol
     * errors are translated to JVM exceptions by JNI.
     */
    fun tryMapTritonToXbox360(
        report: ByteArray,
        length: Int,
        outPacket: ByteArray,
    ): Boolean {
        if (!isAvailable) return false
        return try {
            nativeMapTritonToXbox360(report, length, outPacket)
        } catch (_: LinkageError) {
            disabled = true
            false
        }
    }

    /**
     * Maps a raw Triton input report into the numbered HID input report for the
     * bundled generic gamepad profile. Returns `false` only when JNI is unavailable.
     */
    fun tryMapTritonToGenericGamepad(
        report: ByteArray,
        length: Int,
        outPacket: ByteArray,
    ): Boolean {
        if (!isAvailable) return false
        return try {
            nativeMapTritonToGenericGamepad(report, length, outPacket)
        } catch (_: LinkageError) {
            disabled = true
            false
        }
    }

    fun tryMapTritonToExtendedGamepad(report: ByteArray, length: Int, outPacket: ByteArray): Boolean {
        if (!isAvailable) return false
        return try {
            nativeMapTritonToExtendedGamepad(report, length, outPacket)
        } catch (_: LinkageError) {
            disabled = true
            false
        }
    }

    private external fun nativeMapTritonToExtendedGamepad(report: ByteArray, length: Int, outPacket: ByteArray): Boolean

    private external fun nativeMapTritonToXbox360(
        report: ByteArray,
        length: Int,
        outPacket: ByteArray,
    ): Boolean

    private external fun nativeMapTritonToGenericGamepad(
        report: ByteArray,
        length: Int,
        outPacket: ByteArray,
    ): Boolean
}
