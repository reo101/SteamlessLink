package xyz.reo101.steamlesslink.raw

import android.content.Context
import computer.iroh.Endpoint
import computer.iroh.EndpointOptions
import computer.iroh.EndpointTicket
import computer.iroh.IrohAndroid
import computer.iroh.RelayMode
import computer.iroh.presetN0
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.io.InputStream
import java.io.OutputStream

fun irohRawUhidConnection(
    context: Context,
    ticket: String,
    connectTimeoutMs: Long = 10_000,
): RawUhidConnection {
    IrohAndroid.installAndroidContext(context.applicationContext)
    val endpoint = runBlocking { Endpoint.bind(EndpointOptions(preset = presetN0(), relayMode = RelayMode.defaultMode())) }
    var closeConnection: (() -> Unit)? = null
    try {
        val addr = EndpointTicket.fromString(ticket.trim()).endpointAddr()
        val conn = runBlocking { withTimeout(connectTimeoutMs) { endpoint.connect(addr, ALPN) } }
        val bi = runBlocking { withTimeout(connectTimeoutMs) { conn.openBi() } }
        val recv = bi.recv()
        val send = bi.send()
        closeConnection = { conn.close(0, "bye".toByteArray()) }
        return RawUhidConnection(
            input = object : InputStream() {
                override fun read(): Int {
                    val one = ByteArray(1)
                    val n = read(one, 0, 1)
                    return if (n < 0) -1 else one[0].toInt() and 0xff
                }

                override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                    if (length == 0) return 0
                    val chunk = runBlocking { recv.read(length.toUInt()) }
                    if (chunk.isEmpty()) return -1
                    chunk.copyInto(buffer, offset, 0, chunk.size)
                    return chunk.size
                }
            },
            output = object : OutputStream() {
                override fun write(value: Int) = write(byteArrayOf(value.toByte()))

                override fun write(buffer: ByteArray, offset: Int, length: Int) {
                    if (length == 0) return
                    runBlocking { send.writeAll(buffer.copyOfRange(offset, offset + length)) }
                }
            },
        ) {
            runCatching { runBlocking { send.finish() } }
            closeConnection?.invoke()
            runCatching { runBlocking { endpoint.shutdown() } }
        }
    } catch (error: Throwable) {
        closeConnection?.invoke()
        runCatching { runBlocking { endpoint.shutdown() } }
        throw error
    }
}

private val ALPN = "steamlesslink/uhid-raw/0".toByteArray()
