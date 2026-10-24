package xyz.reo101.steamlesslink.triton

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** A failed or closed capture cannot become ready again. */
internal class CaptureLifecycle(private val onFailure: (String) -> Unit) {
    private enum class State { STARTING, READY, CLOSED }
    private val state = AtomicReference(State.STARTING)
    private val settled = CountDownLatch(1)

    val isClosed: Boolean get() = state.get() == State.CLOSED

    fun markReady(): Boolean {
        if (!state.compareAndSet(State.STARTING, State.READY)) return false
        settled.countDown()
        return true
    }

    fun awaitReady(timeoutMs: Long): Boolean {
        settled.await(timeoutMs, TimeUnit.MILLISECONDS)
        return state.get() == State.READY
    }

    fun fail(reason: String): Boolean {
        if (state.getAndSet(State.CLOSED) == State.CLOSED) return false
        settled.countDown()
        onFailure(reason)
        return true
    }

    fun close() {
        state.set(State.CLOSED)
        settled.countDown()
    }
}
