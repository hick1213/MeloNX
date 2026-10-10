// SPDX-License-Identifier: MPL-2.0
use std::net::{IpAddr, SocketAddr};
use idevice::{ReadWrite, RsdService, IdeviceError};
use idevice::remote_pairing::{RpPairingFile, RpPairingSocket, RemotePairingClient, connect_tls_psk_tunnel_native};
use idevice::debug_proxy::{DebugProxyClient, DebugserverCommand};
use idevice::dvt::remote_server::RemoteServerClient;
use idevice::rsd::RsdHandshake;
use super::*;

async fn connect(pairing: &[u8], address: SocketAddr)
    -> Result<(DebugProxyClient<Box<dyn ReadWrite>>, RemoteServerClient<Box<dyn ReadWrite>>), IdeviceError> {
    let mut record = RpPairingFile::from_bytes(pairing)?;
    let stream = tokio::net::TcpStream::connect(address).await?;
    let mut remote = RemotePairingClient::new(RpPairingSocket::new(stream), "MeloNX");
    // Verify only. Invalid stored credentials never silently initiate another PIN pairing.
    remote.attempt_pair_verify().await?;
    remote.validate_pairing(&mut record).await?;
    let port = remote.create_tcp_listener().await?;
    let stream = tokio::net::TcpStream::connect(SocketAddr::new(address.ip(), port)).await?;
    let tunnel = connect_tls_psk_tunnel_native(stream, remote.encryption_key()).await?;
    let client: IpAddr = tunnel.info.client_address.parse().map_err(|_| IdeviceError::Timeout)?;
    let server: IpAddr = tunnel.info.server_address.parse().map_err(|_| IdeviceError::Timeout)?;
    let rsd_port = tunnel.info.server_rsd_port;
    let mtu = tunnel.info.mtu as usize;
    let mut adapter = idevice::tcp::adapter::Adapter::new(Box::new(tunnel.into_inner()), client, server);
    adapter.set_mss(mtu.saturating_sub(60));
    let mut adapter = adapter.to_async_handle();
    let stream = adapter.connect(rsd_port).await.map_err(|_| IdeviceError::Timeout)?;
    let mut handshake = RsdHandshake::new(stream).await?;
    let server = RemoteServerClient::connect_rsd(&mut adapter, &mut handshake).await?;
    let mut proxy = DebugProxyClient::connect_rsd(&mut adapter, &mut handshake).await?;
    proxy.send_ack().await?;
    proxy.send_command(DebugserverCommand::new("QStartNoAckMode".into(), vec![])).await?;
    proxy.noack_mode = true;
    let detach = proxy.send_command(DebugserverCommand::new("QSetDetachOnError:1".into(), vec![])).await?;
    if detach.as_deref() != Some("OK") {
        return Err(IdeviceError::UnexpectedResponse("debugserver cannot detach on connection loss".into()));
    }
    Ok((proxy, server))
}

pub fn open(pairing: Vec<u8>, address: SocketAddr) -> OwnedSession {
    OwnedSession::spawn(move |mut commands, cancel| async move {
        // 15s for authenticated connect; cancellation drops partial handshakes and
        // the owner runtime disposes of its spawned adapter/remote-reader tasks.
        let connection = interruptible(&cancel, connect(&pairing, address), Duration::from_secs(15)).await;
        let Ok(Ok((mut proxy, _server))) = connection else {
            if let Some(request) = commands.recv().await { let _ = request.reply.send(Err(SessionError::Transport)); }
            return;
        };
        while let Some(request) = commands.recv().await {
            let work = async {
                let response = match request.mode {
                    CommandMode::Command => proxy.send_command(DebugserverCommand::new(request.text, vec![])).await?,
                    CommandMode::Read => proxy.read_response().await?,
                    CommandMode::Raw => { proxy.send_raw(request.text.as_bytes()).await?; Some(String::new()) },
                };
                Ok::<_, IdeviceError>(response.unwrap_or_default())
            };
            let result = interruptible(&cancel, work, Duration::from_secs(15)).await
                .and_then(|r| r.map_err(|_| SessionError::Transport))
                .and_then(|r| if r.len() <= 65_536 { Ok(r) } else { Err(SessionError::Transport) });
            let stop = result.is_err();
            let _ = request.reply.send(result);
            // A cancelled/timed-out read may have consumed a partial packet.
            // Never reuse that connection. The whole runtime owns and drops it.
            if stop { break; }
        }
    })
}
