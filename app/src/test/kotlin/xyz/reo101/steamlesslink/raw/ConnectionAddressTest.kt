package xyz.reo101.steamlesslink.raw

import org.junit.Assert.assertEquals
import org.junit.Test

class ConnectionAddressTest {
    @Test fun preservesIpv6AndExistingHostForms() {
        for ((input, expected) in mapOf(
            "::1" to "::1", "2001:db8::1" to "2001:db8::1",
            "[2001:db8::1]:3244" to "2001:db8::1",
            "http://[::1]:3244/path" to "::1", "https://host:3244/path" to "host",
            " 127.0.0.1 " to "127.0.0.1", "host:3244" to "host",
        )) assertEquals(input, expected, normalizeHost(input))
    }
}
