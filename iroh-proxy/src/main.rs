use std::{
    collections::HashSet,
    env,
    fs::{self, OpenOptions},
    io::{Read, Write},
    net::SocketAddr,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use anyhow::{Context, Result, bail, ensure};
use iroh::{Endpoint, EndpointAddr, EndpointId, SecretKey, TransportAddr, endpoint::presets};
use iroh_tickets::{Ticket, endpoint::EndpointTicket};
use tokio::{io as tokio_io, io::AsyncWriteExt, net::TcpStream, task::JoinSet};

const ALPN: &[u8] = b"steamlesslink/uhid-raw/0";

#[tokio::main]
async fn main() -> Result<()> {
    let args = env::args().skip(1).collect::<Vec<_>>();
    if args.first().is_some_and(|arg| arg == "connect") {
        let (identity_key, ticket) = match args.as_slice() {
            [_, ticket] => (None, ticket.clone()),
            [_, option, path, ticket] if option == "--identity-key" => {
                (Some(PathBuf::from(path)), ticket.clone())
            }
            _ => bail!(
                "usage: steamless-link-iroh-proxy connect [--identity-key PATH] ENDPOINT_TICKET"
            ),
        };
        return connect(identity_key, ticket).await;
    }

    let (target, identity_key, ticket_file, allowed_peers) = serve_args(args)?;
    serve(
        target,
        identity_key.as_deref(),
        ticket_file.as_deref(),
        allowed_peers,
    )
    .await
}

fn serve_args(
    args: Vec<String>,
) -> Result<(
    SocketAddr,
    Option<PathBuf>,
    Option<PathBuf>,
    HashSet<EndpointId>,
)> {
    let mut args = args.into_iter();
    let mut identity_key = env::var_os("STEAMLESS_IROH_IDENTITY_KEY").map(PathBuf::from);
    let mut ticket_file = env::var_os("STEAMLESS_IROH_TICKET_FILE").map(PathBuf::from);
    let mut target = None;
    let mut allowed_peers = HashSet::new();
    let usage = "usage: steamless-link-iroh-proxy [--identity-key PATH] [--ticket-file PATH] [--allow-peer ENDPOINT_ID]... [tcp-host:port]";

    while let Some(arg) = args.next() {
        if arg == "--identity-key" {
            identity_key = Some(PathBuf::from(args.next().context(usage)?));
        } else if arg == "--ticket-file" {
            ticket_file = Some(PathBuf::from(args.next().context(usage)?));
        } else if arg == "--allow-peer" {
            let peer_str = args.next().context(usage)?;
            let endpoint_id: EndpointId = peer_str
                .parse()
                .with_context(|| format!("failed to parse endpoint ID: {}", peer_str))?;
            allowed_peers.insert(endpoint_id);
        } else if arg.starts_with('-') {
            bail!("unknown option {arg}");
        } else if target.replace(arg).is_some() {
            bail!(usage);
        }
    }

    let target = target
        .unwrap_or_else(|| "127.0.0.1:3244".to_string())
        .parse::<SocketAddr>()
        .context(usage)?;

    if allowed_peers.is_empty() {
        bail!(
            "no allowed peers configured; at least one --allow-peer ENDPOINT_ID must be provided"
        );
    }

    Ok((target, identity_key, ticket_file, allowed_peers))
}

fn load_or_create_secret_key(path: &Path) -> Result<SecretKey> {
    match fs::read(path) {
        Ok(bytes) => {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;

                let metadata = fs::symlink_metadata(path).with_context(|| {
                    format!("read Iroh identity key metadata at {}", path.display())
                })?;
                ensure!(
                    metadata.file_type().is_file(),
                    "Iroh identity key {} must be a regular file",
                    path.display()
                );
                ensure!(
                    metadata.permissions().mode() & 0o777 == 0o600,
                    "Iroh identity key {} must have mode 0600",
                    path.display()
                );
            }
            ensure!(
                bytes.len() == 32,
                "Iroh identity key {} must contain exactly 32 bytes, found {}",
                path.display(),
                bytes.len()
            );
            Ok(SecretKey::try_from(bytes.as_slice())?)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let key = SecretKey::generate();
            match write_secret_key(path, &key) {
                Ok(()) => Ok(key),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                    load_or_create_secret_key(path)
                }
                Err(error) => Err(error)
                    .with_context(|| format!("create Iroh identity key at {}", path.display())),
            }
        }
        Err(error) => {
            Err(error).with_context(|| format!("read Iroh identity key at {}", path.display()))
        }
    }
}

fn write_secret_key(path: &Path, key: &SecretKey) -> std::io::Result<()> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;

        options.mode(0o600);
    }
    let mut file = options.open(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        file.set_permissions(fs::Permissions::from_mode(0o600))?;
    }
    file.write_all(&key.to_bytes())?;
    file.sync_all()
}

fn write_ticket_file(path: &Path, ticket: &str) -> std::io::Result<()> {
    let temporary = path.with_extension("tmp");
    let mut options = OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;

        options.mode(0o600);
    }
    let mut file = options.open(&temporary)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        file.set_permissions(fs::Permissions::from_mode(0o600))?;
    }
    file.write_all(ticket.as_bytes())?;
    file.sync_all()?;
    fs::rename(temporary, path)
}

async fn serve(
    target: SocketAddr,
    identity_key: Option<&Path>,
    ticket_file: Option<&Path>,
    allowed_peers: HashSet<EndpointId>,
) -> Result<()> {
    let bind_addr = env::var("STEAMLESS_IROH_BIND_ADDR").ok();
    let mut builder = Endpoint::builder(presets::N0).alpns(vec![ALPN.to_vec()]);
    if let Some(path) = identity_key {
        builder = builder.secret_key(load_or_create_secret_key(path)?);
    }
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
    if let Some(path) = ticket_file {
        write_ticket_file(path, &ticket)
            .with_context(|| format!("write Iroh ticket to {}", path.display()))?;
    }
    eprintln!("Forwarding Iroh {ticket} -> {target}");
    println!("{ticket}");

    let mut connections = JoinSet::new();
    let allowed_peers = Arc::new(allowed_peers);
    while let Some(incoming) = endpoint.accept().await {
        while connections.try_join_next().is_some() {}
        if connections.len() >= 16 {
            incoming.refuse();
            continue;
        }
        let allowed = allowed_peers.clone();
        connections.spawn(async move {
            if let Err(error) = forward(incoming, target, &allowed).await {
                eprintln!("iroh proxy connection failed: {error:#}");
            }
        });
    }
    Ok(())
}

async fn connect(identity_key: Option<PathBuf>, ticket: String) -> Result<()> {
    let mut input = Vec::new();
    std::io::stdin().read_to_end(&mut input)?;

    let addr = EndpointTicket::decode_string(&ticket)?
        .endpoint_addr()
        .clone();
    let mut builder = Endpoint::builder(presets::N0);
    if let Some(path) = identity_key {
        builder = builder.secret_key(load_or_create_secret_key(&path)?);
    }
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

async fn forward(
    incoming: iroh::endpoint::Incoming,
    target: SocketAddr,
    allowed_peers: &HashSet<EndpointId>,
) -> Result<()> {
    let timeout = Duration::from_secs(10);
    let conn = tokio::time::timeout(timeout, incoming.accept()?).await??;
    let result = async {
        ensure!(
            allowed_peers.contains(&conn.remote_id()),
            "unauthorized controller {}",
            conn.remote_id()
        );
        // Authorization precedes both stream admission and opening the TCP target.
        let (mut send, mut recv) = tokio::time::timeout(timeout, conn.accept_bi()).await??;
        let tcp = tokio::time::timeout(timeout, TcpStream::connect(target)).await??;
        let (mut tcp_recv, mut tcp_send) = tcp.into_split();
        let to_tcp = async {
            tokio_io::copy(&mut recv, &mut tcp_send).await?;
            tcp_send.shutdown().await
        };
        let to_iroh = async {
            tokio_io::copy(&mut tcp_recv, &mut send).await?;
            send.finish()?;
            Ok::<_, anyhow::Error>(())
        };
        tokio::try_join!(async { to_tcp.await.map_err(anyhow::Error::from) }, to_iroh)?;
        // finish queues FIN; wait for acknowledgement before closing the connection.
        tokio::time::timeout(timeout, send.stopped()).await??;
        Ok(())
    }
    .await;
    conn.close(0u8.into(), b"session ended");
    result
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        time::{SystemTime, UNIX_EPOCH},
    };

    use super::*;

    fn temp_dir() -> PathBuf {
        let path = env::temp_dir().join(format!(
            "steamless-link-iroh-proxy-test-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&path).unwrap();
        path
    }

    #[test]
    fn identity_key_is_private_and_stable() {
        let dir = temp_dir();
        let path = dir.join("identity.key");
        let generated = load_or_create_secret_key(&path).unwrap();
        let loaded = load_or_create_secret_key(&path).unwrap();

        assert_eq!(generated.to_bytes(), loaded.to_bytes());
        assert_eq!(fs::metadata(&path).unwrap().len(), 32);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;

            assert_eq!(
                fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn ticket_file_is_private() {
        let dir = temp_dir();
        let path = dir.join("ticket");
        write_ticket_file(&path, "endpoint-test").unwrap();

        assert_eq!(fs::read_to_string(&path).unwrap(), "endpoint-test");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;

            assert_eq!(
                fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn malformed_identity_key_is_rejected() {
        let dir = temp_dir();
        let path = dir.join("identity.key");
        fs::write(&path, [0; 31]).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;

            fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        }

        assert!(load_or_create_secret_key(&path).is_err());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn empty_allowlist_rejected() {
        let args = vec!["127.0.0.1:3244".to_string()];
        let result = serve_args(args);
        assert!(result.is_err());
        assert!(
            result
                .unwrap_err()
                .to_string()
                .contains("no allowed peers configured")
        );
    }

    #[test]
    fn allow_peer_parsing() {
        let key = SecretKey::generate();
        let endpoint_id = key.public();
        let id_str = endpoint_id.to_string();

        let args = vec![
            "--allow-peer".to_string(),
            id_str.clone(),
            "127.0.0.1:3244".to_string(),
        ];
        let (_, _, _, allowed) = serve_args(args).unwrap();

        assert_eq!(allowed.len(), 1);
        assert!(allowed.contains(&endpoint_id));
    }

    #[test]
    fn multiple_allowed_peers() {
        let key1 = SecretKey::generate();
        let key2 = SecretKey::generate();
        let id1_str = key1.public().to_string();
        let id2_str = key2.public().to_string();

        let args = vec![
            "--allow-peer".to_string(),
            id1_str,
            "--allow-peer".to_string(),
            id2_str,
            "127.0.0.1:3244".to_string(),
        ];
        let (_, _, _, allowed) = serve_args(args).unwrap();

        assert_eq!(allowed.len(), 2);
        assert!(allowed.contains(&key1.public()));
        assert!(allowed.contains(&key2.public()));
    }

    #[test]
    fn identity_key_file_option() {
        let args = vec![
            "--identity-key".to_string(),
            "/tmp/key".to_string(),
            "--allow-peer".to_string(),
            SecretKey::generate().public().to_string(),
            "127.0.0.1:3244".to_string(),
        ];
        let (_, key_path, _, _) = serve_args(args).unwrap();

        assert_eq!(key_path, Some(PathBuf::from("/tmp/key")));
    }

    #[test]
    fn ticket_file_option() {
        let args = vec![
            "--ticket-file".to_string(),
            "/tmp/ticket".to_string(),
            "--allow-peer".to_string(),
            SecretKey::generate().public().to_string(),
            "127.0.0.1:3244".to_string(),
        ];
        let (_, _, ticket_path, _) = serve_args(args).unwrap();

        assert_eq!(ticket_path, Some(PathBuf::from("/tmp/ticket")));
    }
}
