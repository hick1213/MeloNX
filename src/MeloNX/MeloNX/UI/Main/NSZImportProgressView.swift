import SwiftUI
import MeloNXImportCore

struct NSZImportProgressView: View {
    @ObservedObject var coordinator = NSZImportCoordinator.shared
    private var title: String {
        switch coordinator.phase {
        case .idle, .preparing: return "Preparing NSZ"
        case .converting: return "Converting NSZ"
        case .validating: return "Validating Package"
        case .committing: return "Saving Package"
        case .stopping: return "Stopping Import"
        case .succeeded: return "Import Complete"
        case .failed: return "Import Failed"
        case .cancelled: return "Import Cancelled"
        }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "shippingbox").font(.system(size: 42)).foregroundStyle(.tint)
                Text(title).font(.title2.bold())
                Text(coordinator.sourceName).font(.subheadline).lineLimit(2)
                if coordinator.phase == .converting, coordinator.totalBytes > 0 {
                    ProgressView(value: min(0.99, Double(coordinator.completedBytes) / Double(coordinator.totalBytes)))
                    Text("\(ByteCountFormatter.string(fromByteCount: coordinator.completedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: coordinator.totalBytes, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                } else { ProgressView() }
                if coordinator.phase == .stopping {
                    Text("Waiting for the import to finish stopping.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Button("Cancel Import", role: .cancel) { coordinator.cancel() }.buttonStyle(.bordered)
                }
            }
            .padding(28).frame(maxWidth: 420)
            .navigationTitle("NSZ Import").navigationBarTitleDisplayMode(.inline)
        }
        .onDisappear { if coordinator.isBusy { coordinator.cancel() } }
    }
}
