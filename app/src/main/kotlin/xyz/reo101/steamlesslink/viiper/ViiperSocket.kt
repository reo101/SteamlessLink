package xyz.reo101.steamlesslink.viiper

import java.net.Socket
import javax.net.ssl.SSLSocketFactory

internal fun openViiperSocket(host: String, port: Int, readTimeoutMs: Int): Socket {
    val socket = if (port == 443) {
        (SSLSocketFactory.getDefault().createSocket(host, port) as Socket)
    } else {
        Socket(host, port)
    }
    socket.soTimeout = readTimeoutMs
    return socket
}
