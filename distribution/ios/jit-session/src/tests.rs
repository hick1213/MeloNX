use super::*;

#[test]
fn authenticated_dynamic_port_keeps_loopback_address_restriction() {
    let invalid_pairing = [1u8]; // Rejected before network I/O; no user credentials.
    unsafe {
        let session = ffi::melonx_owned_debug_new(invalid_pairing.as_ptr(), 1, c"10.7.0.1".as_ptr(), 56958);
        assert!(!session.is_null());
        ffi::melonx_owned_debug_free(session);
        assert!(ffi::melonx_owned_debug_new(invalid_pairing.as_ptr(), 1, c"10.7.0.1".as_ptr(), 0).is_null());
        assert!(ffi::melonx_owned_debug_new(invalid_pairing.as_ptr(), 1, c"192.168.1.1".as_ptr(), 56958).is_null());
    }
}
use std::sync::{Arc, atomic::{AtomicUsize, Ordering}};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

#[test]
fn cancel_interrupts_a_real_blocked_read_and_joins_the_only_owner() {
    let closes = Arc::new(AtomicUsize::new(0));
    let count = closes.clone();
    let session = Arc::new(OwnedSession::spawn(move |mut requests, cancel| async move {
        struct CloseCount(Arc<AtomicUsize>);
        impl Drop for CloseCount { fn drop(&mut self) { self.0.fetch_add(1, Ordering::SeqCst); } }
        let _owner = CloseCount(count);
        let (mut socket, mut peer) = tokio::io::duplex(64);
        let request = requests.recv().await.unwrap();
        peer.write_all(b"command accepted").await.unwrap();
        // Drain already buffered bytes, then block indefinitely while peer stays open.
        let mut buffer = [0u8; 16];
        socket.read_exact(&mut buffer).await.unwrap();
        let mut byte = [0u8; 1];
        let blocked = socket.read_exact(&mut byte);
        let result = interruptible(&cancel, blocked, Duration::from_secs(30)).await;
        drop(socket); drop(peer);
        let _ = request.reply.send(result.map(|_| String::new()).map_err(|_| SessionError::Cancelled));
    }));
    std::thread::scope(|scope| {
        let reader = scope.spawn(|| session.command("c".into()));
        std::thread::sleep(Duration::from_millis(30));
        session.cancel(); session.cancel();
        assert!(matches!(reader.join().unwrap(), Err(SessionError::Cancelled)));
    });
    assert_joined(session.clone());
    assert!(session.has_ended());
    assert_eq!(closes.load(Ordering::SeqCst), 1, "one owner closes resources exactly once");
}

#[test]
fn cancellation_before_a_wait_cannot_be_lost() {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    runtime.block_on(async {
        let cancel = Cancellation::default();
        cancel.cancel();
        let result = interruptible(&cancel, std::future::pending::<()>(), Duration::from_secs(30)).await;
        assert!(matches!(result, Err(SessionError::Cancelled)));
    });
}

#[test]
fn deadline_drops_a_silent_peer_future() {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    runtime.block_on(async {
        let cancel = Cancellation::default();
        let result = interruptible(&cancel, std::future::pending::<()>(), Duration::from_millis(20)).await;
        assert!(matches!(result, Err(SessionError::TimedOut)));
    });
}

#[test]
fn completion_racing_cancel_never_reuses_a_closed_session() {
    for _ in 0..50 {
        let session = Arc::new(OwnedSession::spawn(|mut requests, cancel| async move {
            if let Some(request) = requests.recv().await {
                let result = interruptible(&cancel, async { "OK".to_string() }, Duration::from_secs(1)).await;
                let _ = request.reply.send(result);
            }
        }));
        std::thread::scope(|scope| {
            let result = scope.spawn(|| session.command("D".into()));
            session.cancel();
            assert!(matches!(result.join().unwrap(), Ok(_) | Err(SessionError::Cancelled) | Err(SessionError::Ended)));
        });
        assert_joined(session.clone());
        assert!(matches!(session.command("c".into()), Err(SessionError::Cancelled) | Err(SessionError::Ended)));
    }
}

fn assert_joined(session: Arc<OwnedSession>) {
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || { let result = session.join(); let _ = sender.send(result); });
    receiver.recv_timeout(Duration::from_secs(1)).expect("owner did not exit after cancellation").expect("owner panicked");
}

#[test]
fn real_tcp_peer_observes_eof_after_cancel_and_owner_join() {
    use std::io::Read;
    let listener = std::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0)).unwrap();
    let address = listener.local_addr().unwrap();
    let session = Arc::new(OwnedSession::spawn(move |mut requests, _cancel| async move {
        let mut socket = tokio::net::TcpStream::connect(address).await.unwrap();
        if let Some(request) = requests.recv().await {
            socket.write_all(request.text.as_bytes()).await.unwrap();
            let mut byte = [0u8; 1];
            let response = socket.read_exact(&mut byte).await;
            let _ = request.reply.send(response.map(|_| "OK".into()).map_err(|_| SessionError::Transport));
        }
    }));
    std::thread::scope(|scope| {
        let reader = scope.spawn(|| session.command("c".into()));
        let (mut peer, _) = listener.accept().unwrap();
        peer.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
        let mut byte = [0u8; 1];
        peer.read_exact(&mut byte).unwrap();
        assert_eq!(byte, *b"c");
        session.cancel();
        assert_joined(session.clone());
        assert_eq!(peer.read(&mut byte).unwrap(), 0, "owned socket closed before join returned");
        assert!(matches!(reader.join().unwrap(), Err(SessionError::Cancelled)));
    });
}

#[test]
fn owner_panic_is_reported_as_failure_after_resources_are_disposed() {
    let session = OwnedSession::spawn(|_requests, _cancel| async { panic!("test transport failure") });
    std::thread::sleep(Duration::from_millis(20));
    assert_eq!(session.join(), Err(SessionError::Transport));
    assert!(session.has_ended());
}

#[test]
fn exported_diagnostic_really_waits_for_cancellation() {
    let pointer = ffi::melonx_owned_debug_diagnostic_new();
    assert!(!pointer.is_null());
    let session = unsafe { &*pointer };
    std::thread::scope(|scope| {
        let reader = scope.spawn(|| session.command("WAIT".into()));
        std::thread::sleep(Duration::from_millis(20));
        assert!(!reader.is_finished(), "diagnostic lost its owned command receiver");
        assert_eq!(unsafe { ffi::melonx_owned_debug_cancel(pointer) }, 1, "actor was actually waiting when cancellation arrived");
        assert_eq!(reader.join().unwrap(), Err(SessionError::Cancelled));
    });
    assert_eq!(unsafe { ffi::melonx_owned_debug_finish(pointer) }, 0);
    unsafe { ffi::melonx_owned_debug_free(pointer) };
}
