//
//  JITPopover.swift
//  MeloNX
//
//  Created by Stossy11 on 10/11/2025.
//

import SwiftUI
import MeloNXJITCore

struct NoJITView: View {
    var game: GameInfo
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var ryujinxController: RyujinxController
    @ObservedObject public var nativeSettingsManager = NativeSettingsManager.shared
    
    @State private var isJIT: Bool = false
    @State private var requestID = UUID()
    @State private var status = ""
    @State private var attemptGeneration = 0
    @State private var setup = false
    @State private var pulseAnimation: Bool = false
    
    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                if let icon = game.icon {
                    Image(uiImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 150, height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(12)
                        .background {
                            RoundedRectangle(cornerRadius: 24)
                                .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                        }
                } else {
                    Circle()
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                        .frame(width: 100, height: 100)
                    
                    Image(systemName: "cpu.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.top, 10)
            
            VStack(spacing: 8) {
                Text("Waiting for JIT")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                Text("Waiting for Just-In-Time compilation...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.accentColor)
                        .font(.system(size: 16))
                    
                    Text("JIT compilation enables MeloNX to achieve maximum performance by dynamically translating and executing code on the fly.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 16))
                    
                    Text("Enabling JIT is required for the emulator to function.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.thinMaterial)
            )
            
            
            if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.secondary) }
            Button("内置 JIT 设置") { setup = true }
            Button("Go Back") {
                if let id = ryujinxController.pendingLaunchID { ryujinxController.cancelPendingLaunch(id) }
            }
            .foregroundStyle(Color.accentColor)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.thinMaterial)
            )
        }
        .padding(24)
        .frame(maxWidth: 400)
        .sheet(isPresented: $setup, onDismiss: { attemptGeneration += 1 }) { NavigationView { BuiltInJITSetupView() }.withAppTheme() }
        .task(id: attemptGeneration) {
            guard let launchID = ryujinxController.pendingLaunchID else { return }
            requestID = launchID
            pulseAnimation = true
            let coordinator = BuiltInJITCoordinator.shared
            var ready = false
            let provider = nativeSettingsManager.jitProvider(JITProvider.disabled).value
            let preference = UserDefaults.standard.object(forKey: "preferBuiltInJIT") as? Bool
            let useBuiltIn = JITCompatibilityPolicy.useBuiltIn(preference: preference, externalProviderSelected: provider != .disabled)
            if useBuiltIn, coordinator.unavailableReason == nil {
                guard (try? JITKeychainPairingStore.shared.load()) != nil else {
                    status = "请先打开内置 JIT 设置，完成配对并连接 LocalDevVPN。"
                    return
                }
                ready = await coordinator.enable(launchID: requestID)
                status = coordinator.message
            } else {
                EnableJIT.enableJIT(nativeSettingsManager.jitProvider(JITProvider.disabled).value)
                let deadline = ProcessInfo.processInfo.systemUptime + 60
                while !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
                    if checkDebugged() { ready = await coordinator.enableExternal(launchID: requestID); if ready { break } }
                    do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                }
                if !ready { status = "外部 JIT 等待超时，可以返回后重试。" }
            }
            guard ready, !Task.isCancelled else { return }
            ryujinxController.startGame(game, resumingLaunchID: requestID)
        }
        .onDisappear { ryujinxController.cancelPendingLaunch(requestID) }
    }
}
