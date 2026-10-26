package xyz.reo101.steamlesslink.testing

import android.content.Intent
import android.os.Bundle
import android.view.InputDevice
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import xyz.reo101.steamlesslink.bridge.ControllerBridgeService

class CaptureHardwareInstrumentationTest {
    @Test fun physicalCaptureAndDisconnectCloseLocalOutput() {
        val arguments = InstrumentationRegistry.getArguments()
        assumeTrue("Requires a real controller and authorized local output", arguments.getString("captureHardware") == "true" &&
            arguments.getString("localHardware") == "true")
        val transport = arguments.getString("transport") ?: "ble"
        require(transport in listOf("ble", "usb"))
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val activity = instrumentation.startActivitySync(Intent(context, ControllerTestActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as ControllerTestActivity
        fun gamepadPresent(): Boolean = InputDevice.getDeviceIds().any {
            InputDevice.getDevice(it)?.name == "SteamlessLink Virtual Xbox 360 Controller"
        }
        try {
            instrumentation.runOnMainSync {
                context.startForegroundService(Intent(context, ControllerBridgeService::class.java)
                    .putExtra(ControllerBridgeService.EXTRA_TRANSPORT, transport)
                    .putExtra(ControllerBridgeService.EXTRA_MODE, ControllerBridgeService.MODE_LOCAL_UINPUT_XBOX360))
            }
            val readyDeadline = System.nanoTime() + 35_000_000_000
            while (System.nanoTime() < readyDeadline &&
                ControllerTestFeed.latest?.disposition?.startsWith("Written to local helper") != true &&
                !ControllerTestFeed.status.startsWith("Bridge stopped:")) Thread.sleep(50)
            assertTrue(ControllerTestFeed.status, ControllerTestFeed.latest?.disposition?.startsWith("Written to local helper") == true)
            assertTrue("Virtual gamepad must exist during capture", gamepadPresent())
            instrumentation.sendStatus(0, Bundle().apply { putString("hardwareReady", "$transport: power off or unplug controller now") })
            val disconnectDeadline = System.nanoTime() + 90_000_000_000
            while (System.nanoTime() < disconnectDeadline &&
                (!ControllerTestFeed.status.startsWith("Bridge stopped:") || gamepadPresent())) Thread.sleep(50)
            assertTrue(ControllerTestFeed.status, ControllerTestFeed.status.startsWith("Bridge stopped:"))
            assertNull("Closed capture must not expose a stale sample", ControllerTestFeed.latest)
            assertFalse("Capture loss must remove local output", gamepadPresent())
        } finally {
            instrumentation.runOnMainSync {
                context.stopService(Intent(context, ControllerBridgeService::class.java))
                activity.finish()
            }
        }
    }
}
