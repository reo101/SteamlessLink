use std::{
    env,
    io::{Read, Write},
    net::SocketAddr,
    time::Duration,
};

use anyhow::{Context, Result};
use iroh::{Endpoint, EndpointAddr, TransportAddr, endpoint::presets};
use iroh_tickets::{Ticket, endpoint::EndpointTicket};
use tokio::{io as tokio_io, net::TcpStream};

const ALPN: &[u8] = b"steamlesslink/uhid-raw/0";

#[tokio::main]
async fn main() -> Result<()> {
    let mut args = env::args().skip(1);
    if args.next().as_deref() == Some("connect") {
        return connect(
            args.next()
                .context("usage: steamless-link-iroh-proxy connect ENDPOINT_TICKET")?,
        )
        .await;
    }

    let target = env::args()
        .nth(1)
        .unwrap_or_else(|| "127.0.0.1:3244".to_string())
        .parse::<SocketAddr>()
        .context("usage: steamless-link-iroh-proxy [tcp-host:port]")?;
    serve(target).await
}

async fn serve(target: SocketAddr) -> Result<()> {
    let bind_addr = env::var("STEAMLESS_IROH_BIND_ADDR").ok();
    let mut builder = Endpoint::builder(presets::N0).alpns(vec![ALPN.to_vec()]);
    if let Some(addr) = &bind_addr {
        builder = builder.bind_addr(addr)?;
    }
    let external_addr = env::var("STEAMLESS_IROH_EXTERNAL_ADDR").ok();
    if let Some(addr) = &external_addr {
        builder = builder.external_addr(addr.parse()?);
    }
    let endpoint = builder.bind().await?;
    if bind_addr.is_none() {
        let _ = tokio::time::timeout(Duration::from_secs(10), endpoint.online()).await;
    }

    let endpoint_addr = if let Some(addr) = external_addr {
        EndpointAddr::from_parts(endpoint.id(), [TransportAddr::Ip(addr.parse()?)])
    } else {
        endpoint.addr()
    };
    let ticket = EndpointTicket::new(endpoint_addr).encode_string();
    eprintln!("Forwarding Iroh {ticket} -> {target}");
    println!("{ticket}");

    while let Some(incoming) = endpoint.accept().await {
        tokio::spawn(async move {
            if let Err(error) = forward(incoming, target).await {
                eprintln!("iroh proxy connection failed: {error:#}");
            }
        });
    }
    Ok(())
}

async fn connect(ticket: String) -> Result<()> {
    let mut input = Vec::new();
    std::io::stdin().read_to_end(&mut input)?;

    let addr = EndpointTicket::decode_string(&ticket)?
        .endpoint_addr()
        .clone();
    let mut builder = Endpoint::builder(presets::N0);
    if let Ok(addr) = env::var("STEAMLESS_IROH_BIND_ADDR") {
        builder = builder.bind_addr(addr)?;
    }
    let endpoint = builder.bind().await?;
    let conn = endpoint.connect(addr, ALPN).await?;
    let (mut send, mut recv) = conn.open_bi().await?;

    send.write_all(&input).await?;
    send.finish()?;

    let mut output = vec![0; input.len()];
    recv.read_exact(&mut output).await?;
    std::io::stdout().write_all(&output)?;

    conn.close(0u8.into(), b"bye");
    endpoint.close().await;
    Ok(())
}

async fn forward(incoming: iroh::endpoint::Incoming, target: SocketAddr) -> Result<()> {
    let conn = incoming.accept()?.await?;
    let (mut send, mut recv) = conn.accept_bi().await?;
    let tcp = TcpStream::connect(target).await?;
    let (mut tcp_recv, mut tcp_send) = tcp.into_split();

    let from_phone = tokio_io::copy(&mut recv, &mut tcp_send);
    let to_phone = tokio_io::copy(&mut tcp_recv, &mut send);
    tokio::try_join!(from_phone, to_phone)?;

    send.finish()?;
    conn.close(0u8.into(), b"bye");
    Ok(())
}
