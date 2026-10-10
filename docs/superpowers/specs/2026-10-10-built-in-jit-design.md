# Built-in JIT for MeloNX

## Intent and approval state

The user wants the installed MeloNX application to acquire JIT itself, following
Madeira's built-in StikJIT approach. They approved the conversational scope on
2026-10-10: built-in setup, iPadOS 27 self-pairing, pairing-file import, an
independent helper extension, automatic acquisition before gameplay, progress,
errors and retry, and an update of 房栋的iPad that preserves application data.

The user approved this written design on 2026-10-10. Product implementation and
dependency installation have not started. The separately reviewable implementation
plan is the next workflow gate; its execution method has not yet been selected.

## Current evidence

- The target is an iPad Pro 11-inch M5, iPadOS 27.0, with Developer Mode enabled.
  MeloNX 2.6 is installed under `com.hick.MeloNX`.
- A current device screenshot shows `JIT Not Acquired` and Increased Memory
  Limit enabled. StikDebug is absent from the inspected application list.
- The installed development signature permits `get-task-allow` and increased
  memory. Signature checks must be repeated on the replacement app and helper.
- MeloNX already exposes external JIT providers in `EnableJIT.swift`, waits for
  JIT in `NoJITView.swift`, and calls `Ryujinx.initDualMapping()` through
  `RyujinxController.attemptToMapDualMapping()`.
- Its external script includes universal and legacy breakpoint handlers. Source
  compatibility with StikJIT's universal script is plausible, but has not been
  demonstrated on this device. A debugger flag alone is not runtime proof.
- Madeira uses a classic helper `.appex` and StikJIT 1.9.0. Its Wine-specific
  script is unsuitable for MeloNX. The existing Madeira installation must remain
  independent of this work.
- This checkout requires .NET 10. The previously inspected local installation
  supplied .NET 9 only. A successful source build is still outstanding.

## Chosen architecture

Use an independent helper extension containing StikJIT. The main application
owns setup, credentials and status, and sends one request to the helper with
its own PID and pairing bytes. The helper owns its DDI cache and debugger
connection. The host retains the extension request for the operation's lifetime.

The other approaches considered are continued external StikDebug activation,
which does not provide the requested built-in flow, and attaching from the main
process itself, which can deadlock. The helper approach matches the upstream
integration guide and separates blocking debugger work from the target process.

Use StikJIT's developer-selected universal script after proving it matches the
MeloNX allocator. Do not copy Madeira's `madeira-jit.js`, make script selection
a user preference, or change the CPU/GPU emulation design as part of integration.

## Components and boundaries

### Host coordinator

Add a main-actor coordinator in MeloNX's JIT area. It owns a single active
operation, progress, cancellation, deadlines and a generation/token identifying
the request. Late replies from a cancelled or superseded request are ignored.
Repeated enable taps reuse or reject the active operation rather than launching
multiple helpers. Pairing replacement invalidates an active preparation attempt.

The coordinator checks host `get-task-allow`, supported OS version, readable and
valid pairing data, helper installation and loopback reachability before JIT
acquisition. Missing setup opens setup and does not start gameplay.

### Helper and messages

Add `MeloNXJITHelper` as a classic app extension using the proven
`com.apple.ar.viewer` extension point and a non-user-visible activation rule.
Activate it through the private NSExtension host interface, resolving its actual
installed bundle ID from the embedded extension. For this device, sign the host
as `com.hick.MeloNX` and helper as `com.hick.MeloNX.JITHelper` with the same team.

Define narrowly scoped versioned terminal request/reply messages for prepare,
enable and reset-DDI, including an operation ID, target PID, pairing data and
result. Use Madeira's terminal NSExtension transport initially; do not promise
streaming IPC that it does not supply. The host displays coarse operation stages
and elapsed time. Detailed preparation callbacks are sanitized helper logs,
not a fictional live percentage in the host. Reject unsupported operations,
invalid PIDs, malformed replies and
oversized input. Only the coordinator supplies the host PID; this is not a
general-purpose debugger UI for other applications.

The helper writes pairing bytes to a protected, randomly named temporary plist,
uses it for that operation, and removes it on completion or failure. Long-lived
credentials stay in the host's Keychain. No App Group or shared Keychain group
is needed. The helper serializes debugger operations and retains its extension
request until the debugger task ends. StikJIT 1.9.0's prepare/enable APIs are
synchronous and have no public cancellation handle. A cancellation command must
not be queued behind that blocking call. On cancel, invalidate the pending game
launch immediately and request cancellation through the extension host API.
Track stopping separately from confirmed teardown. No retry, credential
replacement or second debugger session is allowed until the worker/extension
has terminated and the target is no longer traced, or normal protocol detach
and terminal completion have been observed. Never kill the host application.

Before building the product flow, verify on the device that cancelling this
extension type actually releases its blocked debugger operation. A cancelled
completion callback alone is insufficient evidence. If the OS does not terminate
the worker, stop integration at this proof gate and add an interruptible debugger
operation in the pinned StikJIT source, with socket/resource ownership and tests,
before exposing retry. Do not claim that the current framework can cancel a
running synchronous operation.

### Pairing and network

Store the host's pairing record in Keychain with
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Import accepts the supported
remote-pairing plist format, validates required fields, uses security-scoped
file access, and replaces the record only after successful validation. Invalid
imports preserve the existing record. Never log credentials or include them in
source, build artifacts, diagnostic exports or an IPA.

On iPadOS 27, adapt the proven idevice-based local pairing bridge: a TCP listener
advertised through DNSServiceRegister, host name `MeloNX`, and a native Settings
pairing/PIN confirmation performed by the user. Use idevice 0.1.68 and a pinned
Rust lockfile as the initial reference implementation. Support cancellation and
a five-minute deadline. Stop advertisement and free bridge resources on every
terminal path. Where the continued-processing background task cannot be
scheduled, explain the shortened background window instead of claiming pairing
will continue indefinitely. Older supported systems use pairing-file import.

LocalDevVPN remains required. Probe the VPN route and then the device loopback
service before preparation; another VPN or a generic successful TCP connection
must not be treated as a valid loopback route. Provide an explicit LocalDevVPN
open/connect action and guidance. Initial implementation does not automate
cellular settings, other VPNs or the Madeira Shortcuts workflow.

### DDI and readiness

Cache DDI assets in the helper's Library directory. Log sanitized upstream
preparation progress and allow an explicit cache reset for stale files after OS
updates. The host reports preparation as an indeterminate stage, because its
initial extension transport delivers a terminal result rather than a live
download percentage.
No gameplay begins while DDI preparation or executable-region mapping is pending.

Keep TXM unknown distinct from false. In the TXM path, the host waits for
`CS_DEBUGGED` before making breakpoint-based mapping requests. Run the matching
script, complete the required dual mapping, and confirm the protocol's successful
completion before reporting ready. Reconcile the helper outcome with the host's
actual `jitEnabled()`/mapping result; extension launch, debugger attachment and
successful IPC do not individually count as JIT readiness.

Run mapping on a serialized, non-main worker. The main-actor coordinator only
updates UI and schedules work; it must not invoke `jitEnabled()` or
`initDualMapping()` as a polling predicate, because those calls can synchronously
execute breakpoints. A lightweight debugger-state probe must have no allocator
side effects. After actual attachment is established, submit one owned mapping
operation, then publish its result back to the coordinator if its operation ID
is still current. Cancellation stops that operation's game-launch continuation;
retry waits for the mapping worker and debugger teardown acknowledgement.
Observe current tracing through the platform's process tracing state and owned
helper/worker lifetime; persistent `CS_DEBUGGED` alone cannot establish current
attachment or teardown. If that tracing probe is unavailable on this OS, treat
teardown as unverified and prohibit a replacement session until an equivalent
owned-operation termination check has been demonstrated.

The initial sequence is explicit: attach and observe debugger state, run the
mapping worker, prepare all required executable allocations including the native
signal-handler code block, execute the allocator's `BreakJITDetach`, receive the
helper terminal result, then mark ready. Source currently initializes its shared
cache and native signal-handler code during this path. Trace all allocator users
and prove that subsequent game starts allocate from the prepared pool without
new unserviced breakpoint calls. Validate a second game launch in the same host
process; cached `hasScript` must not conceal a lost session or unprepared region.

Retain safe signal handling on failure. If later TXM allocations are discovered,
automatic launch remains blocked until acquisition is explicitly routed through
the coordinator again before those allocations. Do not detach early and rely on
the cached Boolean to make later allocation appear ready.

## User flow

Add `Built-in StikJIT` to the current JIT provider selector and a setup page in
the same settings section. The page offers pair this device on iPadOS 27,
import/replace pairing file, prepare device, enable JIT, reset DDI and retry.
Show pairing, VPN, preparation and JIT state without exposing key material.

Preserve existing explicitly selected providers. For a new installation,
prefer built-in on supported OS versions. Existing installations with None offer
the built-in setup when JIT is needed instead of silently looping forever.

Use the same coordinator for settings, library launches and game deep links.
The wait-for-JIT screen shows bounded progress and offers retry and go back.
Replace its unowned detached infinite polling with cancellation tied to the
view/launch request. Leaving the screen cancels that launch; a late successful
reply cannot start the old game. Existing external-provider paths continue to
work and remain available as fallback.

## State and deadlines

Use explicit states: needs setup, pairing, checking network, preparing device,
attaching, mapping, stopping, ready, failed and cancelled. Ready is process-scoped and
must be re-evaluated after app restart or helper interruption.

Pairing expires after 300 seconds. Initial loopback connection uses the
upstream five-second connect limit and a bounded route-readiness retry window.
JIT attach/mapping has a 90-second deadline, which triggers stopping rather than
pretending the blocked native work has ended. DDI preparation has a separate
ten-minute operation deadline; it displays an indeterminate stage and elapsed
time, with cancellation subject to the same verified teardown rule. Failure
invalidates the launch request immediately and permits retry only after confirmed
teardown, without removing game data.

## Build, signing and compatibility

Keep the host's existing minimum OS support. Gate built-in features to iOS 26+
initially, matching the known Madeira integration; gate self-pairing to iOS 27+.
Load StikJIT from the helper, not through an unconditional host import. Ensure
older systems can still open MeloNX and use their existing external providers.

Embed and sign the framework and helper with the app. Madeira's pinned StikJIT
framework lacks a framework Info.plist in its source bundle; generate the
required metadata during embedding and use the correct helper runpath to the
app Frameworks directory. Include local-network/Bonjour declarations and
correct bundle-specific background-task identifiers for self-pairing.

Start with a normal source build, installing the required .NET SDK into an
isolated local directory and keeping build output off unrelated user files.
Do not silently substitute a release emulator binary and call it a full source
build. If an unavailable dependency or source incompatibility blocks compilation,
report the exact evidence and proposed fallback before changing that boundary.

Update the currently installed bundle in place to preserve Documents, firmware,
keys, games and saves. Inspect device data before the update and after it; never
uninstall the application as an installation workaround. Preserve the previous
signed artifact and prepare a new signed IPA for review.

## Licensing and provenance

Pin the reference StikJIT 1.9.0 artifact to upstream SHA-256
`806664393770c68e75f2b6429955bfdd88cfaad09fec2ba70f8ed615ff90c060` and record its
source tag and MPL-2.0 notice. Retain idevice MIT notices. Any adapted Madeira
host/helper/pairing wrapper code keeps its GPL-3.0-or-later copyright and license
headers and corresponding-source information. Include the pinned Rust
dependencies' license notices with distributed artifacts. No publication or
external upload is part of this task.

## Validation and completion

1. Before integration, prove the existing MeloNX allocator can acquire JIT with
   the matching external universal handler on the target device. If it cannot,
   diagnose and make only the allocator/protocol changes required by this design.
2. Add focused tests for coordinator transitions: signing/setup rejection,
   invalid import preserves old credentials, duplicate requests, retry,
   cancellation, timeout, interruption and stale replies cannot start gameplay.
3. Build the host, helper and pairing bridge; verify nested signatures,
   entitlements, linkage, deployment gates and bundled license notices.
4. On 房栋的iPad, complete self-pairing with the user's system confirmation,
   prepare DDI, enable built-in JIT and inspect the actual status screen. Verify
   mapping success and debugger lifecycle, including app restart and retry.
5. Exercise VPN unavailable and pairing-invalid failures, deliberately cancel and
   time out while native mapping is blocked, confirm debugger/worker teardown,
   retry, launch a second game in the same process, and confirm existing data
   and the independent Madeira app remain.
6. Run a small JIT execution probe or a user-provided playable workload. A green
   status alone does not establish code execution or game compatibility. If no
   workload is available, distinguish proven mapping/JIT-probe results from
   untested gameplay.

Completion requires a working signed installation and real device evidence for
the built-in path. User-only system pairing steps or an unavailable build/device
capability are reported as concrete blockers, not successful implementation.

## References

- [Madeira](https://github.com/willfaust/Madeira), local inspected checkout at
  `/Volumes/untitled/github/Madeira`, especially `docs/JIT.md`,
  `app/Madeira/JITBuiltInHost.swift`, `JITBuiltInMessages.swift`, `JITSetup.swift`,
  `JITPairing.swift`, `app/MadeiraJITHelper` and `build/rppairing-ios`.
- [StikJIT integration guide](https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md).
- [StikJIT 1.9.0](https://github.com/StikDebug/StikJIT/releases/tag/1.9.0).
- Local MeloNX paths: `Common/JIT/EnableJIT.swift`, `Common/JITChecker.swift`,
  `Core/RyujinxController.swift`, `UI/Main/NoJITView.swift`,
  `UI/Main/ContentView.swift` and `UI/Main/Settings/SettingsView.swift` under
  `src/MeloNX/MeloNX`.
