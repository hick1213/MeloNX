//
//  Alert.swift
//  MeloNX
//
//  Created by Stossy11 on 30/4/2026.
//

import Foundation
import UIKit
import SwiftUI

@MainActor class AppAlerts {
    private static func rootViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController
    }

    static func topViewController() -> UIViewController? {
        let rootViewController = rootViewController()
        guard let rootViewController else {
            return nil
        }
        
        return topMost(of: rootViewController)
    }
    
    private static func topMost(of viewController: UIViewController) -> UIViewController {
        if let presented = viewController.presentedViewController {
            return topMost(of: presented)
        }
        
        if let navigationController = viewController as? UINavigationController,
           let visibleViewController = navigationController.visibleViewController {
            return topMost(of: visibleViewController)
        }
        
        if let tabController = viewController as? UITabBarController,
           let selectedViewController = tabController.selectedViewController {
            return topMost(of: selectedViewController)
        }
        
        return viewController
    }

    static func present(_ alert: UIAlertController, from preferred: UIViewController? = nil,
                        onUnavailable: (() -> Void)? = nil, attempt: Int = 0) {
        guard attempt < 4, var presenter = preferred ?? rootViewController() else {
            onUnavailable?()
            return
        }
        while true {
            if let transition = presenter.transitionCoordinator {
                var resumed = false
                let retry = {
                    guard !resumed else { return }
                    resumed = true
                    Task { @MainActor in
                        // The old sheet/picker may have gone away. Resolve the current host again.
                        present(alert, onUnavailable: onUnavailable, attempt: attempt + 1)
                    }
                }
                if !transition.animate(alongsideTransition: nil, completion: { _ in retry() }) {
                    Task { @MainActor in
                        // A false animation result does not mean dismissal has finished.
                        for _ in 0..<50 {
                            guard !resumed else { return }
                            if presenter.transitionCoordinator == nil && !presenter.isBeingDismissed && !presenter.isBeingPresented {
                                retry()
                                return
                            }
                            try? await Task.sleep(nanoseconds: 100_000_000)
                        }
                        guard !resumed else { return }
                        resumed = true
                        onUnavailable?()
                    }
                }
                return
            }
            guard !presenter.isBeingDismissed, !presenter.isBeingPresented else {
                onUnavailable?()
                return
            }
            if let presented = presenter.presentedViewController { presenter = presented }
            else if let nav = presenter as? UINavigationController, let visible = nav.visibleViewController { presenter = visible }
            else if let tab = presenter as? UITabBarController, let selected = tab.selectedViewController { presenter = selected }
            else { break }
        }
        guard !(presenter is UIAlertController), !(presenter is UIDocumentPickerViewController),
              presenter.viewIfLoaded?.window != nil else {
            onUnavailable?()
            return
        }
        presenter.present(alert, animated: true)
    }
    
    static func showAlert(_ viewController: UIViewController? = nil,
                          title: String?,
                          message: String?,
                          actions: [(title: String, style: UIAlertAction.Style, handler: (() -> Void)?)]) {
        
        
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        
        for action in actions {
            let uiAction = UIAlertAction(title: action.title, style: action.style) { _ in
                action.handler?()
            }
            alert.addAction(uiAction)
        }
        
        present(alert, from: viewController)
    }
    
    @discardableResult
    static func showSyncAlert(
        title: String?,
        message: String?,
        actions: [String] = ["OK"],
        hasCancel: Bool = true,
        alertHandler: @escaping (String) -> Void = { _ in }
    ) -> UIAlertController? {
        
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        
        for actionTitle in actions {
            alert.addAction(UIAlertAction(title: actionTitle, style: .default) { _ in
                alertHandler(actionTitle)
            })
        }
        
        if hasCancel {
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                alertHandler("Cancel")
            })
        }
        
        present(alert)
        
        return alert
    }
    
    @MainActor
    static func showTextFieldAlert(
        title: String?,
        message: String?,
        default defaultText: String?,
        action: String = "OK",
    ) async -> String? {
        await withCheckedContinuation { continuation in
            guard topViewController() != nil else {
                continuation.resume(returning: "NoPresenter")
                return
            }
            
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addTextField()
            
            alert.textFields![0].text = defaultText
            
            alert.addAction(UIAlertAction(title: action, style: .default) { _ in
                let answer = alert.textFields![0]
                
                continuation.resume(returning: answer.text)
            })
            
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                continuation.resume(returning: defaultText)
            })
            
            present(alert, onUnavailable: { continuation.resume(returning: "NoPresenter") })
        }
    }
    
    @MainActor
    static func showAlert(
        title: String?,
        message: String?,
        actions: [String] = ["OK"],
        hasCancel: Bool = true
    ) async -> String {
        
        await withCheckedContinuation { continuation in
            guard topViewController() != nil else {
                continuation.resume(returning: "NoPresenter")
                return
            }
            
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            
            for actionTitle in actions {
                alert.addAction(UIAlertAction(title: actionTitle, style: .default) { _ in
                    continuation.resume(returning: actionTitle)
                })
            }
            
            if hasCancel {
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                    continuation.resume(returning: "Cancel")
                })
            }
            
            present(alert, onUnavailable: { continuation.resume(returning: "NoPresenter") })
        }
    }
}
