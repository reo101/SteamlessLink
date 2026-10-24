package xyz.reo101.steamlesslink.triton

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

class FakeTritonTransportTest {
    @Test fun terminalFailureStopsReportsAndClearsReadiness() {
        val reports = AtomicInteger()
        val failed = CountDownLatch(1)
        FakeTritonTransport({ _, _ -> reports.incrementAndGet() }, {}, intervalMs = 1,
            onFailure = { failed.countDown() }, failureAfterReports = 3).use { capture ->
            capture.start()
            assertTrue(failed.await(1, TimeUnit.SECONDS))
            assertFalse(capture.awaitReady(0))
            assertEquals(3, reports.get())
        }
    }
}
