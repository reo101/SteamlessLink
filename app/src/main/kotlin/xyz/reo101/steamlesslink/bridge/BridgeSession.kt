package xyz.reo101.steamlesslink.bridge

import java.io.Closeable
import java.util.concurrent.atomic.AtomicReference
import xyz.reo101.steamlesslink.local.LocalMappingSettings
import xyz.reo101.steamlesslink.local.LocalUinputXbox360Output
import xyz.reo101.steamlesslink.protocol.ExtendedGamepadSession
import xyz.reo101.steamlesslink.raw.UhidRawClient
import xyz.reo101.steamlesslink.triton.TritonTransport

/** Resources and report state belong to one start request, never its successor. */
internal class BridgeSession(
    val startId: Int,
    val mode: String,
    val mapping: LocalMappingSettings,
    val feedGeneration: Long = 0,
    private val closeResource: (Closeable) -> Unit,
) : Closeable {
    private val lock = Any()
    private val resources = mutableListOf<Closeable>()
    @Volatile private var closed = false
    val isActive: Boolean get() = !closed
    @Volatile var transport: TritonTransport? = null
    val rawClient = AtomicReference<UhidRawClient?>(null)
    @Volatile var extended: ExtendedGamepadSession? = null
    val localOutput = AtomicReference<LocalUinputXbox360Output?>(null)
    var reportCount = 0L
    var lastReportStatusAtMs = 0L
    var lastDroppedStatusAtMs = 0L

    fun attach(resource: Closeable): Boolean {
        synchronized(lock) {
            if (!closed) {
                resources.add(resource)
                return true
            }
        }
        closeResource(resource)
        return false
    }

    fun release(resource: Closeable) {
        val owned = synchronized(lock) { resources.remove(resource) }
        if (owned) closeResource(resource)
    }

    override fun close() {
        val closing = synchronized(lock) {
            if (closed) return
            closed = true
            resources.asReversed().toList().also { resources.clear() }
        }
        rawClient.set(null)
        localOutput.set(null)
        closing.forEach(closeResource)
    }
}
