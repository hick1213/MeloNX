// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from Madeira; see distribution/legal/Madeira-JIT-EXCEPTION.md

//! On-device remote pairing for Built-in StikJIT (iOS 27 and later).
//!
//! Madeira plays the computer in iOS 27's device-initiated pairing: it listens
//! on a TCP port, the app advertises that port as a
//! `_remotepairing-pairable-host._tcp` Bonjour service (through NetService, so no
//! multicast entitlement is needed), the user taps "Pair with Madeira" under
//! Settings > Privacy & Security > Developer Mode and types the PIN Madeira
//! shows. The result is the RPPairing plist StikJIT reads.
//!
//! The protocol is idevice's `PairableHost` (MIT, jkcoxson/idevice). This file
//! only binds the listener, hands the advertisement to Swift and returns the
//! pairing file as bytes.

use std::collections::VecDeque;
use std::future::Future;
use std::time::Duration;
use std::ffi::{CStr, CString, c_char, c_void};
use std::net::{Ipv4Addr, TcpListener};
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use idevice::remote_pairing::{PairableHost, PairableHostInfo, PeerDevice, RpPairingFile, RpPairingSocket};
use tokio::sync::Notify;
use tokio::task::{AbortHandle, Id, JoinSet};

/// iOS shows the host as a computer; keep this a Mac model identifier.
const HOST_MODEL: &str = "Mac17,7";

pub struct MeloNXRPPairing {
    port: u16,
    service_name: CString,
    txt: Vec<(CString, CString)>,
    listener: Mutex<Option<TcpListener>>,
    identity: Mutex<Option<(RpPairingFile, PairableHostInfo)>>,
    cancelled: AtomicBool,
    cancel: Notify,
}

pub type MeloNXRPPairingPinCallback = Option<extern "C" fn(pin: *const c_char, context: *mut c_void)>;

#[derive(Clone, Copy)]
struct PinTarget {
    callback: MeloNXRPPairingPinCallback,
    context: *mut c_void,
}
// The context is only handed back to the caller's callback, on the accepting thread.
unsafe impl Send for PinTarget {}
unsafe impl Sync for PinTarget {}

impl PinTarget {
    fn show(&self, pin: String) {
        if let (Some(callback), Ok(pin)) = (self.callback, CString::new(pin)) {
            callback(pin.as_ptr(), self.context);
        }
    }
}

enum Failure {
    Cancelled,
    Error(String),
}

fn set_error(out: *mut *mut c_char, message: impl Into<Vec<u8>>) {
    if !out.is_null() {
        unsafe { *out = CString::new(message).unwrap_or_default().into_raw() };
    }
}

/// Checks that a Remote Pairing Bonjour advertisement belongs to the paired
/// device. Returns 1 for a match, 0 for invalid inputs or a different device.
/// Uses idevice's peer matcher; no pairing keys or TXT records are logged.
///
/// # Safety
/// Non-NULL `alt_irk` must point to `alt_irk_len` readable bytes. Non-NULL
/// `identifier` and `auth_tag` must be readable NUL-terminated strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn melonx_rppairing_validate_auth_tag(
    alt_irk: *const u8,
    alt_irk_len: usize,
    identifier: *const c_char,
    auth_tag: *const c_char,
) -> i32 {
    if alt_irk.is_null() || alt_irk_len != 16 || identifier.is_null() || auth_tag.is_null() {
        return 0;
    }
    let (Ok(identifier), Ok(auth_tag)) = (
        unsafe { CStr::from_ptr(identifier) }.to_str(),
        unsafe { CStr::from_ptr(auth_tag) }.to_str(),
    ) else {
        return 0;
    };
    if identifier.is_empty() || identifier.len() > 255 || auth_tag.len() != 8 {
        return 0;
    }
    let alt_irk = unsafe { std::slice::from_raw_parts(alt_irk, alt_irk_len) };
    i32::from(PeerDevice::validate_auth_tag(alt_irk, identifier, auth_tag))
}

/// Generates a fresh host identity and binds a TCP listener on all IPv4
/// interfaces. Returns NULL on failure, with `*error` set (free it with
/// `melonx_rppairing_string_free`).
///
/// # Safety
/// `name` must be a valid NUL-terminated string. `error` must be NULL or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn melonx_rppairing_new(name: *const c_char, error: *mut *mut c_char) -> *mut MeloNXRPPairing {
    if name.is_null() {
        set_error(error, "missing host name");
        return ptr::null_mut();
    }
    let name = match unsafe { CStr::from_ptr(name) }.to_str() {
        Ok(name) if !name.is_empty() => name.to_string(),
        _ => {
            set_error(error, "invalid host name");
            return ptr::null_mut();
        }
    };

    let listener = match TcpListener::bind((Ipv4Addr::UNSPECIFIED, 0)) {
        Ok(listener) => listener,
        Err(e) => {
            set_error(error, format!("could not open the pairing port: {e}"));
            return ptr::null_mut();
        }
    };
    let port = match listener.local_addr().and_then(|addr| listener.set_nonblocking(true).map(|_| addr.port())) {
        Ok(port) => port,
        Err(e) => {
            set_error(error, format!("could not open the pairing port: {e}"));
            return ptr::null_mut();
        }
    };

    // The device only offers pair-setup to a host it does not recognise, so a
    // new identity per run is intended: the identifier stays the same (it is
    // derived from the name) and the device replaces its record for it.
    let pairing_file = RpPairingFile::generate(&name);
    let host_info = PairableHostInfo::generate(&name, HOST_MODEL);
    let identifier = pairing_file.identifier.clone();
    let txt = host_info
        .mdns_txt_records(&identifier)
        .into_iter()
        .filter_map(|(k, v)| Some((CString::new(k).ok()?, CString::new(v).ok()?)))
        .collect();

    Box::into_raw(Box::new(MeloNXRPPairing {
        port,
        service_name: CString::new(identifier).unwrap_or_default(),
        txt,
        listener: Mutex::new(Some(listener)),
        identity: Mutex::new(Some((pairing_file, host_info))),
        cancelled: AtomicBool::new(false),
        cancel: Notify::new(),
    }))
}

/// # Safety
/// `session` must be a live pointer from `melonx_rppairing_new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn melonx_rppairing_port(session: *const MeloNXRPPairing) -> u16 {
    unsafe { &*session }.port
}

/// The Bonjour service instance name to publish. Owned by the session.
///
/// # Safety
/// `session` must be a live pointer from `melonx_rppairing_new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn melonx_rppairing_service_name(session: *const MeloNXRPPairing) -> *const c_char {
    unsafe { &*session }.service_name.as_ptr()
}

/// # Safety
/// `session` must be a live pointer from `melonx_rppairing_new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn melonx_rppairing_txt_count(session: *const MeloNXRPPairing) -> usize {
    unsafe { &*session }.txt.len()
}

/// TXT record key at `index`, or NULL past the end. Owned by the session.
///
/// # Safety
/// `session` must be a live pointer from `melonx_rppairing_new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn melonx_rppairing_txt_key(session: *const MeloNXRPPairing, index: usize) -> *const c_char {
    unsafe { &*session }.txt.get(index).map_or(ptr::null(), |(k, _)| k.as_ptr())
}

/// TXT record value at `index`, or NULL past the end. Owned by the session.
///
/// # Safety
/// `session` must be a live pointer from `melonx_rppairing_new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn melonx_rppairing_txt_value(session: *const MeloNXRPPairing, index: usize) -> *const c_char {
    unsafe { &*session }.txt.get(index).map_or(ptr::null(), |(_, v)| v.as_ptr())
}

/// Blocks until a device pairs, pairing fails, or `melonx_rppairing_cancel`
/// is called. `pin_callback` runs on this thread with the 6-digit code to show.
///
/// Returns 0 on success (`*out_plist`/`*out_len` hold the RPPairing plist, free
/// with `melonx_rppairing_bytes_free`; `*out_device_name` the device's name),
/// 1 on failure (`*error` set), 2 when cancelled. Call at most once per session.
///
/// # Safety
/// `session` must be a live pointer from `melonx_rppairing_new`; the out
/// pointers must be NULL or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn melonx_rppairing_accept(
    session: *const MeloNXRPPairing,
    pin_callback: MeloNXRPPairingPinCallback,
    pin_context: *mut c_void,
    out_plist: *mut *mut u8,
    out_len: *mut usize,
    out_device_name: *mut *mut c_char,
    error: *mut *mut c_char,
) -> i32 {
    let session = unsafe { &*session };
    let listener = session.listener.lock().ok().and_then(|mut l| l.take());
    let identity = session.identity.lock().ok().and_then(|mut i| i.take());
    let (Some(listener), Some((pairing_file, host_info))) = (listener, identity) else {
        set_error(error, "this pairing session has already been used");
        return 1;
    };

    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(e) => {
            set_error(error, format!("could not start the pairing runtime: {e}"));
            return 1;
        }
    };
    let target = PinTarget { callback: pin_callback, context: pin_context };

    match runtime.block_on(accept(session, listener, pairing_file, host_info, target)) {
        Ok((file, device_name)) => {
            let bytes = file.to_bytes().into_boxed_slice();
            if !out_len.is_null() {
                unsafe { *out_len = bytes.len() };
            }
            if !out_plist.is_null() {
                unsafe { *out_plist = Box::into_raw(bytes) as *mut u8 };
            }
            if !out_device_name.is_null() {
                unsafe { *out_device_name = CString::new(device_name).unwrap_or_default().into_raw() };
            }
            0
        }
        Err(Failure::Cancelled) => 2,
        Err(Failure::Error(message)) => {
            set_error(error, message);
            1
        }
    }
}

type PairingResult = Result<(RpPairingFile, String), idevice::IdeviceError>;

struct PeerOutcome {
    pin_shown: bool,
    result: PairingResult,
}

/// Retain at most eight handshakes. A new connection replaces the oldest
/// pre-PIN peer; the selected peer is never evicted by an unrelated connection.
struct PairingPeers {
    tasks: JoinSet<PairingResult>,
    active: VecDeque<(Id, Arc<AtomicBool>, AbortHandle)>,
    limit: usize,
}

impl PairingPeers {
    fn new(limit: usize) -> Self {
        assert!(limit > 1);
        Self { tasks: JoinSet::new(), active: VecDeque::new(), limit }
    }

    fn spawn(&mut self, pin: Arc<AtomicBool>, work: impl Future<Output = PairingResult> + Send + 'static) {
        if self.active.len() >= self.limit {
            if let Some(index) = self.active.iter().position(|(_, pin, _)| !pin.load(Ordering::SeqCst)) {
                let (_, _, handle) = self.active.remove(index).unwrap();
                handle.abort();
            } else { return; }
        }
        let handle = self.tasks.spawn(work);
        self.active.push_back((handle.id(), pin, handle));
    }

    async fn next(&mut self) -> Option<PeerOutcome> {
        while let Some(done) = self.tasks.join_next_with_id().await {
            let id = match &done { Ok((id, _)) => *id, Err(error) => error.id() };
            let Some(index) = self.active.iter().position(|(active_id, _, _)| *active_id == id) else { continue };
            let (_, pin, _) = self.active.remove(index).unwrap();
            let result = match done { Ok((_, result)) => result, Err(_) => Err(idevice::IdeviceError::Timeout) };
            return Some(PeerOutcome { pin_shown: pin.load(Ordering::SeqCst), result });
        }
        None
    }

    #[cfg(test)]
    fn active_count(&self) -> usize { self.active.len() }
    #[cfg(test)]
    fn contains_pin_owner(&self) -> bool { self.active.iter().any(|(_, pin, _)| pin.load(Ordering::SeqCst)) }
}

async fn with_peer_deadline<T>(work: impl Future<Output = Result<T, idevice::IdeviceError>>,
    pin: Arc<AtomicBool>, notify: Arc<Notify>, initial: Duration, confirmation: Duration) -> Result<T, idevice::IdeviceError> {
    tokio::pin!(work);
    if pin.load(Ordering::SeqCst) {
        return tokio::time::timeout(confirmation, work).await.map_err(|_| idevice::IdeviceError::Timeout)?;
    }
    tokio::select! {
        result = &mut work => result,
        _ = notify.notified() => tokio::time::timeout(confirmation, work).await.map_err(|_| idevice::IdeviceError::Timeout)?,
        _ = tokio::time::sleep(initial) => Err(idevice::IdeviceError::Timeout),
    }
}

async fn attempt(
    stream: tokio::net::TcpStream,
    mut file: RpPairingFile,
    host_info: PairableHostInfo,
    target: PinTarget,
    pin_shown: Arc<AtomicBool>,
    selected: Arc<AtomicBool>,
) -> PairingResult {
    let mut host = PairableHost::new(RpPairingSocket::new_device(stream), host_info);
    let notify = Arc::new(Notify::new());
    let callback_pin = pin_shown.clone();
    let callback_notify = notify.clone();
    let work = async {
        let peer = host.accept(&mut file, |pin| {
            if selected.compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst).is_ok() {
                callback_pin.store(true, Ordering::SeqCst);
                callback_notify.notify_one();
                target.show(pin);
            }
            async {}
        }).await?;
        if !pin_shown.load(Ordering::SeqCst) { return Err(idevice::IdeviceError::Timeout); }
        Ok((file, peer.name))
    };
    with_peer_deadline(work, pin_shown.clone(), notify, Duration::from_secs(5), Duration::from_secs(120)).await
}

async fn accept(
    session: &MeloNXRPPairing,
    listener: TcpListener,
    pairing_file: RpPairingFile,
    host_info: PairableHostInfo,
    target: PinTarget,
) -> Result<(RpPairingFile, String), Failure> {
    let listener = tokio::net::TcpListener::from_std(listener)
        .map_err(|e| Failure::Error(format!("could not listen for the device: {e}")))?;
    let selected = Arc::new(AtomicBool::new(false));

    // Every connection is served at once, so one that stays open without
    // speaking cannot keep the device from reaching Madeira.
    let pair = async {
        let mut attempts = PairingPeers::new(8);
        loop {
            tokio::select! {
                connection = listener.accept() => {
                    let (stream, _) = connection
                        .map_err(|e| Failure::Error(format!("could not accept the device's connection: {e}")))?;
                    let pin = Arc::new(AtomicBool::new(false));
                    attempts.spawn(pin.clone(), attempt(stream, pairing_file.clone(), host_info.clone(), target, pin, selected.clone()));
                }
                Some(done) = attempts.next() => match done.result {
                    Ok(paired) if done.pin_shown => return Ok(paired),
                    // A failure belongs only to the peer that displayed our PIN.
                    Err(e) if done.pin_shown => return Err(Failure::Error(format!("pairing failed: {e}"))),
                    _ => continue,
                },
            }
        }
    };

    if session.cancelled.load(Ordering::SeqCst) {
        return Err(Failure::Cancelled);
    }
    tokio::select! {
        biased;
        _ = session.cancel.notified() => Err(Failure::Cancelled),
        result = pair => result,
    }
}

/// Ends a running or future `melonx_rppairing_accept` with result 2. Safe from
/// any thread, any number of times.
///
/// # Safety
/// `session` must be a live pointer from `melonx_rppairing_new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn melonx_rppairing_cancel(session: *const MeloNXRPPairing) {
    let session = unsafe { &*session };
    session.cancelled.store(true, Ordering::SeqCst);
    session.cancel.notify_one();
}

/// # Safety
/// `session` must be NULL or a pointer from `melonx_rppairing_new` whose
/// accept, if any, has returned.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn melonx_rppairing_free(session: *mut MeloNXRPPairing) {
    if !session.is_null() {
        drop(unsafe { Box::from_raw(session) });
    }
}

/// # Safety
/// `bytes`/`len` must come from `melonx_rppairing_accept`, or `bytes` be NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn melonx_rppairing_bytes_free(bytes: *mut u8, len: usize) {
    if !bytes.is_null() {
        drop(unsafe { Box::from_raw(ptr::slice_from_raw_parts_mut(bytes, len)) });
    }
}

/// # Safety
/// `string` must be NULL or a string returned by this library.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn melonx_rppairing_string_free(string: *mut c_char) {
    if !string.is_null() {
        drop(unsafe { CString::from_raw(string) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::net::TcpStream;
    use std::thread;
    use std::time::Duration;

    struct Session(*mut MeloNXRPPairing);
    unsafe impl Send for Session {}
    unsafe impl Sync for Session {}

    fn new_session() -> Session {
        let mut error = ptr::null_mut();
        let session = unsafe { melonx_rppairing_new(c"MeloNX".as_ptr(), &mut error) };
        assert!(!session.is_null() && error.is_null());
        Session(session)
    }

    fn accept(session: &Session) -> (i32, Option<String>) {
        let (mut bytes, mut len, mut name, mut error) = (ptr::null_mut(), 0, ptr::null_mut(), ptr::null_mut());
        let status = unsafe {
            melonx_rppairing_accept(session.0, None, ptr::null_mut(), &mut bytes, &mut len, &mut name, &mut error)
        };
        assert!(bytes.is_null() && name.is_null());
        let message = (!error.is_null()).then(|| {
            let text = unsafe { CStr::from_ptr(error) }.to_string_lossy().into_owned();
            unsafe { melonx_rppairing_string_free(error) };
            text
        });
        (status, message)
    }

    fn string(p: *const c_char) -> String {
        unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_string()
    }

    #[test]
    fn advertisement_matches_the_host_identity() {
        let session = new_session();
        unsafe {
            assert_ne!(melonx_rppairing_port(session.0), 0);
            let identifier = string(melonx_rppairing_service_name(session.0));
            assert_eq!(identifier.len(), 36, "a UUID");
            let txt: Vec<(String, String)> = (0..melonx_rppairing_txt_count(session.0))
                .map(|i| (string(melonx_rppairing_txt_key(session.0, i)), string(melonx_rppairing_txt_value(session.0, i))))
                .collect();
            let get = |key: &str| txt.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone());
            assert_eq!(get("name").as_deref(), Some("MeloNX"));
            assert_eq!(get("identifier"), Some(identifier));
            assert_eq!(get("model").as_deref(), Some(HOST_MODEL));
            assert!(get("authTag").is_some_and(|tag| !tag.is_empty()));
            assert!(txt.iter().all(|(k, v)| k.len() + v.len() < 255), "every TXT entry fits one length byte");
            assert!(melonx_rppairing_txt_key(session.0, txt.len()).is_null());
            melonx_rppairing_free(session.0);
        }
    }

    #[test]
    fn identifier_is_stable_across_runs() {
        let (a, b) = (new_session(), new_session());
        unsafe {
            assert_eq!(string(melonx_rppairing_service_name(a.0)), string(melonx_rppairing_service_name(b.0)));
            assert_ne!(melonx_rppairing_port(a.0), melonx_rppairing_port(b.0));
            melonx_rppairing_free(a.0);
            melonx_rppairing_free(b.0);
        }
    }

    #[test]
    fn cancel_before_accept_returns_cancelled() {
        let session = new_session();
        unsafe { melonx_rppairing_cancel(session.0) };
        assert_eq!(accept(&session), (2, None));
        let (status, message) = accept(&session);
        assert_eq!(status, 1, "a session is single use");
        assert!(message.is_some());
        unsafe { melonx_rppairing_free(session.0) };
    }

    #[test]
    fn stray_connections_do_not_end_the_wait_and_cancel_does() {
        let session = new_session();
        let port = unsafe { melonx_rppairing_port(session.0) };
        thread::scope(|scope| {
            let waiter = scope.spawn(|| accept(&session));
            // A connection that closes, then one that sends garbage, before any PIN.
            drop(TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap());
            let mut junk = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
            junk.write_all(b"GET / HTTP/1.1\r\n\r\n").unwrap();
            drop(junk);
            thread::sleep(Duration::from_millis(300));
            assert!(!waiter.is_finished(), "still listening for the device");
            unsafe { melonx_rppairing_cancel(session.0) };
            assert_eq!(waiter.join().unwrap(), (2, None));
        });
        unsafe { melonx_rppairing_free(session.0) };
    }

    #[test]
    fn a_silent_connection_does_not_block_the_next_one() {
        use std::io::{ErrorKind, Read};
        let session = new_session();
        let port = unsafe { melonx_rppairing_port(session.0) };
        thread::scope(|scope| {
            let waiter = scope.spawn(|| accept(&session));
            let _silent = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
            thread::sleep(Duration::from_millis(100));
            // Half-closed: the server reads to the end, fails the attempt and
            // hangs up, which the read below sees -- unless it never reads.
            let mut junk = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
            junk.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
            junk.write_all(b"not rppairing\r\n\r\n").unwrap();
            junk.shutdown(std::net::Shutdown::Write).unwrap();
            let served = match junk.read(&mut [0u8; 64]) {
                Ok(_) => true,
                Err(e) => !matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut),
            };
            unsafe { melonx_rppairing_cancel(session.0) };
            assert_eq!(waiter.join().unwrap(), (2, None));
            assert!(served, "the second connection was not served while the first stayed silent");
        });
        unsafe { melonx_rppairing_free(session.0) };
    }
}

#[cfg(test)]
#[path = "peers_tests.rs"]
mod peers_tests;

#[cfg(test)]
mod auth_tests;
