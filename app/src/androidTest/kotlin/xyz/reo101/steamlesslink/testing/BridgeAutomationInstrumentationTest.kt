package xyz.reo101.steamlesslink.testing

import android.content.Intent
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import xyz.reo101.steamlesslink.bridge.ControllerBridgeService
import xyz.reo101.steamlesslink.raw.fetchIrohTicket

/** ADB-authorized automation lives in the test APK, never in an exported app entry point. */
class BridgeAutomationInstrumentationTest {
    @Test fun forwardConfiguredController() {
        val arguments = InstrumentationRegistry.getArguments()
        assumeTrue(arguments.getString("remoteBridge") == "true")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val host = arguments.getString("host") ?: "127.0.0.1"
        val port = arguments.getString("port")!!.toInt()
        val mode = arguments.getString("mode") ?: ControllerBridgeService.MODE_UHID_RAW
        val duration = (arguments.getString("durationSeconds") ?: "10").toLong().coerceIn(1, 300)
        val ticket = if (mode == ControllerBridgeService.MODE_UHID_RAW_IROH) fetchIrohTicket(host, port) else ""
        val activity = instrumentation.startActivitySync(Intent(context, ControllerTestActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as ControllerTestActivity
        try {
            instrumentation.runOnMainSync {
                context.startForegroundService(Intent(context, ControllerBridgeService::class.java)
                    .putExtra(ControllerBridgeService.EXTRA_HOST, host)
                    .putExtra(ControllerBridgeService.EXTRA_PORT, port)
                    .putExtra(ControllerBridgeService.EXTRA_MODE, mode)
                    .putExtra(ControllerBridgeService.EXTRA_IROH_TICKET, ticket)
                    .putExtra(ControllerBridgeService.EXTRA_TRANSPORT, "fake"))
            }
            var captured = false
            val deadline = System.nanoTime() + duration * 1_000_000_000
            while (System.nanoTime() < deadline) {
                captured = captured || (ControllerTestFeed.latest?.count ?: 0) >= 10
                Thread.sleep(20)
            }
            // The host harness verifies delivery. Its short connection can finish
            // between diagnostic publications, so this screen only verifies capture.
            assertTrue("No fake capture observed", captured)
        } finally {
            instrumentation.runOnMainSync {
                context.stopService(Intent(context, ControllerBridgeService::class.java))
                activity.finish()
            }
        }
    }
}
