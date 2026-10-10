// SPDX-License-Identifier: MPL-2.0
//! One runtime thread owns transport state. Cancellation shares only atomics and
//! a wakeup, never a proxy, socket, adapter pointer, or mutable borrow.
use std::future::Future;
use std::sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}, mpsc as sync_mpsc};
use std::thread::JoinHandle;
use std::time::Duration;
use tokio::sync::{Notify, mpsc};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionError { Cancelled, TimedOut, Ended, Busy, Transport }

#[derive(Default)]
pub struct Cancellation { requested: AtomicBool, wake: Notify }
impl Cancellation {
    pub fn cancel(&self) {
        self.requested.store(true, Ordering::SeqCst);
        self.wake.notify_one();
    }
    pub fn is_cancelled(&self) -> bool { self.requested.load(Ordering::SeqCst) }
    async fn wait(&self) {
        if self.is_cancelled() { return }
        self.wake.notified().await;
    }
}

pub async fn interruptible<T>(cancel: &Cancellation, future: impl Future<Output = T>, deadline: Duration)
    -> Result<T, SessionError> {
    tokio::select! {
        biased;
        _ = cancel.wait() => Err(SessionError::Cancelled),
        _ = tokio::time::sleep(deadline) => Err(SessionError::TimedOut),
        result = future => Ok(result),
    }
}

#[derive(Clone, Copy)]
pub enum CommandMode { Command, Raw, Read }

pub struct Command {
    pub mode: CommandMode,
    pub text: String,
    pub reply: sync_mpsc::SyncSender<Result<String, SessionError>>,
}

pub struct OwnedSession {
    commands: mpsc::Sender<Command>,
    cancel: Arc<Cancellation>,
    ended: Arc<AtomicBool>,
    worker: Mutex<Option<JoinHandle<()>>>,
    diagnostic_waiting: Option<Arc<AtomicBool>>,
}

impl OwnedSession {
    /// The factory is sent, but its future and transport are CREATED and retained
    /// inside the owner thread; non-Send adapter state never leaves that thread.
    pub fn spawn<F, Work>(factory: F) -> Self
    where F: FnOnce(mpsc::Receiver<Command>, Arc<Cancellation>) -> Work + Send + 'static,
          Work: Future<Output = ()> + 'static {
        let (commands, receiver) = mpsc::channel(1);
        let cancel = Arc::new(Cancellation::default());
        let owner_cancel = cancel.clone();
        let ended = Arc::new(AtomicBool::new(false));
        let owner_ended = ended.clone();
        // The real authenticated-connect future overflows the default 2 MiB
        // owner stack in unoptimized builds; the public FFI regression covers it.
        let worker = std::thread::Builder::new().name("melonx-jit-owner".into())
            .stack_size(8 * 1024 * 1024).spawn(move || {
            struct Ended(Arc<AtomicBool>);
            impl Drop for Ended { fn drop(&mut self) { self.0.store(true, Ordering::SeqCst); } }
            // Declared before runtime/executor: drops last, including during unwind.
            let _ended = Ended(owner_ended);
            if let Ok(runtime) = tokio::runtime::Builder::new_current_thread().enable_all().build() {
                let local = tokio::task::LocalSet::new();
                local.block_on(&runtime, async {
                    let work = factory(receiver, owner_cancel.clone());
                    // Cancel also covers an idle mailbox or an unfinished connect,
                    // not only individual command reads inside the factory.
                    let _ = interruptible(&owner_cancel, work, Duration::from_secs(300)).await;
                });
                // LocalSet drops spawn_local tasks; Runtime then drops all
                // tokio::spawn adapter/reader tasks and their owned sockets.
                drop(local);
                drop(runtime);
            }
        }).expect("could not create JIT transport owner");
        Self { commands, cancel, ended, worker: Mutex::new(Some(worker)), diagnostic_waiting: None }
    }
    pub fn command(&self, text: String) -> Result<String, SessionError> {
        self.perform(CommandMode::Command, text)
    }
    pub fn perform(&self, mode: CommandMode, text: String) -> Result<String, SessionError> {
        if self.cancel.is_cancelled() { return Err(SessionError::Cancelled) }
        if self.has_ended() { return Err(SessionError::Ended) }
        if text.len() > 65_536 { return Err(SessionError::Transport) }
        let (reply, receiver) = sync_mpsc::sync_channel(1);
        self.commands.try_send(Command { mode, text, reply }).map_err(|e| match e {
            mpsc::error::TrySendError::Full(_) => SessionError::Busy,
            mpsc::error::TrySendError::Closed(_) => SessionError::Ended,
        })?;
        match receiver.recv_timeout(Duration::from_secs(30)) {
            Ok(result) => result,
            Err(sync_mpsc::RecvTimeoutError::Timeout) => { self.cancel(); Err(SessionError::TimedOut) }
            Err(_) => Err(if self.cancel.is_cancelled() { SessionError::Cancelled } else { SessionError::Ended }),
        }
    }
    pub fn cancel(&self) { self.cancel.cancel(); }
    pub fn has_ended(&self) -> bool { self.ended.load(Ordering::SeqCst) }
    /// Only joining the owner certifies transport disposal. A cancellation signal
    /// is never a teardown acknowledgement.
    pub fn join(&self) -> Result<(), SessionError> {
        let mut worker = self.worker.lock().map_err(|_| SessionError::Transport)?;
        if let Some(worker) = worker.take() { worker.join().map_err(|_| SessionError::Transport)?; }
        Ok(())
    }
}
impl Drop for OwnedSession {
    fn drop(&mut self) { self.cancel(); let _ = self.join(); }
}

#[cfg(test)]
mod tests;

mod debug_transport;
mod ffi;
