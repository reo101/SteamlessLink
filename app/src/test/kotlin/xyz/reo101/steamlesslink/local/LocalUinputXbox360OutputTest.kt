package xyz.reo101.steamlesslink.local

import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.OutputStream
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class LocalUinputXbox360OutputTest {
    private class HelperProcess(ready: Boolean) : Process() {
        val exited = CountDownLatch(1)
        @Volatile var status = 0
        private val input = ByteArrayInputStream(ByteArray(0))
        private val errors = ByteArrayInputStream(if (ready) "steamless-uinput: ready\n".toByteArray() else ByteArray(0))
        override fun getOutputStream() = java.io.ByteArrayOutputStream()
        override fun getInputStream() = input
        override fun getErrorStream() = errors
        override fun destroy() { exited.countDown() }
        override fun waitFor(): Int { exited.await(); return status }
        override fun exitValue(): Int = if (exited.count == 0L) status else throw IllegalThreadStateException()
    }

    @Test fun missingReadinessTerminatesTheHelper() {
        val process = HelperProcess(false)
        LocalUinputXbox360Output(process).use { output ->
            assertThrows(IOException::class.java) { output.awaitReady(20) }
            assertEquals(0L, process.exited.count)
        }
    }

    @Test fun readyHelperExitReportsFailureWithoutAnotherPacket() {
        val process = HelperProcess(true)
        val failed = CompletableFuture<String>()
        LocalUinputXbox360Output(process).use { output ->
            output.awaitReady(1000, onFailure = { failed.complete(it) })
            process.status = 9
            process.destroy()
            assertTrue(failed.get(1, TimeUnit.SECONDS).contains("status 9"))
        }
    }

    @Test fun closeTerminatesTheHelperBeforeWaitingForABlockedPipe() {
        val writing = CountDownLatch(1)
        val destroyed = CountDownLatch(1)
        val process = object : Process() {
            override fun getOutputStream() = object : OutputStream() {
                override fun write(value: Int) {
                    writing.countDown()
                    destroyed.await()
                    throw IOException("Helper stopped")
                }
            }
            override fun getInputStream() = ByteArrayInputStream(ByteArray(0))
            override fun getErrorStream() = ByteArrayInputStream(ByteArray(0))
            override fun destroy() { destroyed.countDown() }
            override fun waitFor(): Int { destroyed.await(); return 0 }
            override fun exitValue(): Int = if (destroyed.count == 0L) 0 else throw IllegalThreadStateException()
        }
        val output = LocalUinputXbox360Output(process)
        val send = CompletableFuture.runAsync {
            assertThrows(IOException::class.java) { output.sendPacket(ByteArray(20)) }
        }
        try {
            assertTrue(writing.await(1, TimeUnit.SECONDS))
            CompletableFuture.runAsync { output.close() }.get(1, TimeUnit.SECONDS)
            send.get(1, TimeUnit.SECONDS)
            assertThrows(IllegalStateException::class.java) { output.sendPacket(ByteArray(20)) }
        } finally {
            process.destroy()
            output.close()
        }
    }
}
