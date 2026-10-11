import SwiftUI
import MeloNXSaveSyncCore

struct SaveRestoreConfirmation: View {
    let snapshot: SaveSnapshot
    let localUserID: String?
    let expectedCloudUserID: String?
    let restore: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var bindingConfirmed = false
    private var foreign: Bool { snapshot.ownerUserID != expectedCloudUserID }
    var body: some View {
        NavigationStack {
            Form {
                Section("Restore Save") {
                    Text(snapshot.createdUTC)
                    Text("Your current emulator user's save will be backed up before it is replaced. The game must remain stopped until restoration finishes.")
                    if let localUserID { Text("Current user: \(String(localUserID.suffix(8)))").font(.caption).foregroundStyle(.secondary) }
                }
                if foreign {
                    Section("Different Emulator User") {
                        Text("This cloud save belongs to another emulator user. Confirm that it is your progress before connecting it to the current user.")
                        Toggle("Use this cloud user's save", isOn: $bindingConfirmed)
                            .accessibilityIdentifier("saveSync.confirmBinding")
                    }
                }
                Section {
                    Button("Back Up and Restore", role: .destructive) { restore(foreign && bindingConfirmed) }
                        .disabled(foreign && !bindingConfirmed)
                        .accessibilityIdentifier("saveSync.confirmRestore")
                }
            }
            .navigationTitle("Confirm Restore")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
