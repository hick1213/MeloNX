//
//  ContentView.swift
//  MeloNX
//
//  Created by Stossy11 on 4/4/2026.
//

import SwiftUI
import MetalKit
import Melo_Controller

struct EnvironmentVariable: Codable, Hashable {
    let string: String
    var value: String
    
    func set() {
        setenv(string, value, 1)
    }
    
    static func set(_ env: EnvironmentVariable) {
        setenv(env.string, env.value, 1)
    }
}



struct ContentView: View {
    @EnvironmentObject var ryujinxController: RyujinxController
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject public var nativeSettingsManager = NativeSettingsManager.shared
    @StateObject var controllerManager: ControllerManager = .shared
    @ObservedObject private var nszImport = NSZImportCoordinator.shared
    @State private var selectedTab: Tab = .games
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.appTheme) var theme
    
    var tabView: some View {
        TabView(selection: $selectedTab) {
            GamesListView()
                .tabItem { Label("Library", systemImage: "gamecontroller.fill") }
                .tag(Tab.games)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(Tab.settings)
        }
        .accentColor(theme.accent.primary)
        .onOpenURL { url in
            if url.isFileURL, url.pathExtension.lowercased() == "nsz" {
                ryujinxController.handleRunningGame(result: .success([url]))
            } else { AppEnvironment.handleDeepLink(url, ryujinxController: ryujinxController) }
        }
        .onAppear {
            NativeSettingsManager.setShared()
#if DEBUG
            if JITAcquisitionDiagnostic.requested { selectedTab = .settings }
#endif
        }
        .task {
            guard await SaveRecoveryBootstrap.shared.ensureReady() else { return }
            ryujinxController.loadGames()
#if DEBUG
            await NSZImportDiagnostic.runIfRequested()
#endif
            
            try? await Task.sleep(nanoseconds: 100_000_000)
            
            controllerManager.initAll()
            
            MetalViewRepresentable.createView()
            
            AlertHandlers.register()
            
            Air.play(AnyView(Text("Select Game")))
            Task { _ = await BuiltInJITCoordinator.shared.enableAutomatically() }
            
            try? await Task.sleep(nanoseconds: 500_000_000)
            
            if let gameId = ryujinxController.lastGameLaunched, let game = ryujinxController.games.first(where: { $0.titleId == gameId }) {
                ryujinxController.startGame(game)
            } else {
                ryujinxController.lastGameLaunched = nil
            }
        }
    }
    
    @ViewBuilder
    func emulationView(game: GameInfo, state: StartedState) -> some View {
        switch state {
        case .none:
            EmulationView(game: game)
        case .entitlement:
            ControllerView(controller: VirtualControllerManager.shared, isEditing: false)
                .allowsHitTesting(false)
                .frame(width: .infinity, height: .infinity)
                .alert(isPresented: .constant(ryujinxController.isRunning.isEntitlement())) {
                    Alert(
                        title: Text("Entitlement"),
                        message: Text(LocalizedStringKey("MeloNX **REQUIRES** the Increased Memory Limit entitlement, Please follow the instructions on how to Install MeloNX and Enable the Entitlement.")),
                        primaryButton: .default(Text("Instructions")) {
                            UIApplication.shared.open(
                                URL(string: "https://git.ryujinx.app/projects/MeloNX#how-to-install")!,
                                options: [:],
                                completionHandler: nil
                            )
                            ryujinxController.isRunning = .stopped
                        },
                        secondaryButton: .cancel(Text("Cancel")) {
                            ryujinxController.isRunning = .stopped
                        }
                    )
                }
        case .noJIT:
            NoJITView(game: game)
        case .extendedEntitlement:
            ControllerView(controller: VirtualControllerManager.shared, isEditing: false)
                .allowsHitTesting(false)
                .frame(width: .infinity, height: .infinity)
                .alert(isPresented: .constant(ryujinxController.isRunning.isEntitlement())) {
                    Alert(
                        title: Text("Extended Virtual Addressing"),
                        message: Text(LocalizedStringKey("The Extended Virtual Addressing entitlement is required for your device, Please read the Information on how to Install MeloNX and Enable the **PAID** Entitlement.")),
                        primaryButton: .default(Text("Information")) {
                            UIApplication.shared.open(
                                URL(string: "https://git.ryujinx.app/projects/MeloNX#entitlements")!,
                                options: [:],
                                completionHandler: nil
                            )
                            ryujinxController.isRunning = .stopped
                        },
                        secondaryButton: .cancel(Text("Cancel")) {
                            ryujinxController.isRunning = .stopped
                        }
                    )
                }
        case .usersList:
            EmptyView() // TODO: Finish eventually™
        }
    }
    
    var body: some View {
        Group {
            switch ryujinxController.isRunning {
            case .stopped:
                tabView
            case .started(game: let game, state: let state):
                emulationView(game: game, state: state)
            case .crashed(result: let crashed):
                tabView
                    .alert(isPresented: .constant(ryujinxController.isRunning.hasCrashed())) {
                        Alert(
                            title: Text("MeloNX Crashed!"),
                            message: Text(LocalizedStringKey("MeloNX crashed with result: \(crashed)")),
                            dismissButton: .cancel(Text("Cancel")) {
                                ryujinxController.isRunning = .stopped
                            }
                        )
                    }
            }
        }
        .sheet(isPresented: Binding(get: { nszImport.isBusy && nszImport.packageKind == 0 }, set: { if !$0 { nszImport.cancel() } })) {
            NSZImportProgressView()
        }
        .safeAreaInset(edge: .top) { SaveRecoveryStatusView() }
        .safeAreaInset(edge: .bottom) {
            if ryujinxController.waitingForAutomaticJIT {
                HStack {
                    ProgressView("正在准备 JIT…")
                    Spacer()
                    Button("取消启动") { ryujinxController.cancelAutomaticLaunch() }
                }
                .padding()
                .background(.regularMaterial)
            }
        }
        .onDisappear { if nszImport.isBusy { nszImport.cancel() } }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .active:
                if ryujinxController.isRunning.isRunning() {
                    if !ryujinxController.wasManuallyPaused {
                        ryujinxController.isPaused = false
                    }
                } else if ryujinxController.pendingLaunchID == nil {
                    Task { _ = await BuiltInJITCoordinator.shared.enableAutomatically() }
                }
            case .inactive:
                if ryujinxController.isRunning.isRunning(), !ryujinxController.wasManuallyPaused {
                    ryujinxController.isPaused = true
                }
                break
            case .background:
                nszImport.cancel()
                if ryujinxController.isRunning.isRunning(), !ryujinxController.wasManuallyPaused {
                    ryujinxController.isPaused = true
                }
                break
            @unknown default:
                break
            }
        }
    }
}





#Preview {
    ContentView()
}
