package xyz.reo101.steamlesslink.raw

/** Accept the existing host/URL input forms without truncating IPv6 literals. */
internal fun normalizeHost(raw: String): String {
    val authority = raw.trim().removePrefix("https://").removePrefix("http://")
        .trimStart('/').substringBefore('/')
    if (authority.startsWith('[')) return authority.substringAfter('[').substringBefore(']')
    return if (authority.count { it == ':' } == 1) authority.substringBefore(':') else authority
}
