//
//  MetalView.swift
//  MeloNX
//
//  Created by Stossy11 on 20/4/2026.
//

import SwiftUI
import MetalKit
import MeloNXOperationCore

class MetalView: MTKView {
    @ObservedObject var menuViewShower: InGameConfigView_MenuView = .shared
    private var touchIdentifiers = StableTouchIdentifiers<ObjectIdentifier>()

    private var aspectRatio: AspectRatio = .fixed16x9

    func setAspectRatio() {
        self.aspectRatio = RyujinxController.shared.currentSettings.aspectRatio
        Ryujinx.setViewSize(self.bounds)
        updateUnboundedPresentTargetFps()
    }

    private func updateUnboundedPresentTargetFps() {
        Ryujinx.setUnboundedPresentTargetFps(for: window?.screen)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateUnboundedPresentTargetFps()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateUnboundedPresentTargetFps()
    }
    
    private func transformToTargetCoordinates(_ point: CGPoint) -> CGPoint {
        return point
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        menuViewShower.triggerButton()
        guard !UserDefaults.standard.bool(forKey: "disableTouch") else { return }
        setAspectRatio()
        for touch in touches {
            let index = touchIdentifiers.begin(ObjectIdentifier(touch))
            let location = transformToTargetCoordinates(touch.location(in: self))
            Ryujinx.touchBegan(location, index: index)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        menuViewShower.triggerButton()
        guard !UserDefaults.standard.bool(forKey: "disableTouch") else {
            resetTouchTracking()
            return
        }
        setAspectRatio()
        for touch in touches {
            guard let index = touchIdentifiers.identifier(for: ObjectIdentifier(touch)) else { continue }
            let location = transformToTargetCoordinates(touch.location(in: self))
            Ryujinx.touchMoved(location, index: index)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        endTouches(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        endTouches(touches)
    }

    private func endTouches(_ touches: Set<UITouch>) {
        // End already-active fingers even when touch input was disabled mid-gesture.
        for touch in touches {
            if let index = touchIdentifiers.end(ObjectIdentifier(touch)) {
                Ryujinx.touchEnded(index: index)
            }
        }
    }

    func resetTouchTracking() {
        for index in touchIdentifiers.reset() { Ryujinx.touchEnded(index: index) }
    }

}



struct MetalViewRepresentable: UIViewRepresentable {
    var showView: Bool
    
    init(showView: Bool = true) {
        self.showView = showView
    }
    
    func makeUIView(context: Context) -> UIView {
        if showView {
            return Self.createView()
        } else { return MetalView() }
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        
    }
    
    @discardableResult
    static func createView() -> UIView {
        let view = RenderViewPreparation.prepare(cached: Ryujinx.emulationView, create: {
            let view = MetalView()
            guard let metalLayer = view.layer as? CAMetalLayer else {
                fatalError("[Swift] Error: MTKView's layer is not a CAMetalLayer")
            }
            UIApplication.shared.isIdleTimerDisabled = true
            if metalLayer.device == nil {
                metalLayer.device = MTLCreateSystemDefaultDevice()
            }
            view.framebufferOnly = false
            if #available(iOS 16.0, *) {
                MetalFxBridge.registerCallbacks()
            }
            return view
        }, publish: { view in
            guard let metalLayer = view.layer as? CAMetalLayer else {
                fatalError("[Swift] Error: MTKView's layer is not a CAMetalLayer")
            }
            Ryujinx.setNativeWindow(Unmanaged.passUnretained(metalLayer).toOpaque())
            Ryujinx.setUnboundedPresentTargetFps(for: view.window?.screen)
        })
        Ryujinx.emulationView = view
        return view
    }
}
