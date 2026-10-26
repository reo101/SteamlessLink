package xyz.reo101.steamlesslink.local

import android.content.Context
import android.os.Build
import android.content.pm.PackageManager
import rikka.shizuku.Shizuku
import xyz.reo101.steamlesslink.protocol.Xbox360Protocol
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class LocalUinputXbox360Output internal constructor(
    private val process: Process,
) : Closeable {
    private val closed = AtomicBoolean(false)
    private val output = process.outputStream.buffered()
    private val readiness = CountDownLatch(1)
    private val ready = AtomicBoolean(false)

    internal fun awaitReady(timeoutMs: Long, onStatus: (String) -> Unit = {}, onFailure: (String) -> Unit = {}) {
        fun drain(stream: java.io.InputStream, name: String) {
            Thread({
                runCatching { stream.bufferedReader().useLines { lines ->
                    lines.forEach { line ->
                        if (line == "steamless-uinput: ready" && !closed.get()) {
                            ready.set(true)
                            readiness.countDown()
                        }
                        onStatus("uinput: $line")
                    }
                } }
            }, name).apply { isDaemon = true }.start()
        }
        drain(process.errorStream, "uinput-helper-stderr")
        drain(process.inputStream, "uinput-helper-stdout")
        Thread({
            val exit = process.waitFor()
            if (!closed.get()) {
                onFailure("Local uinput helper exited with status $exit")
                close()
            }
        }, "uinput-helper-exit").apply { isDaemon = true }.start()
        try {
            if (!readiness.await(timeoutMs, TimeUnit.MILLISECONDS) || !ready.get() || closed.get()) {
                throw IOException("Local uinput helper did not become ready")
            }
        } catch (error: Exception) {
            close()
            throw error
        }
    }

    @Synchronized
    fun sendPacket(packet: ByteArray) {
        check(packet.size == Xbox360Protocol.PACKET_SIZE) { "expected ${Xbox360Protocol.PACKET_SIZE}-byte Xbox packet" }
        check(!closed.get()) { "Local uinput output is closed" }
        output.write(packet)
        output.flush()
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        readiness.countDown()
        // Terminate the reader before closing a pipe whose writer can be blocked.
        runCatching { process.destroy() }
        runCatching { output.close() }
    }

    companion object {
        private const val HELPER_NAME = "steamless-uinput-gamepad"

        fun start(
            context: Context,
            onFailure: (String) -> Unit = {},
            onCreated: (LocalUinputXbox360Output) -> Boolean = { true },
            onStatus: (String) -> Unit,
        ): LocalUinputXbox360Output {
            val helper = extractHelper(context)
            val process = startWithShizuku(helper, onStatus) ?: startWithSu(helper, onStatus)
            val output = LocalUinputXbox360Output(process)
            try {
                if (!onCreated(output)) throw IOException("Session stopped during helper startup")
                output.awaitReady(5000, onStatus, onFailure)
                return output
            } catch (error: Exception) {
                output.close()
                throw error
            }
        }

        private fun extractHelper(context: Context): File {
            val abi = Build.SUPPORTED_ABIS.firstOrNull { abi -> hasHelperAsset(context, abi) }
                ?: error("this APK was built without local uinput support")
            val helper = File(context.filesDir, "helpers/$abi/$HELPER_NAME")
            helper.parentFile?.mkdirs()
            context.assets.open("uinput/$abi/$HELPER_NAME").use { input ->
                helper.outputStream().use { output -> input.copyTo(output) }
            }
            helper.setExecutable(true, true)
            return helper
        }

        private fun hasHelperAsset(context: Context, abi: String): Boolean = runCatching {
            context.assets.open("uinput/$abi/$HELPER_NAME").close()
            true
        }.getOrDefault(false)

        private fun startWithShizuku(helper: File, onStatus: (String) -> Unit): Process? {
            return runCatching {
                if (!Shizuku.pingBinder()) return null
                if (Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) {
                    onStatus("Shizuku is running, but SteamlessLink permission is not granted")
                    return null
                }
                onStatus("Starting local uinput helper through Shizuku")
                newShizukuProcess(arrayOf(helper.absolutePath))
            }.getOrElse { error ->
                onStatus("Shizuku uinput helper launch failed: ${error.message ?: error::class.java.simpleName}")
                null
            }
        }

        private fun newShizukuProcess(command: Array<String>): Process {
            val method = Shizuku::class.java.getDeclaredMethod(
                "newProcess",
                Array<String>::class.java,
                Array<String>::class.java,
                String::class.java,
            )
            method.isAccessible = true
            return method.invoke(null, command, null, null) as Process
        }

        private fun startWithSu(helper: File, onStatus: (String) -> Unit): Process {
            onStatus("Starting local uinput helper through su/root")
            return try {
                Runtime.getRuntime().exec(arrayOf("su", "-c", helper.absolutePath))
            } catch (error: IOException) {
                throw IOException("failed to launch uinput helper with Shizuku or su", error)
            }
        }

    }
}
