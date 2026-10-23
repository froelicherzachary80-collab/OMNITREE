import Foundation
import Metal
import MetalKit
import MetalPerformanceShaders
import simd
import MultiverseCore

/// Uniform block shared with Shaders.metal (`Uniforms`).
struct CosmicUniforms {
    var viewProj: simd_float4x4
    var view: simd_float4x4
    var cameraPos: SIMD4<Float>
    var viewport: SIMD4<Float>
    var params: SIMD4<Float>
    var cameraRight: SIMD4<Float>
    var cameraUp: SIMD4<Float>
}

/// Per-frame overrides produced by the reveal / growth animators and selection state.
struct FrameOverrides {
    var edgeStates: [Int: SIMD4<Float>] = [:]
    var nodeHighlight: [Int32: Float] = [:]
    var dim: Float = 0
}

/// Custom Metal renderer for the cosmic multiverse: HDR scene with additive glowing branch ribbons,
/// instanced node billboards, starfield + energy motes, MPS Gaussian bloom and ACES tonemapping.
@MainActor
final class CosmicRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var backgroundPipeline: MTLRenderPipelineState!
    private var branchPipeline: MTLRenderPipelineState!
    private var nodePipeline: MTLRenderPipelineState!
    private var particlePipeline: MTLRenderPipelineState!
    private var brightPipeline: MTLRenderPipelineState!
    private var compositePipeline: MTLRenderPipelineState!

    private nonisolated static let maxInFlight = 3
    private nonisolated let inFlight = DispatchSemaphore(value: 3)
    private var frameIndex = 0

    // Scene buffers
    private var branchVertexBuffer: MTLBuffer?
    private var branchIndexBuffer: MTLBuffer?
    private var branchIndexCount = 0
    private var edgeStateBuffers: [MTLBuffer] = []
    private var nodeBuffers: [MTLBuffer] = []
    private var clusterBuffer: MTLBuffer?
    private var clusterCount = 0
    private var starBuffer: MTLBuffer?
    private var moteBuffer: MTLBuffer?

    // CPU copies
    private(set) var scene: UniverseSceneData?
    private var baseNodes: [NodeInstance] = []
    private var baseEdgeStates: [SIMD4<Float>] = []
    private var nodeSlot: [Int32: Int] = [:]

    // Post-processing targets
    private var hdrTexture: MTLTexture?
    private var brightTexture: MTLTexture?
    private var blurTexture: MTLTexture?
    private var blur: MPSImageGaussianBlur?

    var camera = OrbitCamera()
    var quality: RenderQuality = .balanced { didSet { if oldValue != quality { qualityChanged() } } }
    var overridesProvider: ((Double, Float) -> FrameOverrides)?
    var onFrameTime: ((Double) -> Void)?

    private let startTime = CACurrentMediaTime()
    private var lastFrame = CACurrentMediaTime()
    private(set) var lastViewProj = matrix_identity_float4x4
    private var drawableSize = CGSize(width: 1, height: 1)

    var shaderTime: Float { Float(CACurrentMediaTime() - startTime) }

    init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        super.init()
        view.device = device
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .invalid
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = quality.preferredFPS
        do { try buildPipelines(viewFormat: view.colorPixelFormat) } catch {
            print("CosmicRenderer pipeline error: \(error)")
            return nil
        }
        qualityChanged()
    }

    // MARK: Setup

    private func buildPipelines(viewFormat: MTLPixelFormat) throws {
        guard let library = device.makeDefaultLibrary() else { throw NSError(domain: "Metal", code: 1) }
        func make(_ v: String, _ f: String, format: MTLPixelFormat, additive: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: v)
            d.fragmentFunction = library.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = format
            if additive {
                let a = d.colorAttachments[0]!
                a.isBlendingEnabled = true
                a.rgbBlendOperation = .add
                a.alphaBlendOperation = .add
                a.sourceRGBBlendFactor = .one
                a.destinationRGBBlendFactor = .one
                a.sourceAlphaBlendFactor = .one
                a.destinationAlphaBlendFactor = .one
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        backgroundPipeline = try make("fullscreen_vertex", "background_fragment", format: .rgba16Float, additive: false)
        branchPipeline = try make("branch_vertex", "branch_fragment", format: .rgba16Float, additive: true)
        nodePipeline = try make("node_vertex", "node_fragment", format: .rgba16Float, additive: true)
        particlePipeline = try make("particle_vertex", "particle_fragment", format: .rgba16Float, additive: true)
        brightPipeline = try make("fullscreen_vertex", "bright_fragment", format: .rgba16Float, additive: false)
        compositePipeline = try make("fullscreen_vertex", "composite_fragment", format: viewFormat, additive: false)
    }

    private func qualityChanged() {
        var rng = SplitMix64(seed: 99)
        func sphere(_ count: Int, rMin: Float, rMax: Float, size: ClosedRange<Float>) -> [SIMD4<Float>] {
            (0..<count).map { _ in
                let u = Float.random(in: -1...1, using: &rng), th = Float.random(in: 0..<(2 * .pi), using: &rng)
                let s = sqrt(1 - u * u)
                let r = Float.random(in: rMin...rMax, using: &rng)
                return SIMD4(SIMD3(s * cos(th), u, s * sin(th)) * r, Float.random(in: size, using: &rng))
            }
        }
        let stars = sphere(quality.starCount, rMin: 1500, rMax: 2500, size: 1.5...5)
        let motes = sphere(quality.moteCount, rMin: 5, rMax: 260, size: 0.15...0.6)
        starBuffer = device.makeBuffer(bytes: stars, length: max(16, stars.count * 16))
        moteBuffer = device.makeBuffer(bytes: motes, length: max(16, motes.count * 16))
        blur = MPSImageGaussianBlur(device: device, sigma: Float(3 + quality.bloomPasses * 3))
        blur?.edgeMode = .clamp
        brightTexture = nil   // reallocated at next draw
    }

    /// Uploads a new scene (call after layout or filter changes; cheap enough for interactive filtering).
    func upload(_ scene: UniverseSceneData) {
        self.scene = scene
        baseNodes = scene.nodes
        nodeSlot = Dictionary(uniqueKeysWithValues: scene.nodeIndices.enumerated().map { ($1, $0) })
        baseEdgeStates = Array(repeating: SIMD4(0, 1, -1000, 0), count: max(1, scene.edgeSlots.count))
        if !scene.branchVertices.isEmpty {
            branchVertexBuffer = device.makeBuffer(bytes: scene.branchVertices, length: scene.branchVertices.count * MemoryLayout<BranchVertex>.stride, options: .storageModeShared)
            branchIndexBuffer = device.makeBuffer(bytes: scene.branchIndices, length: scene.branchIndices.count * 4, options: .storageModeShared)
            branchIndexCount = scene.branchIndices.count
        } else {
            branchVertexBuffer = nil; branchIndexBuffer = nil; branchIndexCount = 0
        }
        let nodeBytes = max(48, scene.nodes.count * MemoryLayout<NodeInstance>.stride)
        let edgeBytes = max(16, baseEdgeStates.count * 16)
        nodeBuffers = (0..<Self.maxInFlight).compactMap { _ in device.makeBuffer(length: nodeBytes, options: .storageModeShared) }
        edgeStateBuffers = (0..<Self.maxInFlight).compactMap { _ in device.makeBuffer(length: edgeBytes, options: .storageModeShared) }
        let clusters = scene.clusters.map { c in
            NodeInstance(position: SIMD4(c.centroid, min(40, c.radius * 0.6 + Float(c.memberCount).squareRoot())),
                         color: SIMD4(0.35, 0.45, 1.0, 1) * 0.5, params: SIMD4(0, -1, 0, 0))
        }
        clusterCount = clusters.count
        clusterBuffer = clusters.isEmpty ? nil : device.makeBuffer(bytes: clusters, length: clusters.count * MemoryLayout<NodeInstance>.stride)
    }

    /// Persistent highlight for selected person (edges touching them glow).
    func setBaseEdgeState(slot: Int, _ state: SIMD4<Float>) {
        guard slot < baseEdgeStates.count else { return }
        baseEdgeStates[slot] = state
    }

    func resetBaseEdgeStates() {
        for i in baseEdgeStates.indices { baseEdgeStates[i] = SIMD4(0, 1, -1000, 0) }
    }

    func setBaseNodeHighlight(_ highlighted: Set<Int32>) {
        guard let scene else { return }
        for (i, idx) in scene.nodeIndices.enumerated() { baseNodes[i].params.x = highlighted.contains(idx) ? 1 : 0 }
    }

    func position(ofNode index: Int32) -> SIMD3<Float>? {
        guard let s = nodeSlot[index] else { return nil }
        let p = baseNodes[s].position
        return SIMD3(p.x, p.y, p.z)
    }

    // MARK: Picking

    /// Returns the graph node index nearest to `point` (in view points) within 32pt.
    func pick(point: CGPoint, viewSize: CGSize) -> Int32? {
        guard let scene, viewSize.width > 0 else { return nil }
        var best: (Int32, CGFloat)? = nil
        for (i, n) in baseNodes.enumerated() {
            let clip = lastViewProj * SIMD4(n.position.x, n.position.y, n.position.z, 1)
            guard clip.w > 0 else { continue }
            let ndc = SIMD2(clip.x / clip.w, clip.y / clip.w)
            let sp = CGPoint(x: CGFloat(ndc.x + 1) * 0.5 * viewSize.width, y: CGFloat(1 - ndc.y) * 0.5 * viewSize.height)
            let d = hypot(sp.x - point.x, sp.y - point.y)
            if d < 32, d < (best?.1 ?? .greatestFiniteMagnitude) { best = (scene.nodeIndices[i], d) }
        }
        return best?.0
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
        hdrTexture = nil
        brightTexture = nil
    }

    private func ensureTargets(size: CGSize) {
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        if hdrTexture?.width != w || hdrTexture?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            hdrTexture = device.makeTexture(descriptor: d)
            brightTexture = nil
        }
        if brightTexture == nil {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: max(1, w / 2), height: max(1, h / 2), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead, .shaderWrite]
            d.storageMode = .private
            brightTexture = device.makeTexture(descriptor: d)
            blurTexture = device.makeTexture(descriptor: d)
        }
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(0.1, now - lastFrame))
        onFrameTime?(now - lastFrame)
        lastFrame = now
        inFlight.wait()
        guard let drawable = view.currentDrawable, let cmd = queue.makeCommandBuffer() else { inFlight.signal(); return }
        let semaphore = inFlight
        cmd.addCompletedHandler { _ in semaphore.signal() }
        let size = view.drawableSize
        ensureTargets(size: size)
        guard let hdr = hdrTexture, let bright = brightTexture, let blurred = blurTexture else { cmd.commit(); return }

        camera.update(dt: dt)
        let time = shaderTime
        let overrides = overridesProvider?(now, time) ?? FrameOverrides()
        frameIndex = (frameIndex + 1) % Self.maxInFlight

        // Per-frame node and edge state (ring-buffered so the GPU never reads a buffer being written).
        if !nodeBuffers.isEmpty, !baseNodes.isEmpty, let scene {
            let ptr = nodeBuffers[frameIndex].contents().bindMemory(to: NodeInstance.self, capacity: baseNodes.count)
            for i in 0..<baseNodes.count {
                var n = baseNodes[i]
                if let h = overrides.nodeHighlight[scene.nodeIndices[i]] { n.params.x = max(n.params.x, h) }
                ptr[i] = n
            }
        }
        if !edgeStateBuffers.isEmpty {
            let ptr = edgeStateBuffers[frameIndex].contents().bindMemory(to: SIMD4<Float>.self, capacity: baseEdgeStates.count)
            for i in 0..<baseEdgeStates.count { ptr[i] = overrides.edgeStates[i] ?? baseEdgeStates[i] }
        }

        let aspect = Float(size.width / max(1, size.height))
        let viewM = camera.viewMatrix()
        let proj = camera.projectionMatrix(aspect: aspect)
        let viewProj = proj * viewM
        lastViewProj = viewProj
        let right = SIMD3(viewM.columns.0.x, viewM.columns.1.x, viewM.columns.2.x)
        let up = SIMD3(viewM.columns.0.y, viewM.columns.1.y, viewM.columns.2.y)
        var uniforms = CosmicUniforms(
            viewProj: viewProj, view: viewM, cameraPos: SIMD4(camera.position, time),
            viewport: SIMD4(Float(size.width), Float(size.height), 1 / Float(max(1, size.width)), 1 / Float(max(1, size.height))),
            params: SIMD4(camera.distance, quality.depthOfField ? 0.9 : 0, overrides.dim, quality == .performance ? 0.7 : 1.0),
            cameraRight: SIMD4(right, 0), cameraUp: SIMD4(up, 0))

        // 1. HDR scene pass
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = hdr
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
            enc.setRenderPipelineState(backgroundPipeline)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<CosmicUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            enc.setRenderPipelineState(particlePipeline)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<CosmicUniforms>.stride, index: 1)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<CosmicUniforms>.stride, index: 0)
            for (buffer, count, mote) in [(starBuffer, quality.starCount, Float(0)), (moteBuffer, quality.moteCount, Float(1))] {
                guard let buffer, count > 0 else { continue }
                var m = mote
                enc.setVertexBuffer(buffer, offset: 0, index: 0)
                enc.setVertexBytes(&m, length: 4, index: 2)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count)
            }

            enc.setRenderPipelineState(nodePipeline)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<CosmicUniforms>.stride, index: 1)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<CosmicUniforms>.stride, index: 0)
            if let clusterBuffer, clusterCount > 0 {
                enc.setVertexBuffer(clusterBuffer, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: clusterCount)
            }

            if let vb = branchVertexBuffer, let ib = branchIndexBuffer, branchIndexCount > 0, !edgeStateBuffers.isEmpty {
                enc.setRenderPipelineState(branchPipeline)
                enc.setVertexBuffer(vb, offset: 0, index: 0)
                enc.setVertexBytes(&uniforms, length: MemoryLayout<CosmicUniforms>.stride, index: 1)
                enc.setVertexBuffer(edgeStateBuffers[frameIndex], offset: 0, index: 2)
                enc.setFragmentBytes(&uniforms, length: MemoryLayout<CosmicUniforms>.stride, index: 0)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: branchIndexCount, indexType: .uint32, indexBuffer: ib, indexBufferOffset: 0)
            }

            if !baseNodes.isEmpty, !nodeBuffers.isEmpty {
                enc.setRenderPipelineState(nodePipeline)
                enc.setVertexBuffer(nodeBuffers[frameIndex], offset: 0, index: 0)
                enc.setVertexBytes(&uniforms, length: MemoryLayout<CosmicUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: baseNodes.count)
            }
            enc.endEncoding()
        }

        // 2. Bright pass at half resolution
        let bp = MTLRenderPassDescriptor()
        bp.colorAttachments[0].texture = bright
        bp.colorAttachments[0].loadAction = .dontCare
        bp.colorAttachments[0].storeAction = .store
        if let enc = cmd.makeRenderCommandEncoder(descriptor: bp) {
            enc.setRenderPipelineState(brightPipeline)
            enc.setFragmentTexture(hdr, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // 3. Gaussian bloom (Metal Performance Shaders)
        blur?.encode(commandBuffer: cmd, sourceTexture: bright, destinationTexture: blurred)

        // 4. Composite + tonemap to the drawable
        if let rp = view.currentRenderPassDescriptor, let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
            enc.setRenderPipelineState(compositePipeline)
            enc.setFragmentTexture(hdr, index: 0)
            enc.setFragmentTexture(blurred, index: 1)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<CosmicUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        cmd.present(drawable)
        cmd.commit()
    }
}
