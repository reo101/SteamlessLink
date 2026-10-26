package xyz.reo101.steamlesslink.testing

import android.app.KeyguardManager
import android.content.Intent
import java.net.ServerSocket
import java.io.DataInputStream
import java.io.DataOutputStream
import org.junit.Assume.assumeFalse
import xyz.reo101.steamlesslink.protocol.RawProtocol
import xyz.reo101.steamlesslink.protocol.GenericGamepadProtocol
import android.view.KeyEvent
import android.view.InputDevice
import org.junit.Assume.assumeTrue
import xyz.reo101.steamlesslink.local.LocalUinputXbox360Output
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import xyz.reo101.steamlesslink.bridge.ControllerBridgeService
import xyz.reo101.steamlesslink.local.LocalMappingSettings
import xyz.reo101.steamlesslink.protocol.NativeProtocol
import xyz.reo101.steamlesslink.util.i16Le
import xyz.reo101.steamlesslink.util.u32Le

class ControllerTestingInstrumentationTest {
    @Test fun localMappingRunsThroughTheBundledNativeLibrary() {
        val raw = ByteArray(46).apply {
            this[0] = 0x45
            this[4] = 0x22 // L4 and right-pad touch
            this[24] = 0x10
            this[40] = 0x5a // pitch 90 counts → 1000 stick units at 180 deg/s
        }
        val baseline = ByteArray(20)
        val local = ByteArray(20)
        assertTrue(NativeProtocol.tryMapTritonToXbox360(raw, raw.size, baseline))
        assertTrue(NativeProtocol.tryMapTritonToLocalXbox360(raw, raw.size, local, LocalMappingSettings()))
        assertArrayEquals(baseline, local)
        assertTrue(NativeProtocol.tryMapTritonToLocalXbox360(raw, raw.size, local,
            LocalMappingSettings(l4 = 0x1000, rightPadStick = true, touchGyro = true)))
        assertEquals(0x1000u, local.u32Le(0))
        assertEquals(16.toShort(), local.i16Le(10))
        assertEquals(1000.toShort(), local.i16Le(12))
        assertEquals(0.toShort(), baseline.i16Le(12))
    }

    @Test fun localHelperDeliversMappedGripAsAndroidGamepadButton() {
        assumeTrue("Opt in with -e localHardware true; requires authorized Shizuku/root",
            InstrumentationRegistry.getArguments().getString("localHardware") == "true")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assumeFalse("Unlock the phone for foreground UI tests", context.getSystemService(KeyguardManager::class.java).isKeyguardLocked)
        val activity = instrumentation.startActivitySync(Intent(context, ControllerTestActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as ControllerTestActivity
        try {
            LocalUinputXbox360Output.start(context) {}.use { output ->
                val deadline = System.nanoTime() + 5_000_000_000
                while (InputDevice.getDeviceIds().none { InputDevice.getDevice(it)?.name == "SteamlessLink Virtual Xbox 360 Controller" } &&
                    System.nanoTime() < deadline) Thread.sleep(20)
                assertTrue(InputDevice.getDeviceIds().any { InputDevice.getDevice(it)?.name == "SteamlessLink Virtual Xbox 360 Controller" })
                val raw = ByteArray(46).apply { this[0] = 0x45; this[4] = 2 } // L4
                val packet = ByteArray(20)
                assertTrue(NativeProtocol.tryMapTritonToLocalXbox360(raw, raw.size, packet, LocalMappingSettings(l4 = 0x1000)))
                output.sendPacket(packet)
                Thread.sleep(100)
                output.sendPacket(ByteArray(20))
                var history = emptyList<String>()
                val receiptDeadline = System.nanoTime() + 3_000_000_000
                while (System.nanoTime() < receiptDeadline) {
                    instrumentation.runOnMainSync { history = activity.receivedKeyHistory() }
                    if (history.any { it.contains("KEYCODE_BUTTON_A UP") }) break
                    Thread.sleep(20)
                }
                assertTrue("Android must receive mapped A press: $history", history.any { it.contains("SteamlessLink Virtual Xbox 360 Controller") && it.contains("KEYCODE_BUTTON_A DOWN") })
                assertTrue("Android must receive A release: $history", history.any { it.contains("KEYCODE_BUTTON_A UP") })
            }
        } finally {
            instrumentation.runOnMainSync { activity.finish() }
            instrumentation.waitForIdleSync()
        }
    }

    @Test fun remoteRawAndTranslatedSamplesMatchTheirActualOutgoingReports() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assumeFalse("Unlock the phone for foreground UI tests", context.getSystemService(KeyguardManager::class.java).isKeyguardLocked)
        val activity = instrumentation.startActivitySync(Intent(context, ControllerTestActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as ControllerTestActivity
        try {
            for (mode in listOf(ControllerBridgeService.MODE_UHID_RAW, ControllerBridgeService.MODE_UHID_GENERIC_GAMEPAD,
                ControllerBridgeService.MODE_UHID_EXTENDED_GAMEPAD)) {
                ServerSocket(0).use { server ->
                    server.soTimeout = 5000
                    instrumentation.runOnMainSync {
                        context.startForegroundService(Intent(context, ControllerBridgeService::class.java)
                            .putExtra(ControllerBridgeService.EXTRA_TRANSPORT, "fake")
                            .putExtra(ControllerBridgeService.EXTRA_MODE, mode)
                            .putExtra(ControllerBridgeService.EXTRA_HOST, "127.0.0.1")
                            .putExtra(ControllerBridgeService.EXTRA_PORT, server.localPort))
                    }
                    server.accept().use { socket ->
                        socket.soTimeout = 5000
                        val input = DataInputStream(socket.getInputStream())
                        var type = input.readUnsignedByte()
                        var payload = ByteArray(input.readUnsignedShort()).also(input::readFully)
                        if (type == RawProtocol.FRAME_DEVICE_BUNDLE) {
                            val output = DataOutputStream(socket.getOutputStream())
                            output.writeByte(RawProtocol.FRAME_DEVICE_BUNDLE_READY)
                            output.writeShort(1)
                            output.writeByte(4)
                            output.flush()
                        }
                        if (type == RawProtocol.FRAME_DEVICE_INFO || type == RawProtocol.FRAME_DEVICE_BUNDLE) {
                            type = input.readUnsignedByte()
                            payload = ByteArray(input.readUnsignedShort()).also(input::readFully)
                        }
                        assertTrue("Host socket must receive input payload", payload.isNotEmpty())
                        val deadline = System.nanoTime() + 5_000_000_000
                        while (ControllerTestFeed.latest?.output?.isNotEmpty() != true && System.nanoTime() < deadline) Thread.sleep(20)
                        val sample = ControllerTestFeed.latest!!
                        assertTrue(sample.disposition.startsWith("Accepted by remote send queue"))
                        when (mode) {
                            ControllerBridgeService.MODE_UHID_RAW -> {
                                assertEquals(0x45, payload[0].toInt())
                                assertArrayEquals(sample.state.rawReport, sample.output.single().second)
                            }
                            ControllerBridgeService.MODE_UHID_GENERIC_GAMEPAD -> {
                                val expected = ByteArray(GenericGamepadProtocol.INPUT_REPORT_SIZE)
                                assertTrue(NativeProtocol.tryMapTritonToGenericGamepad(sample.state.rawReport, sample.state.rawReport.size, expected))
                                assertArrayEquals(expected, sample.output.single().second)
                                assertArrayEquals(expected, payload)
                            }
                            else -> {
                                // Host has not enabled sensors; capture must show only actual slots 0/1/2.
                                assertEquals(listOf(0, 1, 2), sample.output.map { it.first })
                            }
                        }
                    }
                }
                instrumentation.runOnMainSync { context.stopService(Intent(context, ControllerBridgeService::class.java)) }
                instrumentation.waitForIdleSync()
            }
        } finally {
            instrumentation.runOnMainSync {
                context.stopService(Intent(context, ControllerBridgeService::class.java))
                activity.finish()
            }
            instrumentation.waitForIdleSync()
        }
    }

    @Test fun testingScreenObservesFakeCaptureWithoutCreatingAnOutputDevice() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assumeFalse("Unlock the phone for foreground UI tests", context.getSystemService(KeyguardManager::class.java).isKeyguardLocked)
        val activity = instrumentation.startActivitySync(Intent(context, ControllerTestActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as ControllerTestActivity
        try {
            instrumentation.runOnMainSync {
                context.startForegroundService(Intent(context, ControllerBridgeService::class.java)
                    .putExtra(ControllerBridgeService.EXTRA_TRANSPORT, "fake")
                    .putExtra(ControllerBridgeService.EXTRA_MODE, ControllerBridgeService.MODE_CAPTURE_TEST))
            }
            val deadline = System.nanoTime() + 5_000_000_000
            while (ControllerTestFeed.latest == null && System.nanoTime() < deadline) Thread.sleep(20)
            val snapshot = ControllerTestFeed.latest
            assertNotNull("Fake capture must reach the testing feed", snapshot)
            assertTrue(snapshot!!.output.isEmpty())
            assertEquals("Capture only; previews are NOT sent", snapshot.disposition)
            assertEquals(0x45, snapshot.state.reportId)
            // An ordinary navigation event must not be classified as a gamepad event.
            instrumentation.runOnMainSync { activity.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_UNKNOWN)) }
        } finally {
            instrumentation.runOnMainSync {
                context.stopService(Intent(context, ControllerBridgeService::class.java))
                activity.finish()
            }
            instrumentation.waitForIdleSync()
        }
        // Activity transitions can complete after the main queue first becomes idle.
        val pauseDeadline = System.nanoTime() + 3_000_000_000
        while (ControllerTestFeed.observing && System.nanoTime() < pauseDeadline) Thread.sleep(20)
        assertFalse(ControllerTestFeed.observing)
    }
}
