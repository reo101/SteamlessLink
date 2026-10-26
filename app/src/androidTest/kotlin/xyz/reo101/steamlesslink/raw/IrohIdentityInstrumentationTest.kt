package xyz.reo101.steamlesslink.raw

import android.os.Bundle
import android.system.Os
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Assert.*
import org.junit.Test

class IrohIdentityInstrumentationTest {
    @Test fun identityIsPrivateAndStableAcrossLoads() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val key = IrohIdentity.secretKey(context)
        val id = IrohIdentity.publicId(context)
        assertArrayEquals(key, IrohIdentity.secretKey(context))
        assertEquals(id, IrohIdentity.publicId(context))
        assertEquals(32, key.size)
        assertEquals(0x180, Os.stat(File(context.noBackupFilesDir, "iroh-identity.key").absolutePath).st_mode and 0x1ff)
        // Public ID only. Used by the emulator harness to configure its proxy.
        instrumentation.sendStatus(0, Bundle().apply { putString("irohControllerId", id) })
    }
}
