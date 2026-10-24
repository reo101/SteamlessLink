package xyz.reo101.steamlesslink.testing

import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import xyz.reo101.steamlesslink.triton.TritonReportParser

class ControllerTestFeedTest {
    @After fun reset() { ControllerTestFeed.observing = false; ControllerTestFeed.stop() }

    @Test fun aPreviousSessionCannotPublishIntoItsSuccessor() {
        ControllerTestFeed.observing = true
        val previous = ControllerTestFeed.begin("previous")
        val current = ControllerTestFeed.begin("current")
        val state = TritonReportParser.parse(ByteArray(18).apply { this[0] = 0x45 })!!
        ControllerTestFeed.record(state, 1, emptyList(), "stale", 0, previous)
        assertNull(ControllerTestFeed.latest)
        ControllerTestFeed.record(state, 2, emptyList(), "current", 0, current)
        assertEquals(2L, ControllerTestFeed.latest!!.count)
    }

    @Test fun snapshotsAreBoundedThrottledAndDoNotModifyPackets() {
        ControllerTestFeed.begin("fake / raw")
        val report = ByteArray(18).apply { this[0] = 0x45 }
        val state = TritonReportParser.parse(report)!!
        ControllerTestFeed.record(state, 1, emptyList(), "not observed", 0)
        assertNull(ControllerTestFeed.latest)
        ControllerTestFeed.observing = true
        val output = byteArrayOf(1, 2, 3)
        ControllerTestFeed.record(state, 2, listOf(0 to output), "queued, not delivered", 0)
        output[0] = 99
        assertArrayEquals(byteArrayOf(1, 2, 3), ControllerTestFeed.latest!!.output[0].second)
        ControllerTestFeed.record(state.copy(buttons = 1u), 3, emptyList(), "brief button", 10)
        assertEquals(2L, ControllerTestFeed.latest!!.count)
        ControllerTestFeed.record(state, 4, emptyList(), "released", 100)
        assertEquals(4L, ControllerTestFeed.latest!!.count)
        assertEquals(1u, ControllerTestFeed.latest!!.seenButtons)
        assertEquals(0u, ControllerTestFeed.latest!!.state.buttons)
        ControllerTestFeed.stop()
        assertNull(ControllerTestFeed.latest)
        assertEquals("Stopped", ControllerTestFeed.status)
    }
}
