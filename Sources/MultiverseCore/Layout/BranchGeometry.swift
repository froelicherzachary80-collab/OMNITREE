import Foundation

/// Rendering quality tiers. Drives geometry density, particles, bloom and frame budget.
public enum RenderQuality: String, CaseIterable, Codable, Sendable {
    case performance, balanced, cinematic, ultra

    public var displayName: String { rawValue.capitalized }
    public var segmentsPerBranch: Int { [.performance: 10, .balanced: 18, .cinematic: 28, .ultra: 40][self]! }
    public var tendrilsPerBranch: Int { [.performance: 0, .balanced: 1, .cinematic: 3, .ultra: 5][self]! }
    public var starCount: Int { [.performance: 1500, .balanced: 4000, .cinematic: 9000, .ultra: 16000][self]! }
    public var moteCount: Int { [.performance: 300, .balanced: 1200, .cinematic: 3000, .ultra: 6000][self]! }
    public var bloomPasses: Int { [.performance: 1, .balanced: 2, .cinematic: 3, .ultra: 4][self]! }
    public var maxVisibleNodes: Int { [.performance: 1500, .balanced: 4000, .cinematic: 8000, .ultra: 15000][self]! }
    public var maxVisibleEdges: Int { [.performance: 4000, .balanced: 12000, .cinematic: 25000, .ultra: 45000][self]! }
    public var depthOfField: Bool { self == .cinematic || self == .ultra }
    public var preferredFPS: Int { self == .ultra ? 120 : 60 }

    public var lower: RenderQuality? {
        switch self { case .ultra: return .cinematic; case .cinematic: return .balanced; case .balanced: return .performance; case .performance: return nil }
    }
}

/// GPU vertex for one branch ribbon vertex. Four float4s → identical layout in Swift and MSL.
public struct BranchVertex: Sendable {
    /// xyz = centre-line position, w = t along branch (0…1)
    public var position: SIMD4<Float>
    /// xyz = tangent, w = side (−1 / +1) for screen-space ribbon expansion
    public var tangent: SIMD4<Float>
    /// rgb = glow accent, a = base intensity
    public var color: SIMD4<Float>
    /// x = width, y = edge index (into per-edge state buffer), z = kind (0 branch, 1 tendril), w = established (1) / candidate (0)
    public var params: SIMD4<Float>
}

/// Instance data for one person node.
public struct NodeInstance: Sendable {
    /// xyz = position, w = size
    public var position: SIMD4<Float>
    public var color: SIMD4<Float>
    /// x = highlight (0…1), y = node index, z = pulse phase, w = dimmed (1 = dim)
    public var params: SIMD4<Float>
}

public enum CosmicPalette {
    public static func color(for category: RelationshipCategory) -> SIMD4<Float> {
        switch category {
        case .family: return SIMD4(0.25, 0.55, 1.0, 1)        // electric blue
        case .creator: return SIMD4(0.95, 0.30, 0.90, 1)       // magenta filament
        case .entertainment: return SIMD4(0.62, 0.42, 1.0, 1)  // violet
        case .historical: return SIMD4(0.55, 0.95, 1.0, 1)     // pale cyan
        case .social: return SIMD4(0.30, 0.85, 1.0, 1)         // cyan-blue
        }
    }

    public static func nodeColor(for categories: Set<PersonCategory>) -> SIMD4<Float> {
        if categories.contains(.minecraftCreator) { return SIMD4(0.55, 1.0, 0.75, 1) }
        if categories.contains(.youtuber) || categories.contains(.twitchStreamer) { return SIMD4(1.0, 0.45, 0.85, 1) }
        if categories.contains(.actor) || categories.contains(.musician) || categories.contains(.director) { return SIMD4(0.75, 0.6, 1.0, 1) }
        if categories.contains(.historicalFigure) || categories.contains(.politicalOrRoyal) { return SIMD4(0.6, 0.95, 1.0, 1) }
        if categories.contains(.familyMember) { return SIMD4(0.45, 0.7, 1.0, 1) }
        if categories.contains(.friend) { return SIMD4(0.4, 1.0, 1.0, 1) }
        return SIMD4(0.85, 0.92, 1.0, 1)
    }
}

/// Procedural organic branch geometry: curved, gently noisy centre-lines with thin tendrils.
public enum BranchGeometry {
    /// Smooth value noise in [-1, 1] for organic wobble.
    static func noise(_ x: Float, seed: UInt32) -> Float {
        func hash(_ i: Int32) -> Float {
            var h = UInt32(bitPattern: i) &* 374_761_393 &+ seed &* 668_265_263
            h = (h ^ (h >> 13)) &* 1_274_126_177
            return Float(h & 0xFFFF) / 32767.5 - 1
        }
        let i = Int32(x.rounded(.down)), f = x - Float(i)
        let u = f * f * (3 - 2 * f)
        return hash(i) * (1 - u) + hash(i + 1) * u
    }

    /// Centre-line of a branch between two nodes.
    public static func centerline(from a: SIMD3<Float>, to b: SIMD3<Float>, seed: UInt32, segments: Int) -> [SIMD3<Float>] {
        let d = b - a
        let length = vlen(d)
        guard length > 1e-4 else { return [a, b] }
        let dir = d / length
        let helper: SIMD3<Float> = abs(dir.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let n1 = vnorm(vcross(dir, helper))
        let n2 = vcross(dir, n1)
        let bend = Float(seed % 1000) / 1000 * 2 * .pi
        let bendDir = n1 * cos(bend) + n2 * sin(bend)
        let amp = length * 0.18
        let c1 = a + d * 0.33 + bendDir * amp
        let c2 = a + d * 0.66 + bendDir * amp * 0.6
        let segs = max(2, segments)
        return (0...segs).map { s in
            let t = Float(s) / Float(segs)
            let mt = 1 - t
            let w0: Float = mt * mt * mt, w1: Float = 3 * mt * mt * t, w2: Float = 3 * mt * t * t, w3: Float = t * t * t
            var p: SIMD3<Float> = a * w0
            p += c1 * w1
            p += c2 * w2
            p += b * w3
            // Organic wobble, zero at both endpoints so branches meet their nodes exactly.
            let envelope: Float = sin(t * .pi) * length * 0.035
            let wobble: SIMD3<Float> = n1 * noise(t * 4, seed: seed) + n2 * noise(t * 4 + 17, seed: seed &+ 11)
            p += wobble * envelope
            return p
        }
    }

    /// Thin secondary tendrils sprouting from a centre-line.
    public static func tendrils(along line: [SIMD3<Float>], count: Int, seed: UInt32) -> [[SIMD3<Float>]] {
        guard count > 0, line.count > 3 else { return [] }
        var rng = SplitMix64(seed: UInt64(seed) &* 2654435761)
        let total = zip(line, line.dropFirst()).reduce(Float(0)) { $0 + vlen($1.1 - $1.0) }
        var result: [[SIMD3<Float>]] = []
        for _ in 0..<count {
            let idx = Int.random(in: 1..<(line.count - 2), using: &rng)
            let origin: SIMD3<Float> = line[idx]
            let tangent: SIMD3<Float> = vnorm(line[idx + 1] - line[idx - 1])
            let rx = Float.random(in: -1...1, using: &rng), ry = Float.random(in: -1...1, using: &rng), rz = Float.random(in: -1...1, using: &rng)
            let out: SIMD3<Float> = vnorm(vcross(tangent, vnorm(SIMD3<Float>(rx, ry, rz))))
            let len: Float = total * Float.random(in: 0.06...0.16, using: &rng)
            let heading: SIMD3<Float> = tangent * 0.6 + out
            var pts: [SIMD3<Float>] = []
            for s in 0...6 {
                let t = Float(s) / 6
                let straight: SIMD3<Float> = heading * (len * t)
                let curl: SIMD3<Float> = out * (len * 0.3 * t * t)
                pts.append(origin + straight + curl)
            }
            result.append(pts)
        }
        return result
    }

    /// Appends a camera-facing ribbon (expanded in the vertex shader) as an indexed triangle list.
    public static func appendRibbon(_ line: [SIMD3<Float>], width: Float, color: SIMD4<Float>, edgeIndex: Int, kind: Float,
                                    established: Bool, vertices: inout [BranchVertex], indices: inout [UInt32]) {
        guard line.count >= 2 else { return }
        let base = UInt32(vertices.count)
        for (i, p) in line.enumerated() {
            let prev = line[max(0, i - 1)], next = line[min(line.count - 1, i + 1)]
            let tan = vnorm(next - prev)
            let t = Float(i) / Float(line.count - 1)
            for side: Float in [-1, 1] {
                vertices.append(BranchVertex(position: SIMD4(p, t), tangent: SIMD4(tan, side), color: color,
                                             params: SIMD4(width, Float(edgeIndex), kind, established ? 1 : 0)))
            }
        }
        for i in 0..<UInt32(line.count - 1) {
            let v = base + i * 2
            indices += [v, v + 1, v + 2, v + 1, v + 3, v + 2]
        }
    }
}
