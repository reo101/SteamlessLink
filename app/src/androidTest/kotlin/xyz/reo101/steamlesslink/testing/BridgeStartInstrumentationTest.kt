package xyz.reo101.steamlesslink.testing

import android.content.Intent
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import androidx.test.platform.app.InstrumentationRegistry
import java.io.DataInputStream
import java.net.ServerSocket
import java.net.SocketTimeoutException
import org.junit.Assert.*
import org.junit.Test
import xyz.reo101.steamlesslink.MainActivity
import xyz.reo101.steamlesslink.bridge.ControllerBridgeService

class BridgeStartInstrumentationTest {
    private fun descendants(view: View): Sequence<View> = sequence {
        yield(view)
        if (view is ViewGroup) for (index in 0 until view.childCount) yieldAll(descendants(view.getChildAt(index)))
    }

    @Test fun exportedActivityDoesNotStartAnUnconfirmedRequest() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        context.stopService(Intent(context, ControllerBridgeService::class.java))
        ServerSocket(0).use { server ->
            server.soTimeout = 500
            val activity = instrumentation.startActivitySync(Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(MainActivity.EXTRA_AUTOSTART, true)
                .putExtra(ControllerBridgeService.EXTRA_HOST, "127.0.0.1")
                .putExtra(ControllerBridgeService.EXTRA_PORT, server.localPort)
                .putExtra(ControllerBridgeService.EXTRA_MODE, ControllerBridgeService.MODE_UHID_RAW)
                .putExtra(ControllerBridgeService.EXTRA_TRANSPORT, "fake")) as MainActivity
            try {
                assertThrows(SocketTimeoutException::class.java) { server.accept().close() }
                assertNull(ControllerTestFeed.latest)
            } finally {
                instrumentation.runOnMainSync { activity.finish() }
            }
        }
    }

    @Test fun stopClosesPendingTicketRequestWithoutStartingBridge() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val activity = instrumentation.startActivitySync(Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        try {
            ServerSocket(0).use { server ->
                server.soTimeout = 3000
                instrumentation.runOnMainSync {
                    val views = descendants(activity.window.decorView).toList()
                    val fields = views.filterIsInstance<EditText>()
                    fields[0].setText("127.0.0.1")
                    fields[1].setText(server.localPort.toString())
                    views.filterIsInstance<Button>().first { it.text == "Fetch Iroh ticket & Start" }.performClick()
                }
                server.accept().use { socket ->
                    socket.soTimeout = 3000
                    val input = DataInputStream(socket.getInputStream())
                    assertEquals(5, input.readUnsignedByte())
                    assertEquals(0, input.readUnsignedShort())
                    instrumentation.runOnMainSync {
                        descendants(activity.window.decorView).filterIsInstance<Button>().first { it.text == "Stop" }.performClick()
                    }
                    assertEquals(-1, input.read())
                }
            }
        } finally {
            instrumentation.runOnMainSync { activity.finish() }
        }
    }
}
