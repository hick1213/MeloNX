//
//  Untitled.swift
//  MeloNX
//
//  Created by Stossy11 on 21/12/2024.
//

import SwiftUI

struct PerformanceOverlayView: View {
    @StateObject private var memorymonitor = MemoryUsageMonitor()
    @StateObject private var nativeSettings: NativeSettingsManager = .shared
    @ObservedObject var statisticsHandler: StatisticsHandler
    
    @State private var batteryLevel: Int = Int(UIDevice.current.batteryLevel * 100)
    
    
    @ViewBuilder
    var content: some View {
        if nativeSettings.horizontalorvertical(false).bool {
            HStack(spacing: 8) {
                overlayText
            }
            .padding(10)
        } else {
            VStack(alignment: .trailing, spacing: 8) {
                overlayText
            }
            .padding(10)
            .frame(minWidth: 150)
        }
    }
    
    @ViewBuilder
    var overlayText: some View {
        if nativeSettings.horizontalorvertical(false).bool {
            Text("Battery: \(batteryLevel)%")
                .foregroundStyle(.white)
        }
        
        Text(nativeSettings.performanceFrameTime(true).bool ? statisticsHandler.formatFPS() + (" (\(statisticsHandler.frameTime)ms)") : statisticsHandler.formatFPS())
            .foregroundStyle(.white)
        
        if nativeSettings.performanceRam(true).bool {
            Text("RAM: " + memorymonitor.formatMemorySize(memorymonitor.memoryUsage))
                .foregroundStyle(.white)

            if memorymonitor.donatedMemory > 0 {
                Text("Donated: " + memorymonitor.formatMemorySize(memorymonitor.donatedMemory))
                    .foregroundStyle(.white)
            }
        }

        if nativeSettings.performanceFIFO(false).bool {
            Text("FIFO: \(statisticsHandler.fifo, specifier: "%.2f")%")
                .foregroundStyle(.white)
        }
    }
    
    var body: some View {
        content
            .background(Color.black.opacity(0.7))
            .onAppear() {
                UIDevice.current.isBatteryMonitoringEnabled = true
                batteryLevel = Int(UIDevice.current.batteryLevel * 100)
                
                if nativeSettings.performanceRam(true).bool { memorymonitor.start() }
            }
            .onDisappear { memorymonitor.stop() }
            .onChange(of: nativeSettings.performanceRam(true).bool) { shown in
                if shown { memorymonitor.start() } else { memorymonitor.stop() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
                batteryLevel = Int(UIDevice.current.batteryLevel * 100)
            }
    }
}

