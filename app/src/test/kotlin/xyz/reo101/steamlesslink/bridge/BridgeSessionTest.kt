package xyz.reo101.steamlesslink.bridge

import java.io.Closeable
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test
import xyz.reo101.steamlesslink.local.LocalMappingSettings

class BridgeSessionTest {
    @Test fun stopOwnsExistingAndLateResourcesExactlyOnce() {
        val closed = mutableListOf<Int>()
        val session = BridgeSession(1, "test", LocalMappingSettings()) { it.close() }
        assertTrue(session.attach(Closeable { closed.add(1) }))
        assertTrue(session.attach(Closeable { closed.add(2) }))
        session.close()
        session.close()
        assertFalse(session.attach(Closeable { closed.add(3) }))
        assertEquals(listOf(2, 1, 3), closed)
        assertFalse(session.isActive)
    }

    @Test fun stalledResourceDoesNotBlockStoppingOrTheNextSession() {
        val executor = Executors.newCachedThreadPool()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        try {
            val session = BridgeSession(1, "test", LocalMappingSettings()) { resource -> executor.execute { resource.close() } }
            session.attach(Closeable { entered.countDown(); release.await() })
            CompletableFuture.runAsync { session.close() }.get(1, TimeUnit.SECONDS)
            assertTrue(entered.await(1, TimeUnit.SECONDS))
            assertFalse(session.isActive)
            val successor = BridgeSession(2, "test", LocalMappingSettings()) { it.close() }
            assertTrue(successor.isActive)
            successor.close()
        } finally {
            release.countDown()
            executor.shutdownNow()
        }
    }

    @Test fun concurrentStopAndAttachCannotLeakAResource() {
        val executor = Executors.newFixedThreadPool(2)
        try {
            repeat(100) {
                val closed = AtomicInteger()
                val session = BridgeSession(it, "test", LocalMappingSettings()) { resource -> resource.close() }
                val start = CountDownLatch(1)
                val attach = executor.submit { start.await(); session.attach(Closeable { closed.incrementAndGet() }) }
                val stop = executor.submit { start.await(); session.close() }
                start.countDown()
                attach.get(1, TimeUnit.SECONDS)
                stop.get(1, TimeUnit.SECONDS)
                assertEquals(1, closed.get())
            }
        } finally { executor.shutdownNow() }
    }
}
