import SwiftUI
import MeloNXSaveSyncCore

struct CloudSaveVersionsView: View {
    let versions: [VisibleSnapshot]
    let selected: UUID?
    let choose: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Versions are kept when devices upload different progress. Choose the progress you want to restore; no cloud version will be deleted.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(versions.sorted { $0.snapshot.createdUTC > $1.snapshot.createdUTC }, id: \.snapshot.generation) { version in
                    Button { choose(version.snapshot.generation) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(version.snapshot.createdUTC)
                                Spacer()
                                if selected == version.snapshot.generation { Image(systemName: "checkmark.circle.fill") }
                            }
                            Text("User: \(String(version.snapshot.ownerUserID.suffix(8))) · Version: \(String(version.snapshot.generation.uuidString.prefix(8)))")
                                .font(.caption).foregroundStyle(.secondary)
                            Label(version.availability == .verified ? "Downloaded and verified" : "Download required", systemImage: version.availability == .verified ? "checkmark.shield" : "icloud.and.arrow.down")
                                .font(.caption)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Cloud Versions")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
