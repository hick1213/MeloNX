use super::*;
use std::time::Duration;

#[test]
fn saturated_peers_evict_silent_connections_but_keep_the_pin_owner() {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    runtime.block_on(async {
        let mut peers = PairingPeers::new(2);
        let selected = Arc::new(AtomicBool::new(true));
        peers.spawn(selected.clone(), std::future::pending());
        let silent = Arc::new(AtomicBool::new(false));
        peers.spawn(silent.clone(), std::future::pending());
        peers.spawn(Arc::new(AtomicBool::new(false)), async { Err(idevice::IdeviceError::Timeout) });
        assert_eq!(peers.active_count(), 2);
        let outcome = tokio::time::timeout(Duration::from_secs(1), peers.next()).await.unwrap().unwrap();
        assert!(!outcome.pin_shown, "a stray failure is not a selected-peer failure");
        assert_eq!(peers.active_count(), 1);
        assert!(peers.contains_pin_owner());
    });
}

#[test]
fn silent_peer_deadline_releases_its_worker() {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    runtime.block_on(async {
        let pin = Arc::new(AtomicBool::new(false));
        let notify = Arc::new(Notify::new());
        let result = with_peer_deadline(std::future::pending::<Result<(), idevice::IdeviceError>>(),
            pin, notify, Duration::from_millis(20), Duration::from_secs(1)).await;
        assert!(result.is_err());
    });
}
