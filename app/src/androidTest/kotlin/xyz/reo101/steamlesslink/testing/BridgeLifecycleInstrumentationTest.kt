package xyz.reo101.steamlesslink.testing

import android.app.KeyguardManager
import android.content.Intent
import androidx.test.platform.app.InstrumentationRegistry
import java.io.DataInputStream
import java.io.EOFException
import java.net.ServerSocket
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Assume.assumeFalse
import org.junit.Test
import xyz.reo101.steamlesslink.bridge.ControllerBridgeService
import xyz.reo101.steamlesslink.protocol.RawProtocol

class BridgeLifecycleInstrumentationTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    private var activity: ControllerTestActivity? = null

    @Before fun openObserver() {
        assumeFalse("Unlock the device", context.getSystemService(KeyguardManager::class.java).isKeyguardLocked)
        activity = instrumentation.startActivitySync(Intent(context, ControllerTestActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as ControllerTestActivity
    }

    @After fun stopSession() {
        instrumentation.runOnMainSync {
            context.stopService(Intent(context, ControllerBridgeService::class.java))
            activity?.finish()
        }
        instrumentation.waitForIdleSync()
    }

    private fun start(mode: String, port: Int = 0, reportId: Int = 0x45, failureAfter: Int = 0) {
        instrumentation.runOnMainSync {
            context.startForegroundService(Intent(context, ControllerBridgeService::class.java)
                .putExtra(ControllerBridgeService.EXTRA_TRANSPORT, "fake")
                .putExtra(ControllerBridgeService.EXTRA_MODE, mode)
                .putExtra(ControllerBridgeService.EXTRA_HOST, "127.0.0.1")
                .putExtra(ControllerBridgeService.EXTRA_PORT, port)
                .putExtra(ControllerBridgeService.EXTRA_FAKE_REPORT_ID, reportId)
                .putExtra(ControllerBridgeService.EXTRA_FAKE_FAILURE_AFTER_REPORTS, failureAfter))
        }
    }

    @Test fun unknownRawReportsAreForwardedAndCaptureLossClosesOutput() {
        ServerSocket(0).use { server ->
            server.soTimeout = 5000
            start(ControllerBridgeService.MODE_UHID_RAW, server.localPort, reportId = 0x43, failureAfter = 500)
            server.accept().use { socket ->
                socket.soTimeout = 5000
                val input = DataInputStream(socket.getInputStream())
                assertEquals(RawProtocol.FRAME_INPUT, input.readUnsignedByte())
                val report = ByteArray(input.readUnsignedShort()).also(input::readFully)
                assertEquals(0x43, report[0].toInt())
                assertTrue(report.size >= 18)
                // Capture fails after two seconds. Output must end, not hold its last state.
                try {
                    while (true) {
                        input.readUnsignedByte()
                        input.readFully(ByteArray(input.readUnsignedShort()))
                    }
                } catch (_: EOFException) { }
            }
            val deadline = System.nanoTime() + 3_000_000_000
            while (!ControllerTestFeed.status.startsWith("Bridge stopped:") && System.nanoTime() < deadline) Thread.sleep(20)
            assertTrue(ControllerTestFeed.status, ControllerTestFeed.status.startsWith("Bridge stopped:"))
            assertNull(ControllerTestFeed.latest)
        }
    }

    @Test fun replacingABlockedHandshakeDoesNotBlockTheMainThreadOrStopItsSuccessor() {
        ServerSocket(0).use { server ->
            server.soTimeout = 5000
            start(ControllerBridgeService.MODE_UHID_EXTENDED_GAMEPAD, server.localPort)
            server.accept().use { socket ->
                socket.soTimeout = 3000
                val input = DataInputStream(socket.getInputStream())
                assertEquals(RawProtocol.FRAME_DEVICE_BUNDLE, input.readUnsignedByte())
                input.readFully(ByteArray(input.readUnsignedShort()))
                // Deliberately withhold the bundle acknowledgement.
                val before = System.nanoTime()
                start(ControllerBridgeService.MODE_CAPTURE_TEST)
                assertTrue("Starting a successor must not wait for network shutdown", System.nanoTime() - before < 2_000_000_000)
                assertEquals(-1, input.read())
                val deadline = System.nanoTime() + 5_000_000_000
                while (ControllerTestFeed.latest == null && System.nanoTime() < deadline) Thread.sleep(20)
                assertEquals("Capture only; previews are NOT sent", ControllerTestFeed.latest?.disposition)
                assertTrue(ControllerTestFeed.session.contains(ControllerBridgeService.MODE_CAPTURE_TEST))
            }
        }
    }
}
