package xyz.reo101.steamlesslink.viiper

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.Socket
import java.nio.charset.StandardCharsets

/**
 * Minimal plaintext VIIPER client for MVP development.
 *
 * Use only against local unauthenticated VIIPER API endpoints.
 */
class ViiperPlaintextClient(
    private val host: String,
    private val port: Int = 3242,
    private val connectTimeoutMs: Int = 10_000,
    private val readTimeoutMs: Int = 10_000,
) : ViiperClient {
    override fun ping(): JSONObject = commandJson("ping")

    override fun createXbox360Device(): ViiperDeviceRef {
        val busId = commandJson("bus/create").getInt("busId")
        val device = commandJson("bus/$busId/add {\"type\":\"xbox360\"}")
        val devId = device.optString("devId", device.optString("id", "1"))
        return ViiperDeviceRef(busId = busId, devId = devId)
    }

    override fun openDeviceStream(ref: ViiperDeviceRef): ViiperDeviceStream {
        val socket = connect()
        socket.soTimeout = 0
        socket.getOutputStream().write("bus/${ref.busId}/${ref.devId}\u0000".toByteArray(StandardCharsets.UTF_8))
        socket.getOutputStream().flush()
        return ViiperPlaintextDeviceStream(socket)
    }

    private fun commandJson(command: String): JSONObject = JSONObject(commandRaw(command).decodeToString())

    private fun commandRaw(command: String): ByteArray {
        connect().use { socket ->
            socket.soTimeout = readTimeoutMs
            val out = socket.getOutputStream()
            out.write(command.toByteArray(StandardCharsets.UTF_8))
            out.write(0)
            out.flush()

            val input = socket.getInputStream()
            val buffer = ByteArray(4096)
            val response = ByteArrayOutputStream()
            while (true) {
                val read = try {
                    input.read(buffer)
                } catch (_: java.net.SocketTimeoutException) {
                    break
                }
                if (read < 0) break
                response.write(buffer, 0, read)
                val text = response.toString(StandardCharsets.UTF_8.name()).trim()
                if (text.endsWith("}")) break
            }
            return response.toByteArray()
        }
    }

    private fun connect() = openViiperSocket(host, port, connectTimeoutMs, readTimeoutMs)
}

class ViiperPlaintextDeviceStream(private val socket: Socket) : ViiperDeviceStream {
    @Synchronized
    override fun sendPacket(packet: ByteArray) {
        val out = socket.getOutputStream()
        out.write(packet)
        out.flush()
    }

    override fun close() {
        socket.close()
    }
}
