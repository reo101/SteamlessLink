package xyz.reo101.steamlesslink.viiper

import org.json.JSONObject
import java.io.Closeable

interface ViiperClient {
    fun ping(): JSONObject
    fun createXbox360Device(): ViiperDeviceRef
    fun openDeviceStream(ref: ViiperDeviceRef): ViiperDeviceStream
}

data class ViiperDeviceRef(val busId: Int, val devId: String)

interface ViiperDeviceStream : Closeable {
    fun send(state: Xbox360State)
}

fun viiperClient(host: String, port: Int, key: String?): ViiperClient =
    if (key.isNullOrBlank()) {
        ViiperPlaintextClient(host, port)
    } else {
        ViiperAuthenticatedClient(host, port, key.trim())
    }
