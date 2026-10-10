# Built-in StikJIT Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add built-in StikJIT, pairing and automatic JIT acquisition to MeloNX, then update 房栋的iPad in place and demonstrate executable JIT memory without losing application data.

**Architecture:** The host owns credentials, a main-actor coordinator and a serialized non-main mapping worker. A separate classic helper extension owns StikJIT and its DDI/debugger lifecycle; terminal IPC results and actual worker/tracing state jointly determine completion. iPadOS 27 pairing uses a pinned idevice Rust bridge and user-confirmed system pairing.

**Tech Stack:** Swift/SwiftUI, Foundation-only Swift package with XCTest, Security Keychain, private NSExtension SPI, StikJIT 1.9.0, Rust/idevice 0.1.68, .NET 10 NativeAOT, Xcode and devicectl.

**Spec:** `docs/superpowers/specs/2026-10-10-built-in-jit-design.md` — user approved the written design on 2026-10-10. Read both documents before execution.

## Global Constraints

- Gate built-in features to iOS 26+ initially; gate self-pairing to iOS 27+.
- Keep the host's existing minimum OS support (`IPHONEOS_DEPLOYMENT_TARGET = 15.0` in the app target); the new helper has a supported, separately gated deployment floor.
- Sign this device's host as `com.hick.MeloNX` and helper as `com.hick.MeloNX.JITHelper` with the same team.
- LocalDevVPN remains required. Initial implementation does not automate cellular settings, other VPNs or the Madeira Shortcuts workflow.
- Store the host's pairing record in Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; never log credentials or include them in source, build artifacts, diagnostic exports or an IPA.
- No App Group or shared Keychain group is needed.
- Use StikJIT's developer-selected universal script after proving it matches the MeloNX allocator. Do not copy Madeira's `madeira-jit.js` or make script selection a user preference.
- Pairing expires after 300 seconds. JIT attach/mapping has a 90-second deadline. DDI preparation has a separate ten-minute operation deadline.
- A cancelled completion callback alone is insufficient evidence. No retry, credential replacement or second debugger session is allowed until the old operation has terminated.
- A debugger flag alone is not runtime proof. Mapping stays on a serialized, non-main worker, and status polling has no allocator side effects.
- Pin StikJIT 1.9.0 to archive SHA-256 `806664393770c68e75f2b6429955bfdd88cfaad09fec2ba70f8ed615ff90c060`; pin idevice to `=0.1.68` and retain license notices.
- Start with a normal source build. Do not silently substitute a release emulator binary and call it a full source build.
- Update the currently installed bundle in place. Never uninstall the application as an installation workaround. Preserve the independent Madeira application.
- No publication or external upload is part of this task.
- Every command below is planned work, not an executed or passing check. Save actual outputs during execution and stop at a failed proof gate.

## Review Focus

1. Cancel/timeout during a native breakpoint must keep the UI responsive, prevent game launch, and prevent retry while the old worker/debugger is alive: Tasks 2 and 5.
2. A completion from an older attempt or a second game launch in the same process must not reuse invalid readiness or start a cancelled game: Tasks 2, 5 and 7.
3. Malformed/oversized pairing input and an iOS-update-stale DDI must preserve valid credentials and expose a recoverable failure: Tasks 2, 3 and 4.
4. Missing/renamed helper, stripped signing entitlement, unsupported OS or LiveContainer must report an unavailable built-in path while preserving external providers: Tasks 4, 6 and 7.
5. A different VPN, no route, background expiration or a silent pairing peer must not appear paired/JIT-ready: Tasks 3, 6 and 7.

## File ownership and dependency order

Execute sequentially because the shared Xcode project, coordinator and mapping protocol are tightly coupled. Initial order is Task 1 steps 1–6, Tasks 2–3, then Task 1's external-handler proof if it needed pairing, followed by Tasks 4–7. If subagent-driven execution is selected, give each task exclusive ownership of its listed files, and tell every worker it is not alone and must preserve other edits. Use read-only review agents between tasks rather than concurrent writers to the project file.

- Task 1 owns build selection and baseline evidence.
- Task 2 owns a small Foundation-only `MeloNXJITCore` package: protocol, pairing validation and deterministic session state.
- Task 3 owns Keychain/network/self-pairing adapters and the Rust bridge.
- Task 4 owns the classic extension, terminal host transport and Xcode/framework integration.
- Task 5 owns the mapping worker, debugger-state probe and coordinator.
- Task 6 owns existing app entry points and setup/wait UI.
- Task 7 owns device validation, final installation and delivery documentation.

### Task 1: Establish an isolated source-build and allocator baseline

**Files:**
- Modify: `distribution/ios/build.sh` only if explicit SDK selection is necessary.
- Read: `global.json`, `nuget.config`, `Directory.Build.props`, `src/Ryujinx.Library/Ryujinx.Library.csproj`.
- Read: `src/Ryujinx.Cpu/LightningJit/Translator.cs` (`DualMappedMemory`), `src/Ryujinx.Cpu/LightningJit/Cache/DualMappedNoWxCache.cs`, `src/Ryujinx.Memory/MemoryBlock.cs`, `src/Ryujinx.Memory/DualMappedJitAllocator.cs`, `src/Ryujinx.Library/UnmanagedPassthrough.cs`, `src/Ryujinx.Cpu/Signal/NativeSignalHandler.cs`, and `src/ARMeilleure/Signal/NativeSignalHandlerGenerator.cs`.
- Record: `docs/superpowers/verification/2026-10-10-built-in-jit-baseline.md`.
- Store local artifacts: `/Users/hick/Downloads/MeloNX-built-in-JIT/`; no pairing or keys in this evidence directory.

**Interfaces:**
- Consumes: existing `init_dualmapping` export and `Ryujinx.initDualMapping() -> Bool`.
- Produces: a reproducible source build command and an observed allocator lifecycle used by Task 5; no new runtime API yet.

- [ ] **Step 1: Create the isolated checkout at execution time.** Use `superpowers:using-git-worktrees`, starting from the approved design commit and carrying this plan. Confirm repository and parent instructions, `git status --short`, disk capacity, signing identity and device availability. Keep `.planning/ipad-install` in the original checkout as session state; do not overwrite it from another task.
- [ ] **Step 2: Reproduce the SDK failure and save its exact output.**

```bash
dotnet --list-sdks
dotnet publish -c Release -r ios-arm64 -p:ExtraDefineConstants=DISABLE_UPDATER src/Ryujinx.Library --self-contained true
```

Expected before SDK setup: the repository-required SDK cannot be selected if only .NET 9 remains installed. If .NET 10 now exists, use that current evidence instead of replaying a stale failure.

- [ ] **Step 3: Install a task-local .NET SDK using Microsoft's official installer after reading it.** Keep the installed runtime at `/Users/hick/Downloads/MeloNX-build-tools/dotnet10`, version `10.0.100` initially, compatible with `global.json`. Do not change system dotnet or shell startup files. Run the selected binary's `--info` and the publish command above. If the iOS NativeAOT runtime pack or package source fails, record the precise package/URL/error; do not substitute a release binary.
- [ ] **Step 4: If the legacy Xcode build ignores the selected SDK, add an explicit override with a focused shell check.** The selection contract is:

```bash
DOTNET="${MELONX_DOTNET:-$(command -v dotnet || true)}"
if [ -z "$DOTNET" ] || [ ! -x "$DOTNET" ]; then
  echo "dotnet not found" >&2
  exit 1
fi
"$DOTNET" publish -c Release -r ios-arm64 -p:ExtraDefineConstants=DISABLE_UPDATER src/Ryujinx.Library --self-contained true
```

Keep compatible existing fallback paths if still needed. Exercise a temporary stub executable that records arguments, plus a missing executable, before relying on the override; verify `bash -n distribution/ios/build.sh`. Avoid unrelated shell-script cleanup.
- [ ] **Step 5: Build the existing iOS app from source with the selected SDK and current development signature.**

```bash
MELONX_DOTNET=/Users/hick/Downloads/MeloNX-build-tools/dotnet10/dotnet \
xcodebuild -project src/MeloNX/MeloNX.xcodeproj -scheme MeloNX -configuration Release \
  -destination 'id=00008142-0001785A3E20401C' \
  -derivedDataPath /Users/hick/Downloads/MeloNX-built-in-JIT/baseline-build \
  DEVELOPMENT_TEAM=KWP42AEP6Q PRODUCT_BUNDLE_IDENTIFIER=com.hick.MeloNX \
  -allowProvisioningUpdates build
```

Passing output must identify a freshly compiled Ryujinx native library and host executable. Keep the already installed IPA unchanged until an installable replacement is verified.
- [ ] **Step 6: Trace the existing allocator and reference handler.** Disassemble `BreakpointJIT.framework/BreakpointJIT` with `xcrun llvm-objdump --disassemble`; identify actual breakpoint commands/registers. Trace shared cache allocation, signal-handler executable allocation and `BreakJITDetach`, and enumerate subsequent allocation callers. Record which calls happen before and after detach. Compare against pinned StikJIT universal handler source, including its legacy compatibility branches.
- [ ] **Step 7: Establish the external-handler device proof before enabling product auto-launch.** Use the official StikDebug reference app or an isolated reference helper process with the pinned universal handler, target only MeloNX, and record attachment, mapping, detach and a known ARM64 execution result. If pairing setup is needed, perform Task 3's pairing preparation first and return here. User-only Settings/PIN confirmation is a real handoff. A failure keeps the automatic-launch gate closed and is diagnosed before continuing Task 5.
- [ ] **Step 8: Record evidence and commit only the necessary build change and baseline document.** Label source-only allocator traces separately from actual runtime evidence; no unexecuted check is marked passed.

### Task 2: Build deterministic shared state, messages and validation with tests

**Files:**
- Create: `src/MeloNX/MeloNXJITCore/Package.swift`.
- Create: `src/MeloNX/MeloNXJITCore/Sources/MeloNXJITCore/JITSessionState.swift`.
- Create: `src/MeloNX/MeloNXJITCore/Sources/MeloNXJITCore/JITMessages.swift`.
- Create: `src/MeloNX/MeloNXJITCore/Sources/MeloNXJITCore/PairingRecord.swift`.
- Create: `src/MeloNX/MeloNXJITCore/Sources/MeloNXJITCore/JITDependencies.swift` for Foundation-only adapter protocols introduced by Tasks 3–5.
- Create tests under `src/MeloNX/MeloNXJITCore/Tests/MeloNXJITCoreTests/` for those three files.

**Interfaces:**

```swift
public enum JITPhase: String, Codable, Sendable {
    case idle, needsSetup, checkingNetwork, preparing, attaching, mapping
    case stopping, ready, failed, cancelled
}
public enum JITOperation: String, Codable, Sendable { case prepare, enable, resetDDI }
public struct JITRequest: Codable, Sendable {
    public let version: Int                 // exactly 1
    public let operationID: UUID
    public let operation: JITOperation
    public let targetPID: Int32?
    public let pairingData: Data?
    public init(version: Int, operationID: UUID, operation: JITOperation,
                targetPID: Int32?, pairingData: Data?)
    public func validated() throws -> JITRequest
}
public struct JITReply: Codable, Sendable {
    public let version: Int                 // exactly 1
    public let operationID: UUID
    public let success: Bool
    public let message: String
    public let txmPresent: Bool?
    public init(version: Int, operationID: UUID, success: Bool,
                message: String, txmPresent: Bool?)
}
public struct PairingRecord: Sendable {
    public let data: Data
    public init(validating data: Data) throws
}
public struct JITSessionState: Sendable {
    public private(set) var phase: JITPhase
    public private(set) var activeID: UUID?
    public private(set) var pendingLaunchID: UUID?
    public var canRetry: Bool { get }
    public var allowedLaunchID: UUID? { get }
    public init()
    public mutating func begin(pid: Int32, launchID: UUID?) throws -> UUID
    public mutating func transition(id: UUID, to phase: JITPhase) -> Bool
    public mutating func cancel(id: UUID)
    public mutating func complete(id: UUID, mapped: Bool, helperEnded: Bool,
                                 tracing: Bool?)
}
```

These are declarations for the implementer, not product code already written. Define typed validation errors in the same owning files. The package has no UIKit, StikJIT or credentials-on-disk dependency. Define adapter interfaces in `JITDependencies.swift` as the owning tasks introduce them, so host adapters and the real testable engine use the same types.

- [ ] **Step 1: Write failing XCTest cases for cancellation and stale completion.**

```swift
func testCancelledMappingCannotLaunchOrRetryBeforeTeardown() throws {
    var state = JITSessionState()
    let launch = UUID()
    let id = try state.begin(pid: 123, launchID: launch)
    XCTAssertTrue(state.transition(id: id, to: .mapping))
    state.cancel(id: id)
    state.complete(id: id, mapped: true, helperEnded: false, tracing: true)
    XCTAssertEqual(state.phase, .stopping)
    XCTAssertNil(state.allowedLaunchID)
    XCTAssertFalse(state.canRetry)
    state.complete(id: id, mapped: true, helperEnded: true, tracing: false)
    XCTAssertEqual(state.phase, .cancelled)
    XCTAssertNil(state.allowedLaunchID)
    XCTAssertTrue(state.canRetry)
}

func testUnknownTracingAndOldReplyCannotReportReady() throws {
    var state = JITSessionState()
    let id = try state.begin(pid: 123, launchID: UUID())
    state.complete(id: UUID(), mapped: true, helperEnded: true, tracing: false)
    XCTAssertNotEqual(state.phase, .ready)
    state.complete(id: id, mapped: true, helperEnded: true, tracing: nil)
    XCTAssertNotEqual(state.phase, .ready)
}
```

Also pin duplicate `begin` rejection, invalid PID rejection, failure/retry, timeout using `cancel`, and old completion after a new operation starts. Only the uncancelled matching operation with mapping success, helper end and confirmed tracing state can expose its launch ID.
- [ ] **Step 2: Add message and pairing tests with non-secret fixtures.**

```swift
func testMalformedPairingAndOversizedRequestAreRejected() throws {
    XCTAssertThrowsError(try PairingRecord(validating: Data("not a plist".utf8)))
    let request = JITRequest(version: 1, operationID: UUID(), operation: .enable,
                             targetPID: 123, pairingData: Data(repeating: 0, count: 1_048_577))
    XCTAssertThrowsError(try request.validated())
}
```

Validate remote pairing's required identifier and 32-byte key fields using Madeira's current schema as the reference. Accept its XML/binary plist encodings, not an invented legacy schema. Use generated fixture bytes only. Test unsupported protocol version, unknown JSON operation, mismatched reply operation ID, invalid/missing PID, missing pairing bytes, truncated plist, wrong field types, and reset-DDI rejecting unexpected sensitive payload. Bound encoded request size and pairing size at 1 MiB; bound reply size at 64 KiB.
- [ ] **Step 3: Create the minimal package and run tests red.**

```swift
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "MeloNXJITCore",
    products: [.library(name: "MeloNXJITCore", targets: ["MeloNXJITCore"])],
    targets: [.target(name: "MeloNXJITCore"),
              .testTarget(name: "MeloNXJITCoreTests", dependencies: ["MeloNXJITCore"])])
```

Run `swift test --package-path src/MeloNX/MeloNXJITCore`. Expect missing implementation/behavior failures before implementation.
- [ ] **Step 4: Implement only the defined state/message/validation behavior and run tests green.** Key rule: cancellation invalidates `pendingLaunchID` immediately but keeps `activeID` until teardown; every completion compares its operation ID; `nil` tracing is unknown, never false. Validate bytes without logging them. Run `swift test --package-path src/MeloNX/MeloNXJITCore --enable-code-coverage`; review exercised branches instead of adding tests that merely repeat property assignments.
- [ ] **Step 5: Commit this independently testable package.**

### Task 3: Add secure pairing storage, network checks and iPadOS 27 pairing

**Files:**
- Create under `src/MeloNX/MeloNX/Common/JIT/BuiltIn/`: `JITPairingStore.swift`, `JITNetworkProbe.swift`, `JITDevicePairing.swift`.
- Create: `src/MeloNX/MeloNX/Core/MeloNXRPPairing.h`.
- Modify: `src/MeloNX/MeloNX/Core/MeloNX-Bridging-Header.h` to include that header.
- Create: `distribution/ios/rppairing/{Cargo.toml,Cargo.lock,build.sh,src/lib.rs}` and dependency notices.
- Modify: `src/MeloNX/MeloNX/Info.plist` and third-party notices/license resources.
- Extend package tests: `PairingImportTests.swift`, `NetworkRouteTests.swift`; keep Foundation-only policy helpers in Task 2's package.

**Interfaces:**

```swift
@MainActor public protocol JITPairingStoring {
    func load() throws -> PairingRecord?
    func replace(with data: Data) throws
}
public struct JITNetworkStatus: Sendable {
    public let isReachable: Bool
    public let reason: String?
    public init(isReachable: Bool, reason: String?)
}
public protocol JITNetworkChecking: Sendable {
    func check() async -> JITNetworkStatus
}
@MainActor final class JITDevicePairing: ObservableObject {
    func start() async throws -> PairingRecord
    func cancel()
}
```

Put the public storage/network declarations in Core `JITDependencies.swift`;
`JITKeychainPairingStore` and `JITNetworkProbe` are the iOS adapters. Tests use
those same production interfaces with in-memory/network fakes.

- [ ] **Step 1: Write failing storage/policy tests.** Use an injected in-memory credential backend, not the user's Keychain. Pin “valid old record remains after invalid replacement”, oversize rejection, atomic replacement error leaves old record, non-VPN route rejection, VPN address outside `10.7.*` rejection, and valid route with refused TCP reports unreachable. Add a pairing fake that cancels while a silent peer is connected and returns no record.
- [ ] **Step 2: Implement Keychain ownership and import.** Follow this order:

```swift
let record = try PairingRecord(validating: data) // validate before any update
let service = "\(Bundle.main.bundleIdentifier!).built-in-jit.pairing"
// Update existing generic-password item atomically; add only on errSecItemNotFound.
// Both paths use kSecAttrAccessibleWhenUnlockedThisDeviceOnly.
// Return a typed error for every non-success status; do not remove before update.
```

Use `UIDocumentPicker` security-scoped access, copy bytes into memory under the 1 MiB limit, and call `replace`. No credential values in logs, screenshots, fixtures or diagnostic bundles. Replacement is refused while coordinator teardown is pending.
- [ ] **Step 3: Implement the route/TCP adapter and tests.** Adapt only Madeira's route inspection and bounded probe, requiring a VPN interface with a `10.7.*` address, then a TCP connection to `10.7.0.1:62078`. Use a five-second connect cap and a fifteen-second route-readiness retry window; close the socket on every terminal path. The host opens LocalDevVPN only through an explicit setup action. Return actionable no-route/refused/reset reasons; another VPN's route does not qualify.
- [ ] **Step 4: Adapt the pairing bridge with attribution and a pinned lockfile.** Reuse the inspected Madeira wrapper with `melonx_rppairing_*` symbols and host name `MeloNX`; keep its cancellation/free ordering. Pin the dependency:

```toml
[dependencies]
idevice = { version = "=0.1.68", default-features = false, features = ["remote_pairing", "ring"] }
tokio = { version = "1", features = ["rt", "net", "sync", "macros", "time"] }
```

Expose `new`, `port`, `service_name`, `txt_count/key/value`, `accept`, `cancel`, `free`, `bytes_free` and `string_free` through `MeloNXRPPairing.h`, following the reference C signatures. Never free the session while `accept` is running. Keep per-connection handling and listener cancellation so a silent/garbage connection does not block the real pairing peer.
- [ ] **Step 5: Add iOS 27 advertisement and background handling.** Register `_remotepairing-pairable-host._tcp` with `DNSServiceRegister`, then show the PIN supplied by the bridge. Add local-network/Bonjour keys and `<bundle-id>.pairing.*` permitted background-task identifiers to Info.plist. Register the continued-processing task before submitting it; expiration cancels the Rust listener and deallocates Bonjour after accept returns. The five-minute deadline uses the same path. If scheduling is rejected, show the limited background window. Do not automate the system PIN/security confirmation.
- [ ] **Step 6: Build and verify.** Run `cargo test --manifest-path distribution/ios/rppairing/Cargo.toml --locked`, host policy tests, and `cargo build --manifest-path distribution/ios/rppairing/Cargo.toml --locked --release --target aarch64-apple-ios`. The build script packages `libmelonx_rppairing.a` in ignored build output and regenerates Rust dependency notices. Check with `nm` that symbols match the C header. No simulator claim from an arm64 device-only archive.
- [ ] **Step 7: Inspect the device pairing flow.** Start/cancel pairing, background to Settings, and confirm expiration and silent-peer handling. The user performs Settings pairing and enters the displayed PIN. Store successful bytes only in Keychain. Record whether a cancelled pairing creates no stored record. Complete Task 1's external-handler proof if it depended on pairing.
- [ ] **Step 8: Commit pairing/network changes and notices.**

### Task 4: Integrate the signed helper and prove terminal IPC/teardown

**Files:**
- Create: `src/MeloNX/MeloNXJITHelper/{MeloNXJITHelper.swift,Info.plist}`.
- Create: `src/MeloNX/MeloNX/Common/JIT/BuiltIn/JITExtensionHost.swift`.
- Modify: `src/MeloNX/MeloNX.xcodeproj/project.pbxproj` and shared schemes.
- Create: `distribution/ios/fetch_stikjit.sh`, framework provenance/license metadata.
- Extend: `MeloNXJITCoreTests/JITMessageTests.swift` and a fake transport for Task 5.

**Interfaces:**

```swift
@MainActor public protocol JITHelperSession: AnyObject {
    var operationID: UUID { get }
    var helperPID: Int32? { get }
    func requestCancellation() throws
    func terminalResult() async throws -> JITReply
}
@MainActor public protocol JITHelperStarting {
    func start(_ request: JITRequest) throws -> any JITHelperSession
}
```

`requestCancellation` requests OS cancellation; it never itself certifies teardown. The host retains the session and extension object until a terminal result plus worker-lifetime confirmation. A transport fake controls these facts in tests.
Place these public interfaces in Core `JITDependencies.swift`; the private
NSExtension adapter stays in `JITExtensionHost.swift`.

- [ ] **Step 1: Pin and inspect the upstream artifact.** Download the StikJIT 1.9.0 XCFramework from its official release; verify the exact spec SHA-256 before unpacking into an ignored dependency/build directory. Preserve MPL-2.0/idevice notices and source URL. Inspect the public Swift interface for APIs; do not assume a cancellation API exists.
- [ ] **Step 2: Write transport tests red.** Pin missing helper, malformed/oversized reply, mismatched operation ID, duplicate terminal callbacks, cancellation callback with still-running helper, and renamed installed helper ID. The fake emits cancellation then a late success; assert terminal delivery is once and teardown remains unverified until its worker state changes.
- [ ] **Step 3: Add the classic extension and host terminal transport.** Adapt Madeira's `NSExtension` class/shim and its retained request wrapper with GPL attribution. Read the installed helper ID from `Bundle.main.builtInPlugInsURL/MeloNXJITHelper.appex`, dynamically load ExtensionFoundation when needed, and use its actual request UUID/PID. Verify any cancellation SPI against runtime-supported selectors and headers before invoking it; if unavailable, expose a failed proof gate, not an invented working selector.

Request dispatch in the helper is fixed:

```swift
switch request.operation {
case .prepare:
    let readiness = StikJIT.prepareDevice(pairingFile: pairingURL, paths: paths)
    // Return versioned success/reason and optional TXM state; unknown stays nil.
case .enable:
    try StikJIT.enableJIT(targetPID: validatedPID, pairingFile: pairingURL,
                         ddiPaths: paths, script: .universal, forceScript: true)
case .resetDDI:
    try StikJIT.resetCachedDDI(at: paths)
}
```

All preparation and enable work runs on the helper's serial queue. Create a random protected pairing file in helper Library, remove it with `defer`, and leave DDI cache persistent. Bound request/reply decoding as defined in Task 2; sanitize errors and callback logs. No request-supplied script code.
- [ ] **Step 4: Wire build, runtime paths and signing.** Link `MeloNXJITCore` into host/helper, StikJIT only into helper, and embed/sign its framework in the parent app Frameworks with helper runpath `@executable_path/../../Frameworks`. Generate framework Info.plist if absent; embed helper in PlugIns and create its same-team development profile. Verify `NSExtensionPointIdentifier=com.apple.ar.viewer`, `FALSEPREDICATE` activation and the principal class. The host remains iOS 15-compatible and built-in use is gated to physical-device iOS 26+.
- [ ] **Step 5: Prove cancellation before shipping a retry UI.** Use an isolated blocked helper operation, get its actual PID, request cancellation and inspect helper lifetime and the host's current tracing state. Then run actual StikJIT attach/mapping with a controlled blocked mapping test and repeat. Cancellation/interruption callbacks alone do not pass. Record whether the helper and debug connection end, host survives, temp credentials disappear and no mapping worker stays blocked.
- [ ] **Step 6: Enforce the failure branch.** If OS request cancellation fails to release the synchronous framework operation, keep retry disabled and stop the product-flow integration. Before continuing, implement an owned interruptible operation in the pinned StikJIT source with cancellation closing the owned transport exactly once, and tests for close versus blocked-read races. Rebuild, record source/hash/license changes and rerun the same device proof. A host-process kill is not an acceptable substitute.
- [ ] **Step 7: Run package tests, physical-device Xcode build, `codesign --verify --deep --strict` and `otool -L` on the helper.** Inspect host get-task-allow and increased-memory-limit, helper identity and dynamic paths. Verify older-system/LiveContainer unavailability reports rather than relying on a simulator to prove actual helper startup.
- [ ] **Step 8: Commit only the helper/transport/framework integration and licensing records after the teardown proof passes.**

### Task 5: Add the non-main mapping worker and owned coordinator

**Files:**
- Create under `src/MeloNX/MeloNX/Common/JIT/BuiltIn/`: `JITDebuggerProbe.swift`, `JITMappingWorker.swift`, `BuiltInJITCoordinator.swift`.
- Create: `src/MeloNX/MeloNXJITCore/Sources/MeloNXJITCore/JITAcquisitionEngine.swift` for the production async lifecycle, independent of UIKit/Combine.
- Extend: Core `JITDependencies.swift` with mapping, clock and debugger snapshot interfaces.
- Modify: `src/MeloNX/MeloNX/Common/JITChecker.swift`, `Core/RyujinxController.swift` only at readiness/mapping ownership boundaries.
- Test: `MeloNXJITCoreTests/JITCoordinatorTests.swift`, `JITSessionStateTests.swift` with injected transport/mapping/clock facts.

**Interfaces:**

```swift
public struct JITDebuggerSnapshot: Sendable {
    public let codeSigningDebugged: Bool
    public let currentlyTraced: Bool?
    public init(codeSigningDebugged: Bool, currentlyTraced: Bool?)
}
public protocol JITMapping: Sendable {
    func initialize() async throws -> Bool
}
public protocol JITClock: Sendable {
    var now: TimeInterval { get } // monotonic seconds, not wall-clock date
    func sleep(for seconds: TimeInterval) async throws
}
@MainActor public final class JITAcquisitionEngine {
    public private(set) var state: JITSessionState
    public init(pairing: any JITPairingStoring, network: any JITNetworkChecking,
                helper: any JITHelperStarting, mapping: any JITMapping,
                debugger: @escaping @Sendable () -> JITDebuggerSnapshot,
                clock: any JITClock)
    public func prepare() async
    public func enable(launchID: UUID?) async -> Bool
    public func cancel()
    public func resetDDI() async
}
@MainActor final class BuiltInJITCoordinator: ObservableObject {
    static let shared: BuiltInJITCoordinator
    @Published private(set) var phase: JITPhase
    @Published private(set) var message: String
    @Published private(set) var elapsed: TimeInterval
    var canRetry: Bool { get }
    func prepare() async
    func enable(launchID: UUID? = nil) async -> Bool
    func cancel()
    func resetDDI() async
}
```

The Foundation-only acquisition engine is the production implementation tested
by SwiftPM. The observable iOS coordinator wraps that engine, checks platform
availability/signing on the host, and publishes state; it does not reimplement
the lifecycle in a separate untested copy. Use monotonic system uptime for the
real clock and a deterministic clock in tests.

- [ ] **Step 1: Write failing fake-clock/fake-worker tests against `JITAcquisitionEngine`.** Cover unknown tracing, a persistent debug-signing flag after detach, mapping held on a semaphore, timeout/cancel with still-live helper, duplicated enable, invalid pairing, mapper failure, helper failure and old operation completion. Platform/signing rejection belongs to Task 6's host availability policy. Assert no main-thread blocking by completing another main-actor task while the fake mapper is held. Assert retry stays false until both owned worker and debugger termination facts are confirmed.

```swift
@MainActor func testCancelDuringMappingDoesNotLaunchOrStartAnotherHelper() async throws {
    let fixture = AcquisitionFixture.mappingHeld() // fake adapters using production protocols
    let task = Task { await fixture.engine.enable(launchID: UUID()) }
    await fixture.mapper.waitUntilStarted()
    fixture.engine.cancel()
    XCTAssertEqual(fixture.engine.state.phase, .stopping)
    XCTAssertNil(fixture.engine.state.allowedLaunchID)
    XCTAssertFalse(fixture.engine.state.canRetry)
    let duplicate = await fixture.engine.enable(launchID: UUID())
    XCTAssertFalse(duplicate)
    XCTAssertEqual(fixture.helper.startCount, 1)
    fixture.mapper.release(mapped: true)
    fixture.helper.finishDetached()
    let didEnable = await task.value
    XCTAssertFalse(didEnable)
}
```

Implement `AcquisitionFixture`, the held fake mapper and fake session in the test
file using the defined interfaces; `waitUntilStarted` yields through a checked
continuation, `release` resumes it, and `finishDetached` supplies terminal result
plus an untraced snapshot. Async values are read into locals before XCTest
assertion autoclosures.
- [ ] **Step 2: Implement a side-effect-free debugger probe.** Use the existing signing status check separately from the platform's process tracing state (Darwin `sysctl`/`kinfo_proc` `P_TRACED`, with read failure yielding nil). Probe code does not call `init_dualmapping`, execute BRK or allocate RX memory. Current tracing is required for the attach proof; `CS_DEBUGGED` alone is not attachment or teardown.
- [ ] **Step 3: Implement one serial mapper and result caching for this process.**

```swift
private let queue = DispatchQueue(label: "com.melonx.jit.mapping")
func initialize() async throws -> Bool {
    try await withCheckedThrowingContinuation { continuation in
        queue.async {
            let mapped = Ryujinx.initDualMapping()
            continuation.resume(returning: mapped)
        }
    }
}
```

The actual worker owns and joins each request; cancellation must not pretend a checked continuation's native operation ended. Serialize/reset readiness accesses so no status view or existing entry point races `hasScript`. Publish a cheap, pure cached readiness accessor after the worker finishes; retain external-method compatibility. Remove direct synchronous allocator calls from SwiftUI/status polling paths.
- [ ] **Step 4: Implement the acquisition engine and its observable coordinator in the proven order.** The host checks platform/signature/helper availability, then the engine validates pairing/network, prepares DDI, launches the enable helper, observes current attachment, schedules one mapper, completes all allocations including signal-handler executable code, lets `BreakJITDetach` run, waits for helper terminal result and confirmed worker/tracing facts, then exposes the current launch ID. Start DDI and mapping deadlines separately. A failed/unknown TXM detection is actionable failure, not non-TXM mode.
- [ ] **Step 5: Implement cancellation and timeout.** Invalidate the pending game ID immediately, enter stopping, request verified extension cancellation, and wait for the owned mapper/worker and tracing teardown. Record a specific teardown-unverified error if proof is unavailable. Do not permit new prepare, pairing replacement, reset or enable while stopping. Normal completion from a cancelled request transitions to cancelled, not ready.
- [ ] **Step 6: Close the later-allocation proof gate.** Revisit Task 1's allocator trace with the new worker. Instrument allocation/detach events without keys. Prove subsequent games use the prepared cache; if a later TXM preparation call occurs, add a coordinator reacquisition boundary before that call and test it. Do not repair this by keeping `hasScript=true` blindly.
- [ ] **Step 7: Run package tests and device cancellation/timeout probes during actual mapping.** A busy main actor, stuck worker, lingering debugger or unexpected game launch is a failure. Commit only after this task's lifecycle evidence and tests pass.

### Task 6: Expose setup and route all launch paths through the coordinator

**Files:**
- Create: `src/MeloNX/MeloNX/UI/Main/Settings/External/BuiltInJITSetupView.swift`.
- Create: `src/MeloNX/MeloNXJITCore/Sources/MeloNXJITCore/JITAvailability.swift` and `Tests/MeloNXJITCoreTests/JITAvailabilityTests.swift` within that package.
- Modify under `src/MeloNX/MeloNX/`: `Common/JIT/EnableJIT.swift`, `Common/AppEnvironment.swift`, `UI/Main/Settings/SettingsView.swift`, `UI/Main/Settings/NativeSettingsManager.swift`, `UI/Main/ContentView.swift`, `UI/Main/NoJITView.swift`, and `UI/Main/GamesList/GamesListView.swift` only where JIT/launch selection is needed.
- Modify: localization resources using their existing catalog pattern.
- Test: package launch-policy tests and targeted device UI journeys.

**Interfaces:**
- Consumes Task 5's coordinator and Task 3's setup adapters.
- Adds `JITProvider.builtIn = "Built-in StikJIT"`; all existing raw provider values retain their meanings.
- Produces a single launchID per requested game and only starts that game when the matching coordinator attempt succeeds.

```swift
public enum JITAvailability: Equatable, Sendable {
    case allowed
    case unavailable(String)
    public static func check(osMajor: Int, isPhysicalDevice: Bool,
                             inLiveContainer: Bool, getTaskAllow: Bool,
                             helperPresent: Bool) -> JITAvailability
}
```

The order is physical-device/OS/LiveContainer, then host signing, then installed
helper. Pairing and network are separate setup facts checked by the engine.

- [ ] **Step 1: Write failing provider/launch-policy tests.** Add a Foundation-only `JITAvailability` policy to Core (consumes OS major version, physical-device flag, LiveContainer flag, host get-task-allow and helper-present flag; returns a typed allowed/unavailable result). The iOS wrapper supplies real facts and uses the tested result. Pin preservation of an explicitly selected external provider, new-install default on supported OS, existing None offering setup, missing/renamed helper, iOS below 26, LiveContainer unavailability, missing entitlement, and go-back followed by late success not launching the game. The fake records startGame calls and must see zero after cancel.

```swift
func testMissingDebugEntitlementRejectsBuiltIn() {
    let result = JITAvailability.check(osMajor: 27, isPhysicalDevice: true,
        inLiveContainer: false, getTaskAllow: false, helperPresent: true)
    guard case .unavailable = result else {
        return XCTFail("A non-debuggable host cannot acquire built-in JIT")
    }
}
```
- [ ] **Step 2: Add the setup page with existing UI patterns.** Include pair on iOS 27, import/replace, LocalDevVPN action, prepare, enable, reset cache, stage/elapsed, actionable errors and retry gated by canRetry. No raw pairing contents, script selector, fictional percentage or automatic manipulation of other VPNs/cellular settings. Treat system pairing confirmation as a user step and give exact Settings guidance.
- [ ] **Step 3: Route provider dispatch without changing external methods.**

```swift
case .builtIn:
    Task { await BuiltInJITCoordinator.shared.enable() }
```

Use Task 5's app-owned `BuiltInJITCoordinator.shared` consistently, exposing that
same instance to SwiftUI as needed. Use setup-aware dispatch so a missing credential
opens setup rather than running an infinite loop. The existing `.stikdebug`,
`.stosdebug`, LC variants and TrollStore methods remain intact.
- [ ] **Step 4: Replace detached infinite wait polling and eager mapping.** For built-in launches, a view-owned `.task` awaits `enable(launchID:)`; after success, verify the view/launch is still current before startGame. On Go Back and `.onDisappear`, invalidate that launch and cancel acquisition when it owns the active request. Other-provider waits use a cancellable, bounded task and the pure readiness accessor. Remove `.task`/`.onAppear` eager `attemptToMapDualMapping()` calls that bypass the worker.
- [ ] **Step 5: Handle library, deep links and status consistently.** All built-in launch paths use the same coordinator and process-scoped ready state. A second launch after valid successful mapping may reuse the proven cache; restart/interruption invalidates readiness. Status rendering reads observable/cache state and performs no mapping side effect. Direct gameInfo deep links keep their existing data behavior.
- [ ] **Step 6: Run package tests and device UI journeys.** Exercise valid/invalid import, missing VPN, cancel while attaching/mapping, retry after teardown, setup restart, external-provider selection and one deep-link launch. Inspect screenshots after interaction; a displayed green state alone does not pass execution. Commit focused UI/entry-point changes.

### Task 7: Review, build, update in place and verify on 房栋的iPad

**Files:**
- Create: `docs/JIT.md` for the actual delivered setup, limits and troubleshooting.
- Create: `docs/superpowers/verification/2026-10-10-built-in-jit-device.md`.
- Update: README installation link and third-party notices as needed.
- Local artifacts: signed IPA, sanitized build/install/launch logs and opened screenshots under `/Users/hick/Downloads/MeloNX-built-in-JIT/`.

**Interfaces:**
- Consumes the complete host/helper/pairing build and source/test evidence.
- Produces a signed, installed, verified app under the unchanged installed bundle ID; gameplay claims remain bounded to actually exercised workloads.

- [ ] **Step 1: Run the scoped final checks.**

```bash
swift test --package-path src/MeloNX/MeloNXJITCore --enable-code-coverage
cargo test --manifest-path distribution/ios/rppairing/Cargo.toml --locked
git diff --check
```

Run the physical-device Xcode Release build from Task 1 including helper/pairing targets. Inspect signatures/entitlements, helper registration metadata, framework Info.plist/runpaths, OS gates, license notices and archive contents. Verify the artifact contains no pairing files, key ZIPs, game data or secrets.
- [ ] **Step 2: Use independent code and security review.** Review all changed code, native/Rust resource ownership, SPI failures, untrusted imported pairing data, message bounds, signing and stored credentials. Native execution uses a final fresh reviewer on the most capable available model, as required by the writing-plans handoff; subagent-driven execution also includes task reviews and a whole-branch review. Resolve concrete findings and rerun only affected checks.
- [ ] **Step 3: Snapshot data before the update without reading secrets.** List current application and Documents metadata; specifically preserve Downloads firmware/key ZIPs and any games/saves subsequently added by the user. Preserve the previous signed app artifact. No cleanup command touches these data files.
- [ ] **Step 4: Install the verified replacement in place.**

```bash
xcrun devicectl device install app --device 00008142-0001785A3E20401C \
  /Users/hick/Downloads/MeloNX-built-in-JIT/final/Payload/MeloNX.app --timeout 120
xcrun devicectl device process launch --device 00008142-0001785A3E20401C \
  com.hick.MeloNX --timeout 30
```

Use that exact output path when packaging the final build. Do not uninstall on failure. Re-check Documents metadata and Madeira's presence after installation.
- [ ] **Step 5: Validate the real built-in flow.** With LocalDevVPN connected, perform iOS 27 in-app pairing (user confirms Settings/PIN), prepare DDI, enable built-in JIT and capture/open the status screen. Record actual helper attachment, mapping completion, detach and known generated ARM64 execution result. Repeat after host restart. Cancel/timeout during actual mapping and retry only after teardown; verify the host remains responsive and no cancelled game starts.
- [ ] **Step 6: Validate allocation lifetime.** Run a user-provided legal playable workload if available and start another game/workload in the same process. Confirm no late unserviced breakpoint call or cached-readiness false success. Without a game, use the known JIT probe and a second probe launch; report gameplay as untested.
- [ ] **Step 7: Exercise recovery and preserve data.** Test invalid pairing in an isolated fake/import transaction that retains the valid Keychain record, VPN unavailable, stale-DDI reset/prepare, helper interruption and missing entitlement using test artifacts rather than damaging the working installation. Check existing firmware, keys, games and saves metadata plus independent Madeira behavior. Restore the working app artifact if a caused regression is reproduced.
- [ ] **Step 8: Document only executed evidence and deliver.** Write exact build versions/hashes, source revision, test results, device OS, actual JIT/probe outcome, user-only pairing steps, data-preservation checks and remaining limits. Leave product code uncommitted only if the user requests that; otherwise use focused local commits required by the execution workflow. Do not publish/merge/deploy externally. Final report distinguishes installed, runtime-verified and untested work.

## Plan self-review and execution handoff

All design components are owned above: build and protocol baseline (1), deterministic validation/state (2), credentials/network/pairing (3), extension/DDI/cancel proof (4), mapping/readiness (5), setup/launch/status UI (6), signing/data preservation/licensing/real-device verification (7). The five review-focus cases have named tests and runtime probes in their owning tasks.

Execution is gated on user review of this plan and selection of Native or Subagent-driven. Recommend **Native** for this plan: seven tasks share the same project file, coordinator and mapping lifecycle; one implementer avoids costly interface handoffs, while independent final code/security review remains required. Product implementation and dependency installation have not started.
