import SwiftUI
import MetalKit
import MultiverseCore

/// SwiftUI host for the Metal universe with orbit / pinch / pan gestures and node picking.
struct UniverseMetalView: UIViewRepresentable {
    let model: AppModel
    var onPick: (EntityID?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model, onPick: onPick) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.framebufferOnly = true
        view.isMultipleTouchEnabled = true
        guard let renderer = CosmicRenderer(view: view) else { return view }
        context.coordinator.renderer = renderer
        view.delegate = renderer
        model.renderer = renderer
        renderer.quality = model.effectiveQuality
        renderer.overridesProvider = { [weak model] now, t in
            MainActor.assumeIsolated { model?.frameOverrides(now: now, shaderTime: t) ?? FrameOverrides() }
        }
        renderer.onFrameTime = { [weak model] dt in MainActor.assumeIsolated { model?.reportFrameTime(dt) } }
        if let scene = model.scene { renderer.upload(scene) }

        let c = context.coordinator
        view.addGestureRecognizer(UIPanGestureRecognizer(target: c, action: #selector(Coordinator.rotate(_:))))
        let twoFinger = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        twoFinger.minimumNumberOfTouches = 2
        view.addGestureRecognizer(twoFinger)
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:))))
        let doubleTap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.onPick = onPick
        view.preferredFramesPerSecond = model.effectiveQuality.preferredFPS
    }

    @MainActor
    final class Coordinator: NSObject {
        let model: AppModel
        var onPick: (EntityID?) -> Void
        var renderer: CosmicRenderer?   // strong: MTKView.delegate is weak
        private var lastPan = CGPoint.zero
        private var lastTwo = CGPoint.zero

        init(model: AppModel, onPick: @escaping (EntityID?) -> Void) { self.model = model; self.onPick = onPick }

        @objc func rotate(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            if g.state == .began { lastPan = .zero }
            renderer?.camera.rotate(dx: Float(t.x - lastPan.x), dy: Float(t.y - lastPan.y))
            lastPan = t
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let r = renderer else { return }
            let t = g.translation(in: g.view)
            if g.state == .began { lastTwo = .zero }
            let v = r.camera.viewMatrix()
            r.camera.pan(dx: Float(t.x - lastTwo.x), dy: Float(t.y - lastTwo.y),
                         right: SIMD3(v.columns.0.x, v.columns.1.x, v.columns.2.x), up: SIMD3(v.columns.0.y, v.columns.1.y, v.columns.2.y))
            lastTwo = t
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            renderer?.camera.zoom(scale: Float(g.scale))
            g.scale = 1
        }

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let r = renderer, let view = g.view, let graph = model.graph else { return }
            let idx = r.pick(point: g.location(in: view), viewSize: view.bounds.size)
            onPick(idx.map(graph.id(of:)))
        }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            // Zoom out to the whole universe.
            guard let r = renderer else { return }
            r.camera.frame(model.positions.isEmpty ? [.zero] : model.positions, padding: 1.1)
        }
    }
}
