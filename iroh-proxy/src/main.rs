use std::{
    env,
    fs::{self, OpenOptions},
    io::{Read, Write},
    net::SocketAddr,
    path::{Path, PathBuf},
    time::Duration,
};

use anyhow::{Context, Result, bail, ensure};
use iroh::{Endpoint, EndpointAddr, SecretKey, TransportAddr, endpoint::presets};
use iroh_tickets::{Ticket, endpoint::EndpointTicket};
use tokio::{io as tokio_io, net::TcpStream};

const ALPN: &[u8] = b"steamlesslink/uhid-raw/0";

#[tokio::main]
async fn main() -> Result<()> {
    let args = env::args().skip(1).collect::<Vec<_>>();
    if args.first().is_some_and(|arg| arg == "connect") {
        ensure!(
            args.len() == 2,
            "usage: steamless-link-iroh-proxy connect ENDPOINT_TICKET"
        );
        return connect(args[1].clone()).await;
    }

    let (target, identity_key) = serve_args(args)?;
    serve(target, identity_key.as_deref()).await
}

fn serve_args(args: Vec<String>) -> Result<(SocketAddr, Option<PathBuf>)> {
    let mut args = args.into_iter();
    let mut identity_key = env::var_os("STEAMLESS_IROH_IDENTITY_KEY").map(PathBuf::from);
    let mut target = None;

    while let Some(arg) = args.next() {
        if arg == "--identity-key" {
            identity_key = Some(PathBuf::from(args.next().context(
                "usage: steamless-link-iroh-proxy [--identity-key PATH] [tcp-host:port]",
            )?));
        } else if arg.starts_with('-') {
            bail!("unknown option {arg}");
        } else if target.replace(arg).is_some() {
            bail!("usage: steamless-link-iroh-proxy [--identity-key PATH] [tcp-host:port]");
        }
    }

    let target = target
        .unwrap_or_else(|| "127.0.0.1:3244".to_string())
        .parse::<SocketAddr>()
        .context("usage: steamless-link-iroh-proxy [--identity-key PATH] [tcp-host:port]")?;
    Ok((target, identity_key))
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

async fn serve(target: SocketAddr, identity_key: Option<&Path>) -> Result<()> {
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
}
