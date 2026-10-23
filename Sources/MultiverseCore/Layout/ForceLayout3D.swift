import Foundation

/// 3D force-directed layout with spatial hashing (O(n) per iteration) and community-seeded
/// initial placement so related branches grow together into "galaxies".
public struct ForceLayout3D {
    public var idealEdgeLength: Float = 6
    public var repulsion: Float = 40
    public var gravity: Float = 0.015
    public var damping: Float = 0.85
    public var maxStep: Float = 3

    public init() {}

    /// Initial positions: each community is placed on a Fibonacci sphere; members scatter around it.
    public func seedPositions(count: Int, communities: [Int32], existing: [Int: SIMD3<Float>] = [:], seed: UInt64 = 7) -> [SIMD3<Float>] {
        var rng = SplitMix64(seed: seed)
        let labels = Array(Set(communities)).sorted()
        let centerIndex = Dictionary(uniqueKeysWithValues: labels.enumerated().map { ($1, $0) })
        let radius = Float(max(10, cbrt(Double(count)) * 9))
        func fib(_ i: Int, _ n: Int) -> SIMD3<Float> {
            let phi = Float.pi * (3 - sqrt(5))
            let y = n <= 1 ? 0 : 1 - Float(i) / Float(n - 1) * 2
            let r = sqrt(max(0, 1 - y * y))
            let theta = phi * Float(i)
            return SIMD3(cos(theta) * r, y, sin(theta) * r)
        }
        return (0..<count).map { i in
            if let p = existing[i] { return p }
            let c = centerIndex[communities.isEmpty ? 0 : communities[i]] ?? 0
            let center = labels.count <= 1 ? .zero : fib(c, labels.count) * radius
            let jitter = SIMD3<Float>(Float.random(in: -1...1, using: &rng), Float.random(in: -1...1, using: &rng), Float.random(in: -1...1, using: &rng))
            return center + jitter * idealEdgeLength * 1.5
        }
    }

    /// Runs the simulation. `pinned` nodes keep their positions (e.g. already-placed nodes when new branches grow).
    public func run(graph: GraphIndex, positions initial: [SIMD3<Float>], iterations: Int = 300,
                    pinned: Set<Int32> = [], edgeFilter: EdgeFilter = .includingCandidates) -> [SIMD3<Float>] {
        let n = graph.nodeCount
        guard n > 0 else { return [] }
        var pos = initial
        var vel = [SIMD3<Float>](repeating: .zero, count: n)
        let cell = idealEdgeLength * 2
        var temperature: Float = 1

        for _ in 0..<iterations {
            var force = [SIMD3<Float>](repeating: .zero, count: n)
            // Spatial hash for short-range repulsion.
            var grid: [SIMD3<Int32>: [Int]] = [:]
            grid.reserveCapacity(n)
            for i in 0..<n {
                let k = SIMD3<Int32>(Int32((pos[i].x / cell).rounded(.down)), Int32((pos[i].y / cell).rounded(.down)), Int32((pos[i].z / cell).rounded(.down)))
                grid[k, default: []].append(i)
            }
            for (key, members) in grid {
                for dx in -1...1 { for dy in -1...1 { for dz in -1...1 {
                    guard let others = grid[key &+ SIMD3(Int32(dx), Int32(dy), Int32(dz))] else { continue }
                    for i in members {
                        for j in others where j != i {
                            var d = pos[i] - pos[j]
                            var dist2 = vlen2(d)
                            if dist2 < 1e-4 { d = SIMD3(Float(i % 7) - 3, Float(j % 5) - 2, 1) * 0.01; dist2 = 1e-4 }
                            force[i] += d / dist2 * repulsion / sqrt(dist2)
                        }
                    }
                }}}
            }
            // Springs along edges.
            for e in graph.edges where edgeFilter.allows(e) {
                let a = Int(e.from), b = Int(e.to)
                let d = pos[b] - pos[a]
                let dist = max(0.01, vlen(d))
                let strength: Float = e.type.category == .family ? 1.4 : 0.8
                let f = d / dist * (dist - idealEdgeLength) * 0.05 * strength
                force[a] += f
                force[b] -= f
            }
            for i in 0..<n {
                if pinned.contains(Int32(i)) { continue }
                force[i] -= pos[i] * gravity
                vel[i] = (vel[i] + force[i]) * damping
                let speed = vlen(vel[i])
                let limit = maxStep * temperature
                if speed > limit { vel[i] *= limit / speed }
                pos[i] += vel[i]
            }
            temperature = max(0.05, temperature * 0.985)
        }
        return pos
    }
}

@inline(__always) func vlen2(_ v: SIMD3<Float>) -> Float { (v * v).sum() }
@inline(__always) func vlen(_ v: SIMD3<Float>) -> Float { sqrt((v * v).sum()) }
@inline(__always) func vnorm(_ v: SIMD3<Float>) -> SIMD3<Float> {
    let l = vlen(v); return l > 1e-6 ? v / l : SIMD3(0, 1, 0)
}
@inline(__always) func vcross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
