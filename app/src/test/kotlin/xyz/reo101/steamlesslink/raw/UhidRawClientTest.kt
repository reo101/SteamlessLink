package xyz.reo101.steamlesslink.raw

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import org.junit.Assert.assertTrue
import org.junit.Test

class UhidRawClientTest {
    @Test
    fun closesWhenTheRemoteStreamEnds() {
        val client = UhidRawClient(
            connection = RawUhidConnection(ByteArrayInputStream(ByteArray(0)), ByteArrayOutputStream()) {},
            onStatus = {},
            onGetReport = { _, _, _ -> null },
            onSetReport = { _, _, _, _ -> false },
            onOutputReport = { _, _ -> false },
        )

        assertTrue(client.awaitClosed(1_000))
    }
}
