package xyz.reo101.steamlesslink.ble

import android.bluetooth.BluetoothGatt
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test

/** Exercise the descriptor callback's actual transition without a physical controller. */
class BleReadinessInstrumentationTest {
    @Test fun failedSubscriptionIsTerminalAndLateSuccessCannotMakeItReady() {
        val failures = mutableListOf<String>()
        BleTritonTransport(InstrumentationRegistry.getInstrumentation().targetContext, { _, _ -> }, {},
            enableLizardModeRefresh = false, onFailure = failures::add).use { transport ->
            transport.completeNotificationSetup(BluetoothGatt.GATT_FAILURE)
            assertFalse(transport.awaitReady(0))
            transport.completeNotificationSetup(BluetoothGatt.GATT_SUCCESS)
            assertFalse(transport.awaitReady(0))
            assertEquals(1, failures.size)
        }
    }

    @Test fun successfulSubscriptionBecomesUnreadyOnClose() {
        val transport = BleTritonTransport(InstrumentationRegistry.getInstrumentation().targetContext,
            { _, _ -> }, {}, enableLizardModeRefresh = false)
        try {
            transport.completeNotificationSetup(BluetoothGatt.GATT_SUCCESS)
            assertTrue(transport.awaitReady(0))
        } finally { transport.close() }
        assertFalse(transport.awaitReady(0))
    }
}
