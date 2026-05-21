package xyz.reo101.steamlesslink.viiper

import xyz.reo101.steamlesslink.util.hex
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.DataInputStream
import java.io.EOFException
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

class ViiperAuthenticatedClient(
    private val host: String,
    private val port: Int = 3242,
    private val password: String,
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
        val conn = connectAuthenticated()
        conn.writePlain("bus/${ref.busId}/${ref.devId}\u0000".toByteArray(StandardCharsets.UTF_8))
        return ViiperAuthenticatedDeviceStream(conn)
    }

    private fun commandJson(command: String): JSONObject = JSONObject(commandRaw(command).decodeToString())

    private fun commandRaw(command: String): ByteArray {
        connectAuthenticated().use { conn ->
            conn.socket.soTimeout = readTimeoutMs
            conn.writePlain(command.toByteArray(StandardCharsets.UTF_8) + byteArrayOf(0))
            val response = ByteArrayOutputStream()
            while (true) {
                val plain = conn.readPlainPacket()
                response.write(plain)
                val text = response.toString(StandardCharsets.UTF_8.name()).trim()
                if (text.endsWith("}")) break
            }
            return response.toByteArray()
        }
    }

    private fun connectAuthenticated(): EncryptedViiperConnection {
        val socket = openViiperSocket(host, port, connectTimeoutMs, readTimeoutMs)

        val key = deriveKey(password)
        val clientNonce = ByteArray(NONCE_SIZE).also { secureRandom.nextBytes(it) }
        val authMac = hmacSha256(key, AUTH_CONTEXT.toByteArray(StandardCharsets.UTF_8) + clientNonce)
        socket.getOutputStream().write(HANDSHAKE_MAGIC + clientNonce + authMac)
        socket.getOutputStream().flush()

        val input = DataInputStream(socket.getInputStream())
        val ok = ByteArray(3)
        input.readFully(ok)
        if (!ok.contentEquals(byteArrayOf('O'.code.toByte(), 'K'.code.toByte(), 0))) {
            socket.close()
            error("VIIPER auth rejected: ${ok.hex()}")
        }
        val serverNonce = ByteArray(NONCE_SIZE)
        input.readFully(serverNonce)

        val sessionKey = sha256(key + serverNonce + clientNonce + SESSION_CONTEXT.toByteArray(StandardCharsets.UTF_8))
        return EncryptedViiperConnection(socket, input, sessionKey)
    }

    companion object {
        private val HANDSHAKE_MAGIC = byteArrayOf('e'.code.toByte(), 'V'.code.toByte(), 'I'.code.toByte(), '1'.code.toByte(), 0)
        private const val NONCE_SIZE = 32
        private const val AUTH_CONTEXT = "VIIPER-Auth-v1"
        private const val SESSION_CONTEXT = "VIIPER-Session-v1"
        private val PBKDF2_SALT = "VIIPER-Key-v1".toByteArray(StandardCharsets.UTF_8)
        private const val PBKDF2_ITERATIONS = 100_000
        private val secureRandom = SecureRandom()

        private fun deriveKey(password: String): ByteArray {
            val spec = PBEKeySpec(password.toCharArray(), PBKDF2_SALT, PBKDF2_ITERATIONS, 32 * 8)
            return SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
        }

        private fun hmacSha256(key: ByteArray, message: ByteArray): ByteArray {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(key, "HmacSHA256"))
            return mac.doFinal(message)
        }

        private fun sha256(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)
    }
}

private class ViiperAuthenticatedDeviceStream(private val conn: EncryptedViiperConnection) : ViiperDeviceStream {
    @Synchronized
    override fun sendPacket(packet: ByteArray) {
        conn.writePlain(packet)
    }

    override fun close() {
        conn.close()
    }
}

private class EncryptedViiperConnection(
    val socket: Socket,
    private val input: DataInputStream,
    private val sessionKey: ByteArray,
) : Closeable {
    private var sendCounter = 0L

    @Synchronized
    fun writePlain(plain: ByteArray) {
        val nonce = nextNonce(sendCounter++)
        val cipherText = crypt(Cipher.ENCRYPT_MODE, sessionKey, nonce, plain)
        val length = nonce.size + cipherText.size
        val out = socket.getOutputStream()
        out.write(ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(length).array())
        out.write(nonce)
        out.write(cipherText)
        out.flush()
    }

    fun readPlainPacket(): ByteArray {
        val length = try {
            input.readInt()
        } catch (e: EOFException) {
            throw e
        }
        require(length >= 12) { "invalid encrypted VIIPER packet length: $length" }
        val nonce = ByteArray(12)
        input.readFully(nonce)
        val cipherText = ByteArray(length - 12)
        input.readFully(cipherText)
        return crypt(Cipher.DECRYPT_MODE, sessionKey, nonce, cipherText)
    }

    override fun close() {
        socket.close()
    }

    private fun nextNonce(counter: Long): ByteArray = ByteArray(12).also { nonce ->
        ByteBuffer.wrap(nonce, 4, 8).order(ByteOrder.BIG_ENDIAN).putLong(counter)
    }
}

private fun crypt(mode: Int, key: ByteArray, nonce: ByteArray, input: ByteArray): ByteArray {
    val transformation = listOf("ChaCha20-Poly1305", "ChaCha20/Poly1305/NoPadding")
    var lastError: Exception? = null
    for (name in transformation) {
        try {
            val cipher = Cipher.getInstance(name)
            cipher.init(mode, SecretKeySpec(key, "ChaCha20"), IvParameterSpec(nonce))
            return cipher.doFinal(input)
        } catch (e: Exception) {
            lastError = e
        }
    }
    throw IllegalStateException("No ChaCha20-Poly1305 cipher available", lastError)
}
