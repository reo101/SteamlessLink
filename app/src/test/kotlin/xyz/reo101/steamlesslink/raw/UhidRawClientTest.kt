package xyz.reo101.steamlesslink.raw

import xyz.reo101.steamlesslink.protocol.RawProtocol
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.ServerSocket
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test

class UhidRawClientTest {
    @Test
    fun fetchesIrohTicketFromRawHost() {
        val server = ServerSocket(0)
        val request = ByteArray(3)
        val ticket = "endpoint-bootstrap-ticket"
        val worker = thread {
            server.use { listener ->
                listener.accept().use { socket ->
                    DataInputStream(socket.getInputStream()).readFully(request)
                    DataOutputStream(socket.getOutputStream()).apply {
                        writeByte(RawProtocol.FRAME_IROH_TICKET)
                        writeShort(ticket.length)
                        writeBytes(ticket)
                        flush()
                    }
                }
            }
        }

        assertEquals(ticket, fetchIrohTicket("127.0.0.1", server.localPort))
        worker.join()
        assertEquals(RawProtocol.FRAME_GET_IROH_TICKET, request[0].toInt() and 0xff)
        assertEquals(0, request[1].toInt())
        assertEquals(0, request[2].toInt())
    }

    @Test
    fun sendsNamedDeviceInfoBeforeStartingTheStream() {
        val deviceInfo = RawProtocol.encodeDeviceInfo(
            bus = 3,
            vendor = 0,
            product = 0,
            descriptor = byteArrayOf(0x05, 0x01),
            name = "Test",
        )
        val output = ByteArrayOutputStream()
        val client = UhidRawClient(
            connection = RawUhidConnection(ByteArrayInputStream(ByteArray(0)), output) {},
            onStatus = {},
            onGetReport = { _, _, _, _ -> null },
            onSetReport = { _, _, _, _, _ -> false },
            onOutputReport = { _, _, _ -> false },
            initialDeviceInfo = deviceInfo,
        )

        assertTrue(client.awaitClosed(1_000))
        val frame = output.toByteArray()
        assertEquals(RawProtocol.FRAME_DEVICE_INFO, frame[0].toInt() and 0xff)
        assertEquals(deviceInfo.size, ((frame[1].toInt() and 0xff) shl 8) or (frame[2].toInt() and 0xff))
        assertArrayEquals(deviceInfo, frame.copyOfRange(3, frame.size))
        assertArrayEquals(
            byteArrayOf(3, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0x05, 0x01, 4, 'T'.code.toByte(), 'e'.code.toByte(), 's'.code.toByte(), 't'.code.toByte()),
            deviceInfo,
        )
    }

    @Test(timeout = 10_000)
    fun bundleAcknowledgementRoutesControlsAndCompleteSamples() {
        ServerSocket(0).use { server ->
            server.soTimeout = 2_000
            val devices = List(4) { byteArrayOf(it.toByte()) }
            val outputSeen = CountDownLatch(1)
            val sample = listOf(0 to byteArrayOf(1, 10), 1 to byteArrayOf(1, 20), 2 to byteArrayOf(1, 30), 3 to byteArrayOf(1, 40), 3 to byteArrayOf(2, 50))
            val host = CompletableFuture.runAsync {
                server.accept().use { socket ->
                    socket.soTimeout = 2_000
                    val input = DataInputStream(socket.getInputStream())
                    val output = DataOutputStream(socket.getOutputStream())
                    val bundle = readFrame(input)
                    assertEquals(RawProtocol.FRAME_DEVICE_BUNDLE, bundle.first)
                    assertArrayEquals(byteArrayOf(4, 1, 0, 0, 1, 0, 1, 1, 0, 2, 1, 0, 3), bundle.second)
                    writeFrame(output, RawProtocol.FRAME_DEVICE_BUNDLE_READY, byteArrayOf(4))
                    writeFrame(output, RawProtocol.FRAME_DEVICE_FRAME, byteArrayOf(3, 0x82.toByte(), 9, 0, 0, 0, 2, 0))
                    assertArrayEquals(byteArrayOf(3, 2, 9, 0, 0, 0, 0, 0, 2, 99), readFrame(input).second)
                    writeFrame(output, RawProtocol.FRAME_DEVICE_FRAME, byteArrayOf(2, 0x83.toByte(), 7, 0, 0, 0, 1, 0, 1, 42))
                    assertArrayEquals(byteArrayOf(2, 3, 7, 0, 0, 0, 0, 0), readFrame(input).second)
                    writeFrame(output, RawProtocol.FRAME_DEVICE_FRAME, byteArrayOf(1, 0x81.toByte(), 1, 42))
                    for ((slot, report) in sample) {
                        val frame = readFrame(input)
                        assertEquals(RawProtocol.FRAME_DEVICE_FRAME, frame.first)
                        assertArrayEquals(byteArrayOf(slot.toByte(), 1) + report, frame.second)
                    }
                }
            }
            UhidRawClient(
                host = "127.0.0.1", port = server.localPort,
                onStatus = {}, initialDevices = devices,
                onGetReport = { slot, request, number, type ->
                    if (listOf(slot, request, number, type) == listOf(3, 9, 2, 0)) byteArrayOf(2, 99) else null
                },
                onSetReport = { slot, request, number, type, data ->
                    listOf(slot, request, number, type) == listOf(2, 7, 1, 0) && data.contentEquals(byteArrayOf(1, 42))
                },
                onOutputReport = { slot, type, data ->
                    if (slot == 1 && type == 1 && data.contentEquals(byteArrayOf(42))) outputSeen.countDown()
                    true
                },
            ).use { client ->
                assertTrue(outputSeen.await(2, TimeUnit.SECONDS))
                assertTrue(client.sendInputReports(sample))
                host.get(3, TimeUnit.SECONDS)
                assertTrue(client.awaitClosed(1_000))
            }
        }
    }

    @Test(timeout = 3_000)
    fun rejectsMissingOrMismatchedBundleAcknowledgements() {
        for (bytes in listOf(ByteArray(0), byteArrayOf(0x87.toByte(), 0, 1, 2))) {
            val closed = CountDownLatch(1)
            assertThrows(IOException::class.java) {
                UhidRawClient(
                    connection = RawUhidConnection(ByteArrayInputStream(bytes), ByteArrayOutputStream()) { closed.countDown() },
                    onStatus = {}, onGetReport = { _, _, _, _ -> null },
                    onSetReport = { _, _, _, _, _ -> false }, onOutputReport = { _, _, _ -> false },
                    initialDevices = listOf(byteArrayOf(1)),
                )
            }
            assertTrue(closed.await(1, TimeUnit.SECONDS))
        }
    }

    @Test(timeout = 8_000)
    fun timesOutAnOldHostThatKeepsTheConnectionOpen() {
        val closed = CountDownLatch(1)
        val silent = object : InputStream() {
            override fun read(): Int { closed.await(); return -1 }
        }
        val error = assertThrows(IOException::class.java) {
            UhidRawClient(
                connection = RawUhidConnection(silent, ByteArrayOutputStream()) { closed.countDown() },
                onStatus = {}, onGetReport = { _, _, _, _ -> null },
                onSetReport = { _, _, _, _, _ -> false }, onOutputReport = { _, _, _ -> false },
                initialDevices = listOf(byteArrayOf(1)),
            )
        }
        assertTrue(error.message!!.contains("upgrade the host"))
        assertTrue(closed.await(1, TimeUnit.SECONDS))
    }

    @Test(timeout = 5_000)
    fun congestionDropsWholeSamplesWithoutStarvingCompanions() {
        val input = PipedInputStream()
        val host = PipedOutputStream(input)
        host.write(byteArrayOf(0x87.toByte(), 0, 1, 4))
        val bytes = ByteArrayOutputStream()
        val hold = AtomicBoolean(false)
        val blocked = CountDownLatch(1)
        val release = CountDownLatch(1)
        // Bundle, one in-flight sample, and eight queued samples; five reports each.
        val frames = CountDownLatch(1 + 9 * 5)
        val output = object : OutputStream() {
            override fun write(value: Int) {
                if (hold.compareAndSet(true, false)) { blocked.countDown(); release.await() }
                bytes.write(value)
            }
            override fun flush() { frames.countDown() }
        }
        val slots = listOf(0, 1, 2, 3, 3)
        fun sample(sequence: Int) = slots.mapIndexed { index, slot -> slot to byteArrayOf(index.toByte(), sequence.toByte()) }
        UhidRawClient(
            connection = RawUhidConnection(input, output) { release.countDown(); input.close(); host.close() },
            onStatus = {}, onGetReport = { _, _, _, _ -> null },
            onSetReport = { _, _, _, _, _ -> false }, onOutputReport = { _, _, _ -> false },
            initialDevices = List(4) { byteArrayOf(it.toByte()) },
        ).use { client ->
            hold.set(true)
            assertTrue(client.sendInputReports(sample(0)))
            assertTrue(blocked.await(1, TimeUnit.SECONDS))
            for (sequence in 1..20) assertTrue(client.sendInputReports(sample(sequence)))
            release.countDown()
            assertTrue(frames.await(2, TimeUnit.SECONDS))
            val wire = DataInputStream(ByteArrayInputStream(bytes.toByteArray()))
            assertEquals(RawProtocol.FRAME_DEVICE_BUNDLE, readFrame(wire).first)
            for (sequence in listOf(0) + (13..20)) {
                for ((slot, report) in sample(sequence)) {
                    val frame = readFrame(wire)
                    assertEquals(RawProtocol.FRAME_DEVICE_FRAME, frame.first)
                    assertArrayEquals(byteArrayOf(slot.toByte(), 1) + report, frame.second)
                }
            }
            assertEquals(0, wire.available())
        }
    }

    private fun readFrame(input: DataInputStream): Pair<Int, ByteArray> {
        val type = input.readUnsignedByte()
        return type to ByteArray(input.readUnsignedShort()).also(input::readFully)
    }

    private fun writeFrame(output: DataOutputStream, type: Int, data: ByteArray) {
        output.writeByte(type)
        output.writeShort(data.size)
        output.write(data)
        output.flush()
    }

    @Test
    fun closesWhenTheRemoteStreamEnds() {
        val client = UhidRawClient(
            connection = RawUhidConnection(ByteArrayInputStream(ByteArray(0)), ByteArrayOutputStream()) {},
            onStatus = {},
            onGetReport = { _, _, _, _ -> null },
            onSetReport = { _, _, _, _, _ -> false },
            onOutputReport = { _, _, _ -> false },
        )

        assertTrue(client.awaitClosed(1_000))
    }
}
