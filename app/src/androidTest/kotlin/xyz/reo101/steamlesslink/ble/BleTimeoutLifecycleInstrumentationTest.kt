package xyz.reo101.steamlesslink.ble

import android.bluetooth.BluetoothGatt
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test

class BleTimeoutLifecycleInstrumentationTest {
    @Test fun inFlightTimeoutClosesCaptureAndRejectsLateSuccess() {
        for (write in listOf(true, false)) {
            val failures = mutableListOf<String>()
            BleTritonTransport(InstrumentationRegistry.getInstrumentation().targetContext,
                { _, _ -> }, {}, enableLizardModeRefresh = false, onFailure = failures::add).use { transport ->
                transport.completeNotificationSetup(BluetoothGatt.GATT_SUCCESS)
                assertTrue(transport.awaitReady(0))
                if (write) {
                    val pending = PendingWrite(BleTritonTransport.REPORT_CHARACTERISTIC)
                    assertEquals(BluetoothGatt.GATT_FAILURE, transport.awaitWrite(pending, 0))
                    assertFalse(pending.complete(pending.expectsUuid, BluetoothGatt.GATT_SUCCESS))
                } else {
                    val pending = PendingRead(BleTritonTransport.REPORT_CHARACTERISTIC)
                    assertNull(transport.awaitRead(pending, 0))
                    assertFalse(pending.complete(pending.expectsUuid, BluetoothGatt.GATT_SUCCESS, byteArrayOf(1)))
                }
                assertEquals(1, failures.size)
                transport.completeNotificationSetup(BluetoothGatt.GATT_SUCCESS)
                assertFalse(transport.awaitReady(0))
            }
        }
    }
}
