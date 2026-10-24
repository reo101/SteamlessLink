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
