// SPDX-License-Identifier: MPL-2.0
use std::ffi::{CStr, CString, c_char};
use super::*;

/// # Safety
/// Bytes and address must be valid readable buffers. Returned handle stays alive
/// until all its command/cancel calls finish; free only after its owner has joined.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn melonx_owned_debug_new(bytes: *const u8, length: usize,
    address: *const c_char, port: u16) -> *mut OwnedSession {
    if bytes.is_null() || address.is_null() || length == 0 || length > 1_048_576 { return std::ptr::null_mut() }
    let Ok(address) = unsafe { CStr::from_ptr(address) }.to_str() else { return std::ptr::null_mut() };
    // The helper uses only its own device loopback; arbitrary endpoints are not accepted.
    if address != "10.7.0.1" || port == 0 { return std::ptr::null_mut() }
    let pairing = unsafe { std::slice::from_raw_parts(bytes, length) }.to_vec();
    let socket = std::net::SocketAddr::new(address.parse().unwrap(), port);
    Box::into_raw(Box::new(debug_transport::open(pairing, socket)))
}

/// # Safety
/// Live handle, valid command and writable response pointer (or NULL).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn melonx_owned_debug_command(session: *const OwnedSession,
    mode: u8, command: *const c_char, response: *mut *mut c_char) -> i32 {
    if !response.is_null() { unsafe { *response = std::ptr::null_mut() }; }
    if session.is_null() || command.is_null() { return 5 }
    let Ok(command) = unsafe { CStr::from_ptr(command) }.to_str() else { return 5 };
    if command.len() > 65_536 { return 5 }
    let mode = match mode { 0 => CommandMode::Command, 1 => CommandMode::Raw, 2 => CommandMode::Read, _ => return 5 };
    match unsafe { &*session }.perform(mode, command.to_owned()) {
        Ok(text) => {
            let Ok(text) = CString::new(text) else { return 5 };
            if !response.is_null() { unsafe { *response = text.into_raw() }; }
            0
        }
        Err(error) => match error { SessionError::Cancelled => 2, SessionError::TimedOut => 3,
            SessionError::Ended => 4, SessionError::Busy => 6, SessionError::Transport => 5 },
    }
}

/// # Safety
/// Live handle. This function touches only the Send+Sync cancellation state; never transport pointers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn melonx_owned_debug_cancel(session: *const OwnedSession) -> i32 {
    if session.is_null() { return 0 }
    let session = unsafe { &*session };
    let waiting = session.diagnostic_waiting.as_ref().is_some_and(|flag| flag.load(Ordering::SeqCst));
    session.cancel();
    i32::from(waiting)
}

/// # Safety
/// NULL or a handle with no concurrent command/cancel calls. Cancels and joins the
/// owner before freeing controller memory; calling it is NOT transport acknowledgement until it returns.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn melonx_owned_debug_free(session: *mut OwnedSession) {
    if !session.is_null() { drop(unsafe { Box::from_raw(session) }); }
}

/// # Safety
/// NULL or string allocated by melonx_owned_debug_command; free exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn melonx_owned_debug_string_free(string: *mut c_char) {
    if !string.is_null() { drop(unsafe { CString::from_raw(string) }); }
}

/// # Safety
/// Live handle; after returning, the runtime/transport owner has been joined.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn melonx_owned_debug_finish(session: *const OwnedSession) -> i32 {
    if session.is_null() { return 5 }
    let session = unsafe { &*session };
    session.cancel();
    match session.join() { Ok(()) => 0, Err(_) => 5 }
}

#[unsafe(no_mangle)]
pub extern "C" fn melonx_owned_debug_diagnostic_new() -> *mut OwnedSession {
    let waiting = Arc::new(AtomicBool::new(false));
    let owner_waiting = waiting.clone();
    let mut session = OwnedSession::spawn(move |mut commands, _cancel| async move {
        if let Some(request) = commands.recv().await {
            struct Waiting(Arc<AtomicBool>);
            impl Drop for Waiting { fn drop(&mut self) { self.0.store(false, Ordering::SeqCst); } }
            owner_waiting.store(true, Ordering::SeqCst);
            let guard = Waiting(owner_waiting);
            std::future::pending::<()>().await;
            // Retain the receiver, queued request and marker until actual task disposal.
            drop(request); drop(commands); drop(guard);
        }
    });
    session.diagnostic_waiting = Some(waiting);
    Box::into_raw(Box::new(session))
}
