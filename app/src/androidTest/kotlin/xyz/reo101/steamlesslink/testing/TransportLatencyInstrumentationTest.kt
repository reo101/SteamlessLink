package xyz.reo101.steamlesslink.testing

import android.os.Bundle
import androidx.test.platform.app.InstrumentationRegistry
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.ServerSocket
import java.nio.ByteBuffer
import org.junit.Assert.*
import org.junit.Test
import xyz.reo101.steamlesslink.raw.UhidRawClient

class TransportLatencyInstrumentationTest {
    @Test fun measureQueueToLoopbackReceiptAndControlRoundTrip() {
        ServerSocket(0).use { server ->
            UhidRawClient("127.0.0.1", server.localPort, {}, { _, _, number, _ -> byteArrayOf(number.toByte()) },
                { _, _, _, _, _ -> true }, { _, _, _ -> true }).use { client ->
                server.accept().use { socket ->
                    socket.soTimeout = 3000
                    val input = DataInputStream(socket.getInputStream())
                    val samples = LongArray(300)
                    for (index in samples.indices) {
                        val report = ByteBuffer.allocate(9).put(0x45.toByte()).putLong(System.nanoTime()).array()
                        assertTrue(client.sendInputReport(report))
                        assertEquals(1, input.readUnsignedByte())
                        val payload = ByteArray(input.readUnsignedShort()).also(input::readFully)
                        samples[index] = (System.nanoTime() - ByteBuffer.wrap(payload, 1, 8).long) / 1000
                        Thread.sleep(4)
                    }
                    val output = DataOutputStream(socket.getOutputStream())
                    val started = System.nanoTime()
                    output.write(byteArrayOf(0x82.toByte(), 0, 6, 1, 0, 0, 0, 1, 0))
                    output.flush()
                    assertEquals(2, input.readUnsignedByte())
                    val reply = ByteArray(input.readUnsignedShort()).also(input::readFully)
                    val controlUs = (System.nanoTime() - started) / 1000
                    assertArrayEquals(byteArrayOf(1, 0, 0, 0, 0, 0, 1), reply)
                    samples.sort()
                    val statistics = client.statistics()
                    assertEquals(0L, statistics.droppedSamples)
                    InstrumentationRegistry.getInstrumentation().sendStatus(0, Bundle().apply {
                        putString("transportLatencyUs", "Android TCP loopback samples=300 p50=${samples[150]} p95=${samples[285]} p99=${samples[297]} control=$controlUs $statistics")
                    })
                }
            }
        }
    }
}
