//
//  RyujinxController+FilePicker.swift
//  MeloNX
//
//  Created by Stossy11 on 30/4/2026.
//

import Foundation
import UIKit
import Combine
import MeloNXImportCore

extension RyujinxController {
    func beginNSZImport(urls: [URL], intent: NSZImportIntent,
                        onImported: (@MainActor (NSZImportedFile) throws -> Void)? = nil,
                        completion: @escaping @MainActor (Result<[NSZImportedFile], Error>) -> Void) {
        guard canBeginPackageImport, !urls.isEmpty, urls.allSatisfy({ NSZImportRouting.isNSZ(extension: $0.pathExtension) }) else {
            let error = NSZNativeFailure(code: "busy")
            AppAlerts.showSyncAlert(title: "NSZ Import", message: "Exit the game and finish any active operation before importing NSZ files.")
            completion(.failure(error)); return
        }
        NSZImportCoordinator.shared.begin(urls: urls, target: intent.target, kind: intent.kind,
                                         applicationID: intent.applicationID, onImported: onImported, completion: completion)
    }
    public func handleRunningGame(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                return
            }
            if NSZImportRouting.isNSZ(extension: url.pathExtension) {
                beginNSZImport(urls: [url], intent: .open) { [weak self] result in
                    if case .success(let files) = result, let file = files.first {
                        self?.loadGames()
                        self?.handleRunningGame(result: .success([URL(fileURLWithPath: file.path)]))
                    }
                }
                return
            }
            
            _ = url.startAccessingSecurityScopedResource()
            
            do {
                let handle = try FileHandle(forReadingFrom: url)
                let fileExtension = (url.pathExtension as NSString)
                
                let gameInfo = Ryujinx.getGameInfo(arg0: handle.fileDescriptor, arg1: fileExtension, path: url)
                
                self.startGame(gameInfo)
            } catch {
            }
            
        case .failure(let err):
            print("File import failed: \(err.localizedDescription)")
        }
    }
    
    
    public func handleAddingGame(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                return
            }
            if urls.contains(where: { NSZImportRouting.isNSZ(extension: $0.pathExtension) }) {
                guard urls.allSatisfy({ NSZImportRouting.isNSZ(extension: $0.pathExtension) }) else {
                    AppAlerts.showSyncAlert(title: "NSZ Import", message: "Select NSZ files separately from other game formats.")
                    return
                }
                beginNSZImport(urls: urls, intent: .library, onImported: { [weak self] _ in self?.loadGames() }) { _ in }
                return
            }
            guard NSZImportRouting.acceptsSelection(extensions: urls.map(\.pathExtension)) else {
                AppAlerts.showSyncAlert(title: "Game Import", message: "Select one uncompressed game at a time. Multiple NSZ files can be queued together.")
                return
            }
            
            let cool = url.startAccessingSecurityScopedResource()
            defer { cool ? url.stopAccessingSecurityScopedResource() : () }
            
            do {
                if !GameFileType.isSupported(fileExtension: url.pathExtension) {
                    AppAlerts.showSyncAlert(title: "Failed to import", message: "Unsupported file extension")
                    return
                }
                
                let fileManager = FileManager.default
                let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
                let romsDirectory = documentsDirectory.appendingPathComponent("roms")
                
                if !fileManager.fileExists(atPath: romsDirectory.path) {
                    try? fileManager.createDirectory(at: romsDirectory, withIntermediateDirectories: true, attributes: nil)
                }
                
                let destinationURL = romsDirectory.appendingPathComponent(url.lastPathComponent)
                try fileManager.copyItem(at: url, to: destinationURL)
                
                self.loadGames()
            } catch {
                AppAlerts.showSyncAlert(title: "Failed to import", message: error.localizedDescription)
            }
        case .failure(let err):
            AppAlerts.showSyncAlert(title: "Failed to import", message: err.localizedDescription)
        }
    }
    
    public func handleFirmwareImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let url):
            guard let url = url.first else {
                return
            }
            
            do {
                let path = url.path
                
                try Ryujinx.installFirmware(at: path)
                objectWillChange.send()
                _ = firmwareVersion
            } catch FirmwareInstallationError.failedInstall(let string) {
                AppAlerts.showSyncAlert(title: "Installing Firmware Failed", message: string, hasCancel: false)
            } catch {
                AppAlerts.showSyncAlert(title: "Installing Firmware Failed", message: error.localizedDescription, hasCancel: false)
            }
        case .failure(let error):
            AppAlerts.showSyncAlert(title: "Installing Firmware Failed", message: error.localizedDescription, hasCancel: false)
        }
    }
    
}
