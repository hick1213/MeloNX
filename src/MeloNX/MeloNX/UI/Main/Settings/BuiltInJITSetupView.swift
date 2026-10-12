import SwiftUI
import UniformTypeIdentifiers
import MeloNXJITCore

struct BuiltInJITSetupView: View {
    @ObservedObject private var coordinator = BuiltInJITCoordinator.shared
    @ObservedObject private var pairing = JITDevicePairing.shared
    @AppStorage("preferBuiltInJIT") private var preferBuiltIn = true
    @State private var importing = false
    @State private var saved = false
    @State private var errorMessage = ""
    @State private var pairingTask: Task<Void, Never>?
    var body: some View {
        Form {
            Section("内置 JIT") {
                Toggle("优先使用内置 JIT", isOn: $preferBuiltIn)
                Text("首次需要配对，并连接 LocalDevVPN。重新打开 MeloNX 后需要重新获取 JIT。")
                if let reason = coordinator.unavailableReason { Text(reason).foregroundStyle(.secondary) }
                Text(saved ? "已保存配对凭据" : "尚未保存配对凭据")
                Text(coordinator.message.isEmpty ? "尚未开始" : coordinator.message).foregroundStyle(.secondary)
                if !coordinator.canRetry && !pairing.active {
                    ProgressView("\(coordinator.phase.rawValue) · \(Int(coordinator.elapsed)) 秒")
                    Button("取消 JIT 操作", role: .cancel) { coordinator.cancel() }
                }
            }
            Section("配对") {
                if JITDevicePairing.isSupported {
                    Button("在这台设备上配对") {
                        guard coordinator.canRetry else { return }
                        errorMessage = ""
                        pairingTask = Task {
                            do { _ = try await pairing.start(); refreshSaved() }
                            catch is CancellationError {} catch { errorMessage = "配对没有完成，请检查本地网络权限后重试。" }
                        }
                    }.disabled(!coordinator.canRetry || coordinator.unavailableReason != nil)
                    if pairing.active {
                        Text("打开系统设置 → 隐私与安全 → 开发者模式 → 与 MeloNX 配对。输入应用或系统进度卡片显示的验证码。")
                        if pairing.backgroundLimited { Text("后台运行时间受限，请立即前往设置完成配对。") }
                        if case .pin(let code) = pairing.phase {
                            Text(code).font(.system(size: 36, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                        }
                        Button("取消配对", role: .cancel) { pairing.cancel(); pairingTask?.cancel() }
                    }
                } else { Text("本机配对需要 iOS 27；较早系统可导入已有的远程配对文件。") }
                Button("导入远程配对文件") { importing = true }.disabled(!coordinator.canRetry)
                Text("凭据保存在本机钥匙串中。无效文件不会覆盖已有凭据。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("连接与验证") {
                Button("检查连接并准备开发者镜像") { Task { await coordinator.prepare() } }
                Button("获取 JIT 并验证代码执行") { preferBuiltIn = true; Task { _ = await coordinator.enable() } }
                Button("重置开发者镜像缓存") { Task { await coordinator.resetDDI() } }
            }.disabled(!coordinator.canRetry || coordinator.unavailableReason != nil || !saved)
            if !errorMessage.isEmpty { Section { Text(errorMessage).foregroundStyle(.red) } }
        }
        .navigationTitle("内置 JIT 设置")
        .onAppear { refreshSaved() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .xml], allowsMultipleSelection: false) { result in
            guard coordinator.canRetry else { return }
            do {
                guard let url = try result.get().first else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= 1_048_576 else { throw JITValidationError.pairingTooLarge }
                try JITKeychainPairingStore.shared.replace(with: Data(contentsOf: url))
                errorMessage = ""; refreshSaved()
            } catch { errorMessage = "文件无效或无法保存。请使用这台设备的远程配对 plist；已有凭据已保留。" }
        }
    }
    private func refreshSaved() { saved = (try? JITKeychainPairingStore.shared.load()) != nil }
}
