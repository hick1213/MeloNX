# NSZ iOS acceptance

Generated fixtures contain public synthetic data and fixed AES test values. They are deliberately not valid game NCAs. Never treat a converter proof as production package acceptance.

## Fixture export

Run `Ryujinx.Nsz.Tests` with `--filter ExportDeviceFixtures` and set `MELONX_NSZ_FIXTURES` to a fresh task-owned directory beneath `/Volumes/untitled/github/MeloNX/.local/`. The explicit NUnit test exports solid/block NSZ vectors and a version1 `manifest.json` with independently generated complete NSP hashes. Ordinary test runs skip this export.

## Debug probe

Xcode Debug forwards CONFIGURATION to the native build. `distribution/ios/build.sh` enables `MeloNXImportDiagnostics=true` only for Debug. Release/default command-line publishes exclude `nsz_conversion_probe`; production `nsz_import_*` always uses the real NCA/CNMT validator.

Copy the tiny fixture directory to app `Documents/Downloads/NSZImportQA`. Launch the Debug app with `--nsz-conversion-proof`. The probe writes unique NSP output filenames and `proof.json` in that QA directory, checks complete bytes/hashes, keeps cancellation blocked until the owned worker ends, and injects insufficient space. It cannot publish to the library/update/DLC roots. Roundtrip output files and compare their SHA256 with the manifest.

Verify actual source-built native exports with `nm -gU` and confirm Release has no diagnostic export. Verify the embedded `Resources/LICENSE-ZstdSharp.txt` bytes before signing; sign host/helper/nested code using the existing team/profiles and update in place without uninstalling.

## Required separate runtime gates

1. Record app Documents metadata before/after installation; preserve firmware, keys, saves and pairing.
2. Use the ordinary picker to import a malformed/generated NSZ. Inspect progress/cancel UI and clear production rejection, with source/old files unchanged.
3. Import a user-supplied legitimate application NSZ, or a Patch/AddOnContent NSZ for a selected matching game. Confirm metadata and launch or direct JSON registration. Exercise same-name files, cancellation and storage failure. Use available NSP/XCI samples for regression checks.
4. Re-enable built-in JIT in the same newly installed process and inspect the green Settings state. Gameplay requires an actual workload.

Device disconnected or no legitimate samples means these gates remain unverified. Keep their ledger entries incomplete; retain the plan workspace and evidence for resumption.
