package xyz.reo101.steamlesslink.viiper

import java.net.InetSocketAddress
import java.net.Socket
import javax.net.ssl.SSLSocketFactory

internal fun openViiperSocket(host: String, port: Int, connectTimeoutMs: Int, readTimeoutMs: Int): Socket {
    val socket = if (port == 443) {
        (SSLSocketFactory.getDefault().createSocket() as Socket)
    } else {
        Socket()
    }
    socket.connect(InetSocketAddress(host, port), connectTimeoutMs)
    socket.soTimeout = readTimeoutMs
    return socket
}
