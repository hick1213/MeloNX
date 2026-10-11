# Manual iCloud save acceptance

Approved scope: `com.hick.MeloNX`, team `KWP42AEP6Q`, CloudDocuments container
`iCloud.com.hick.MeloNX`. Only the host receives cloud entitlements. Preserve the
owned JIT helper's entitlements and update the app in place; never uninstall or
clear NAND, keys, firmware, pairing material, other games or backups.

## Local checks

- `dotnet test src/Ryujinx.SaveSync.Tests` exercises generated independent NAND,
  logical Account/Device/index mapping, exact replacement, corruption rejection,
  durable journals and failure/restart recovery. It does not use user keys/games.
- `swift test --package-path src/MeloNX/MeloNXSaveSyncCore` exercises snapshots,
  propagation, actual macOS file coordination, held native resources, bindings,
  manual coordination, offline restart receipts and presentation states.
- OperationCore, ImportCore, JITCore and Ryujinx.Nsz.Tests remain regression gates.
- Build iOS/AOT using the external SDK/cache paths. Inspect actual source build
  exit status and the seven `save_sync_` exports; model tests do not prove C ABI.
- `distribution/ios/verify-save-sync-signing.sh MeloNX.app [target-udid]` checks
  deep signatures, host profile permissions, exact container/service/BID/team,
  increased memory, debug entitlement and unchanged helper cloud permissions.
  It prints only booleans, never raw profiles, tokens, device IDs or user data.

## UI-only fixture

Launch the Debug app with `--save-sync-ui-fixture`. It labels itself as a UI
fixture and uses synthetic bytes, independent fake ports/gate and a separate
`Documents/SaveSyncUIFixture/<UUID>` root. It never calls cloud storage or opens
user NAND. Test game choice, upload/download buttons, restore confirmation,
repeated-action prevention, dismissal, cancellation and six-second safe finishing.
Capture portrait/landscape and basic accessibility evidence on the target phone.
This fixture is not a real iCloud, C ABI restore or gameplay proof.

## Required physical gates

1. Record target app Documents metadata before the in-place update. Verify signed
   host/container/profile/helper with the verifier. Do not install a mismatched
   cloud-rights package as a successful feature build.
2. Native startup recovery must finish before shortcuts, last-game launch, JIT,
   firmware/game import or filesystem metadata reads. Confirm actual cold boot.
3. With a user-supplied legitimate game, save progress in-game and exit its actual
   native thread. Upload Account/current user + Device records only. Wait for all
   manifests and payload files to be confirmed uploaded before success/parent update.
4. On a user-identified second device signed for the same container and logged into
   the same iCloud account, fully download and verify hashes/sizes/directories.
   Confirm user binding if IDs differ. Restore with backups and legal local save
   mappings, then launch the actual game and verify progress.
5. Exercise offline queued upload/restart/retry, quota failure, identity switching,
   simultaneous device branches, incomplete successors and unresolved file conflicts.
   Do not delete cloud versions or choose a winner by time.
6. Interrupt before/after individual commits and final completed marker. Cold replay
   must roll back incomplete transactions and only repair binding for completed ones.
   Keep failed rollback blocked and backups/journals intact; no forced unlock.
7. Recheck supplied keys/firmware/other games, NSZ generated probe + legitimate import,
   startup gate and confirmed acquired JIT. No lower-layer check replaces these gates.

Portable synthetic fixture: the public byte files and bounded manifests in
`src/MeloNX/MeloNXSaveSyncCore/Tests/MeloNXSaveSyncCoreTests/Fixtures`. Empty
`payload/empty/sub` directories are explicitly materialized by tests because Git
cannot store empty directories. The fixtures contain no console keys or user saves.

Current evidence and remaining gates are recorded in the external worktree's
`.superpowers/sdd/2026-10-11-icloud-save-sync/progress.md` and the installation ledger.
