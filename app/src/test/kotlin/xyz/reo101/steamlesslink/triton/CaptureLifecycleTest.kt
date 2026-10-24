package xyz.reo101.steamlesslink.triton

import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class CaptureLifecycleTest {
    @Test fun failedSubscriptionNeverBecomesReady() {
        val failures = mutableListOf<String>()
        val lifecycle = CaptureLifecycle(failures::add)
        assertTrue(lifecycle.fail("Notification subscription failed"))
        assertFalse(lifecycle.markReady())
        assertFalse(lifecycle.awaitReady(0))
        assertFalse(lifecycle.fail("Late disconnect"))
        assertEquals(listOf("Notification subscription failed"), failures)
    }

    @Test fun disconnectClearsReadinessAndWakesStartup() {
        val lifecycle = CaptureLifecycle {}
        assertTrue(lifecycle.markReady())
        assertTrue(lifecycle.awaitReady(0))
        lifecycle.fail("Disconnected")
        assertFalse(lifecycle.awaitReady(0))
        val pending = CaptureLifecycle { fail("Explicit close must not report failure") }
        val waiter = CompletableFuture.supplyAsync { pending.awaitReady(30_000) }
        pending.close()
        assertFalse(waiter.get(1, TimeUnit.SECONDS))
        assertFalse(pending.markReady())
    }
}
