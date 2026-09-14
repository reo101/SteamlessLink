package xyz.reo101.steamlesslink.raw

import xyz.reo101.steamlesslink.protocol.RawProtocol
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.ServerSocket
import kotlin.concurrent.thread
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
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
    fun closesWhenTheRemoteStreamEnds() {
        val client = UhidRawClient(
            connection = RawUhidConnection(ByteArrayInputStream(ByteArray(0)), ByteArrayOutputStream()) {},
            onStatus = {},
            onGetReport = { _, _, _ -> null },
            onSetReport = { _, _, _, _ -> false },
            onOutputReport = { _, _ -> false },
        )

        assertTrue(client.awaitClosed(1_000))
    }
}
