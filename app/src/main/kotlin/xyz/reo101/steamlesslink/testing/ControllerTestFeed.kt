package xyz.reo101.steamlesslink.testing

import xyz.reo101.steamlesslink.triton.TritonRawState

/** In-process, latest-sample-only diagnostics. Never queues input or drives output. */
internal object ControllerTestFeed {
    data class Snapshot(
        val capturedAtMs: Long,
        val count: Long,
        val state: TritonRawState,
        val seenButtons: UInt,
        val output: List<Pair<Int, ByteArray>>,
        val disposition: String,
    )

    @Volatile var observing = false
    @Volatile var session = "No capture session"
        private set
    @Volatile var status = "Stopped"
        private set
    @Volatile var latest: Snapshot? = null
        private set
    private var seenButtons = 0u
    private var lastPublishedMs = Long.MIN_VALUE

    @Synchronized fun begin(label: String) {
        session = label
        status = "Starting capture"
        clear()
    }

    @Synchronized fun clear() {
        latest = null
        seenButtons = 0u
        lastPublishedMs = Long.MIN_VALUE
    }

    @Synchronized fun stop() {
        status = "Stopped"
        clear()
    }

    fun status(message: String) { status = message }

    @Synchronized fun record(
        state: TritonRawState,
        count: Long,
        output: List<Pair<Int, ByteArray>>,
        disposition: String,
        nowMs: Long = System.nanoTime() / 1_000_000,
    ) {
        if (!observing) return
        seenButtons = seenButtons or state.buttons
        if (lastPublishedMs != Long.MIN_VALUE && nowMs - lastPublishedMs < 100) return
        lastPublishedMs = nowMs
        latest = Snapshot(nowMs, count, state.copy(rawReport = state.rawReport.copyOf()), seenButtons,
            output.map { it.first to it.second.copyOf() }, disposition)
    }
}
