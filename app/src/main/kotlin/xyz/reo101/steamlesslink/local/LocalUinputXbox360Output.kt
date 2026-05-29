package xyz.reo101.steamlesslink.local

import android.content.Context
import android.os.Build
import android.content.pm.PackageManager
import rikka.shizuku.Shizuku
import xyz.reo101.steamlesslink.viiper.Xbox360State
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean

class LocalUinputXbox360Output private constructor(
    private val process: Process,
    private val onStatus: (String) -> Unit,
) : Closeable {
    private val closed = AtomicBoolean(false)
    private val output = process.outputStream.buffered()

    fun send(state: Xbox360State) {
        sendPacket(state.toViiperPacket())
    }

    @Synchronized
    fun sendPacket(packet: ByteArray) {
        check(packet.size == Xbox360State.PACKET_SIZE) { "expected ${Xbox360State.PACKET_SIZE}-byte Xbox packet" }
        if (closed.get()) return
        output.write(packet)
        output.flush()
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        runCatching { output.close() }
        runCatching { process.destroy() }
    }

    companion object {
        private const val HELPER_NAME = "steamless-uinput-gamepad"

        fun start(context: Context, onStatus: (String) -> Unit): LocalUinputXbox360Output {
            val helper = extractHelper(context)
            val process = startWithShizuku(helper, onStatus) ?: startWithSu(helper, onStatus)
            drainProcessLogs(process, onStatus)
            return LocalUinputXbox360Output(process, onStatus)
        }

        private fun extractHelper(context: Context): File {
            val abi = Build.SUPPORTED_ABIS.firstOrNull { abi -> hasHelperAsset(context, abi) }
                ?: error("uinput helper asset not found; rebuild the APK with -Psteamless.buildUinputHelper=true")
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

        private fun drainProcessLogs(process: Process, onStatus: (String) -> Unit) {
            Thread({
                process.errorStream.bufferedReader().useLines { lines ->
                    lines.forEach { line -> onStatus("uinput: $line") }
                }
            }, "uinput-helper-stderr").apply { isDaemon = true }.start()
            Thread({
                process.inputStream.bufferedReader().useLines { lines ->
                    lines.forEach { line -> onStatus("uinput: $line") }
                }
            }, "uinput-helper-stdout").apply { isDaemon = true }.start()
        }
    }
}
