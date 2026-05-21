package xyz.reo101.steamlesslink.protocol

internal object NativeProtocol {
    private val loadError: Throwable? = runCatching {
        System.loadLibrary("steamless_protocol")
    }.exceptionOrNull()

    @Volatile
    private var disabled = false

    val isAvailable: Boolean
        get() = loadError == null && !disabled

    /**
     * Maps a raw Triton input report directly into a 20-byte VIIPER Xbox360
     * packet. Returns `false` only when the native library is unavailable;
     * protocol errors are translated to JVM exceptions by JNI.
     */
    fun tryMapTritonToViiper(
        report: ByteArray,
        length: Int,
        outPacket: ByteArray,
    ): Boolean {
        if (!isAvailable) return false
        return try {
            nativeMapTritonToViiper(report, length, outPacket)
        } catch (_: LinkageError) {
            disabled = true
            false
        }
    }

    private external fun nativeMapTritonToViiper(
        report: ByteArray,
        length: Int,
        outPacket: ByteArray,
    ): Boolean
}
