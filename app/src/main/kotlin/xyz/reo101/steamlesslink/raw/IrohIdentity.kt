package xyz.reo101.steamlesslink.raw

import android.content.Context
import android.system.Os
import android.util.AtomicFile
import computer.iroh.IrohAndroid
import computer.iroh.SecretKey
import java.io.File
import java.security.SecureRandom

/** One controller identity per installation. Never included in Android backups. */
internal object IrohIdentity {
    @Synchronized
    fun secretKey(context: Context): ByteArray {
        val file = AtomicFile(File(context.noBackupFilesDir, "iroh-identity.key"))
        val saved = try { file.readFully() } catch (_: java.io.FileNotFoundException) { null }
        if (saved != null) {
            require(saved.size == 32) { "Invalid saved Iroh identity; refusing to replace it" }
            return saved
        }
        val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val output = file.startWrite()
        try {
            output.write(bytes)
            file.finishWrite(output)
            Os.chmod(file.baseFile.absolutePath, 0x180) // 0600
        } catch (error: Exception) {
            file.failWrite(output)
            throw error
        }
        return bytes
    }

    fun publicId(context: Context): String {
        IrohAndroid.installAndroidContext(context.applicationContext)
        return SecretKey.fromBytes(secretKey(context)).use { key ->
            key.`public`().use { it.toString() }
        }
    }
}
