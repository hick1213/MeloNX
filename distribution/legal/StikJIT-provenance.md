MeloNX uses a cancellation adaptation of StikJIT 1.9.0 (MPL-2.0).

Upstream: https://github.com/StikDebug/StikJIT
Pinned tag commit: 32287268fa5824f9edce4cb359f5833ce0cf7b00
Original artifact: https://github.com/StikDebug/StikJIT/releases/download/1.9.0/StikJIT.xcframework.zip
Original SHA-256: 806664393770c68e75f2b6429955bfdd88cfaad09fec2ba70f8ed615ff90c060
The original ZIP is retained unchanged for comparison; the app links the source-built adaptation only through its helper.

Modified source: distribution/ios/stikjit-fork (upstream MPL notice retained).
Owned debugger: distribution/ios/jit-session; Cargo.lock pins idevice0.1.68 and jktcp0.1.7. The debugger uses public Rust APIs on a dedicated current-thread runtime. Cancellation shares only an atomic flag/wakeup; the worker disposes adapter/reader tasks, drops its runtime and joins before a successful teardown acknowledgement. A nonce-scoped Darwin signal carries no credential bytes. ScriptRunner aborts on transport failure instead of looping over empty responses.

Build: distribution/ios/stikjit-fork/build.sh. Official upstream DDI preparation still uses its bundled idevice FFI and synchronous APIs. None of those mutable opaque handles is shared across cancellation threads. Preparation cancellation invalidates the launch and retains the operation lease until actual completion; immediate preparation interruption is not claimed.

App Resources includes MPL-2.0, idevice MIT and crate notices. Madeira adaptations retain GPL-3.0-or-later attribution and distribution/legal/Madeira-JIT-EXCEPTION.md. Actual debugger detach, native execution and repeated game launch require separate physical-device proof; passing source/runtime ownership tests is not that proof.
