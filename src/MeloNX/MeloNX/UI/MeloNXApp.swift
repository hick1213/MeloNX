//
//  MeloNXApp.swift
//  MeloNX
//
//  Created by Stossy11 on 4/4/2026.
//

import SwiftUI
import MeloNXJITCore
import SDL3
import AVFoundation

func configureAudioSession() {
    do {
        let session = AVAudioSession.sharedInstance()

        try session.setCategory(
            .playback,
            options: .mixWithOthers
        )
        try session.setPreferredSampleRate(48000)
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
    } catch {
        print("Audio session error: \(error.localizedDescription)")
    }
}

var environment: [EnvironmentVariable] = [
    EnvironmentVariable(string: "MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS", value: "0"),
    EnvironmentVariable(string: "MVK_CONFIG_MAX_ACTIVE_METAL_COMMAND_BUFFERS_PER_QUEUE", value: "32"),
]


func initEnvironmentVariables() {
    if let device = MTLCreateSystemDefaultDevice(), device.argumentBuffersSupport.rawValue < MTLArgumentBuffersTier.tier2.rawValue {
        environment.append(contentsOf: [
            .init(string: "MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", value: "0")
        ])
    }
    
    if #available(iOS 19, *) {
        environment.append(contentsOf: [
            .init(string: "HAS_TXM", value: ProcessInfo.processInfo.hasTXM && !ProcessInfo.processInfo.isiOSAppOnMac ? "1" : "0"),
            .init(string: "DUAL_MAPPED_JIT", value: !ProcessInfo.processInfo.isiOSAppOnMac ? "1" : "0")
        ])
    } else {
        environment.append(contentsOf: [
            .init(string: "HAS_TXM", value: "0"),
            .init(string: "DUAL_MAPPED_JIT", value: "0")
        ])
    }
    
    for env in environment { env.set() }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock = UIInterfaceOrientationMask.all

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return AppDelegate.orientationLock
    }
}


@main
struct MeloNXApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    @StateObject var ryujinxController: RyujinxController = .shared
    @StateObject var themeManager: ThemeManager = .shared
    
    @AppStorage("hasSetupFinished") var hasSetupFinished: Bool = false
    @AppStorage("lastAppversion") var lastAppversion: Data = Data()
#if DEBUG
    @State private var jitDiagnosticFinished = false
#endif

    private var shouldShowSetup: Bool {
#if DEBUG
        if FirmwareImportDiagnostic.requested || JITAcquisitionDiagnostic.requested { return false }
#endif
        return !hasSetupFinished
    }
    
    init() {
        SDL_SetMainReady()
        SDL_SetiOSEventPump(true)
        SDL_Init(SDL_INIT_EVENTS)
        JIT26BreakpointHandler()
        initEnvironmentVariables()
        Ryujinx.initialize()
        ThemeManager.shared.applyUIKitAppearance()
    }
    
    var body: some Scene {
        WindowGroup {
            Group {
#if DEBUG
                if JITAcquisitionDiagnostic.requested {
                    if jitDiagnosticFinished {
                        ContentView()
                    } else {
                        Text("正在检查内置 JIT…")
                            .task {
                                await JITAcquisitionDiagnostic.run()
                                jitDiagnosticFinished = true
                            }
                    }
                } else if FirmwareImportDiagnostic.requested {
                    Text("正在安装 22.5.0 固件…")
                        .task { await FirmwareImportDiagnostic.run() }
                } else if JITCancellationDiagnostic.requested {
                    Text("Checking JIT helper cancellation…")
                        .task { await JITCancellationDiagnostic.run() }
                } else if ProcessInfo.processInfo.arguments.contains("--jit-pairing-setup") {
                    NavigationView { BuiltInJITSetupView() }
                } else { ContentView() }
#else
                ContentView()
#endif
            }
                .environmentObject(ryujinxController)
                .environmentObject(themeManager)
                .withAppTheme()
                .onAppear() {
                    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                    
                    configureAudioSession()
                    
                    let versionNumber = StoredAppVersion.decode(lastAppversion)
                    
                    if versionNumber < Float(Bundle.main.versionNumber) ?? .zero {
                        lastAppversion = encodeFloatToData(Float(Bundle.main.versionNumber) ?? .zero)
                         hasSetupFinished = false
                    }
                }
                .sheet(isPresented: .constant(shouldShowSetup)) {
                    SetupView {
                        hasSetupFinished = true
                        ryujinxController.loadGames()
                    }
                    .interactiveDismissDisabled()
                    .withAppTheme()
                }
        }
    }
    
    func encodeFloatToData(_ value: Float) -> Data {
        var mutableValue = value
        return Data(bytes: &mutableValue, count: MemoryLayout<Float>.size)
    }
}
