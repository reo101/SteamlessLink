package xyz.reo101.steamlesslink.usb

import android.content.BroadcastReceiver
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import xyz.reo101.steamlesslink.triton.TritonReportParser

/** Opt in with `am instrument -e usbHardware true`; requires a permitted wired controller. */
class UsbTritonTransportInstrumentationTest {
    private fun controller(): Pair<Context, UsbDevice> {
        assumeTrue(InstrumentationRegistry.getArguments().getString("usbHardware") == "true")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val manager = context.getSystemService(Context.USB_SERVICE) as UsbManager
        val device = manager.deviceList.values.firstOrNull(UsbTritonTransport::isSteamController)
        assertNotNull("Connect a supported USB controller", device)
        assertTrue("Grant SteamlessLink USB permission first", manager.hasPermission(device!!))
        return context to device
    }

    @Test
    fun permissionReceiverSurvivesRegistrationAndHandlesDenial() {
        val (base, device) = controller()
        var registered: BroadcastReceiver? = null
        var registrations = 0
        var unregistrations = 0
        val context = object : ContextWrapper(base) {
            override fun registerReceiver(receiver: BroadcastReceiver?, filter: IntentFilter?, flags: Int): Intent? {
                assertNotNull("USB permission receiver must not be cleared before registration", receiver)
                registered = receiver
                registrations++
                return null
            }

            override fun registerReceiver(receiver: BroadcastReceiver?, filter: IntentFilter?): Intent? =
                registerReceiver(receiver, filter, 0)

            override fun unregisterReceiver(receiver: BroadcastReceiver) {
                assertTrue("Only unregister the previously registered receiver", receiver === registered)
                registered = null
                unregistrations++
            }
        }
        val statuses = mutableListOf<String>()
        UsbTritonTransport(context, { _, _ -> }, statuses::add).use { transport ->
            val request = UsbTritonTransport::class.java.getDeclaredMethod("requestPermission", UsbDevice::class.java)
                .apply { isAccessible = true }
            // Exercise the permission branch even though this device is already permitted.
            // The wrapper captures registration; it does not attach a real broadcast receiver.
            request.invoke(transport, device)
            assertEquals(1, registrations)
            assertEquals(0, unregistrations)
            request.invoke(transport, device)
            assertEquals(2, registrations)
            assertEquals(1, unregistrations)
            registered!!.onReceive(context, Intent("${context.packageName}.USB_PERMISSION")
                .putExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false))
            assertNull(registered)
            assertEquals(2, unregistrations)
            assertTrue(statuses.contains("USB permission denied or unsupported device"))
        }
    }

    @Test
    fun capturesUsbStateAndProxiesFeatureAndOutputReports() {
        val (context, device) = controller()
        val stateReceived = CountDownLatch(1)
        val statuses = mutableListOf<String>()
        val transport = UsbTritonTransport(
            context,
            onReport = { report, length ->
                if (TritonReportParser.parse(report, length)?.reportId == 0x42) stateReceived.countDown()
            },
            onStatus = { synchronized(statuses) { statuses.add(it) } },
            enableLizardModeRefresh = false,
        )
        transport.use {
            it.start()
            assertTrue(statuses.toString(), it.awaitReady(5000))
            assertTrue("No physical USB state report", stateReceived.await(5, TimeUnit.SECONDS))
            val info = it.deviceInfo!!
            assertEquals(3, info[0].toInt()) // BUS_USB
            assertEquals(device.vendorId, (info[4].toInt() and 0xff) or ((info[5].toInt() and 0xff) shl 8))
            assertEquals(device.productId, (info[6].toInt() and 0xff) or ((info[7].toInt() and 0xff) shl 8))
            // Read-only string-attribute query, not a settings/calibration/firmware command.
            val query = ByteArray(64).also { report ->
                report[0] = 1
                report[1] = 0xae.toByte()
                report[2] = 1
                report[3] = 1
            }
            assertTrue("USB SET_REPORT failed", it.writeHidReport(1, 0, query))
            val response = it.readHidReport(1, 0)
            assertNotNull("USB GET_REPORT failed", response)
            assertTrue(response!!.size in 4..65)
            assertEquals(1, response[0].toInt())
            assertEquals(0xae, response[1].toInt() and 0xff)
            // Zero rumble: exercise output routing without asking the user to feel a pulse.
            val output = ByteArray(10).also { report -> report[0] = 0x80.toByte() }
            assertTrue("USB interrupt output failed", it.writeHidReport(0x80, 1, output))
            assertFalse(it.writeHidReport(1, 2, query)) // Input reports cannot be written.
            assertFalse(it.writeHidReport(2, 0, query)) // Mismatched numbered report.
        }
        assertFalse(transport.awaitReady(0))
        assertNull(transport.readHidReport(1, 0))
    }
}
