import Foundation

/// Per-person attributes needed for filtering without touching SQLite every frame.
public struct NodeAttributes: Sendable {
    public var name: String
    public var categories: Set<PersonCategory>
    public var country: String?
    public var birthYear: Int?
    public var communities: Set<EntityID>
    public var isPrivate: Bool
    public var isSample: Bool
}

/// Exploration filters: universe modes (unioned) plus relationship / person / date / country /
/// quality / verification / community / graph-distance filters.
public struct UniverseFilter: Sendable, Equatable {
    public var modes: Set<UniverseMode> = [.entireMultiverse]
    public var personCategories: Set<PersonCategory>? = nil
    public var relationshipCategories: Set<RelationshipCategory>? = nil
    public var relationshipTypes: Set<RelationshipType>? = nil
    public var statuses: Set<VerificationStatus> = [.verified, .sourced, .userAsserted, .candidate]
    public var yearRange: ClosedRange<Int>? = nil
    public var country: String? = nil
    public var community: EntityID? = nil
    public var minSourceReliability: Double = 0
    /// Only show nodes within this many hops of `focus`.
    public var maxDistance: Int? = nil
    public var focus: EntityID? = nil
    public var showSampleData = true

    public init() {}

    public var edgeFilter: EdgeFilter {
        EdgeFilter(categories: relationshipCategories, types: relationshipTypes, statuses: statuses,
                   minReliability: minSourceReliability, yearRange: yearRange)
    }

    func modeAllows(_ cats: Set<PersonCategory>) -> Bool {
        if modes.contains(.entireMultiverse) || modes.contains(.customResearch) || modes.isEmpty { return true }
        return modes.contains { m in m.categories.map { !$0.isDisjoint(with: cats) } ?? true }
    }

    /// Node visibility mask.
    public func visibleNodes(graph: GraphIndex, attributes: [NodeAttributes]) -> [Bool] {
        var mask = attributes.map { a -> Bool in
            if !showSampleData && a.isSample { return false }
            if !modeAllows(a.categories) { return false }
            if let pc = personCategories, pc.isDisjoint(with: a.categories) { return false }
            if let c = country, a.country?.localizedCaseInsensitiveContains(c) != true { return false }
            if let comm = community, !a.communities.contains(comm) { return false }
            if let yr = yearRange, let b = a.birthYear, !yr.contains(b) && b > yr.upperBound { return false }
            return true
        }
        if let max = maxDistance, let focus, let f = graph.index(of: focus) {
            let dist = PathFinder(graph: graph).bfsDistances(from: f, filter: edgeFilter, maxDepth: max)
            for i in 0..<mask.count where dist[i] > max { mask[i] = false }
        }
        return mask
    }
}

/// Clustered summary for progressive disclosure: nodes outside the render budget collapse into these.
public struct ClusterSummary: Sendable {
    public let label: Int32
    public let centroid: SIMD3<Float>
    public let memberCount: Int
    public let radius: Float
}

/// Picks what to render: every highlighted/focused node, their neighbourhood, then the
/// highest-degree nodes nearest the camera — up to the quality budget. The rest are clusters.
public enum ViewportSelector {
    public static func select(graph: GraphIndex, positions: [SIMD3<Float>], visible: [Bool], communities: [Int32],
                              cameraPosition: SIMD3<Float>, mustInclude: Set<Int32>, budget: Int) -> (nodes: [Int32], clusters: [ClusterSummary]) {
        let n = graph.nodeCount
        guard n > 0 else { return ([], []) }
        var chosen = Set<Int32>()
        for m in mustInclude where Int(m) < n && visible[Int(m)] { chosen.insert(m) }
        for m in mustInclude where Int(m) < n {
            for nb in graph.neighbors(of: m) where visible[Int(nb.node)] && chosen.count < budget { chosen.insert(nb.node) }
        }
        if chosen.count < budget {
            // Score = degree weight / distance to camera.
            let scored = (0..<n).compactMap { i -> (Int32, Float)? in
                guard visible[i], !chosen.contains(Int32(i)) else { return nil }
                let d = max(1, vlen(positions[i] - cameraPosition))
                return (Int32(i), (1 + log(Float(graph.degree(of: Int32(i)) + 1))) / d)
            }.sorted { $0.1 > $1.1 }
            for (i, _) in scored.prefix(budget - chosen.count) { chosen.insert(i) }
        }
        var groups: [Int32: (sum: SIMD3<Float>, count: Int, pts: [SIMD3<Float>])] = [:]
        for i in 0..<n where visible[i] && !chosen.contains(Int32(i)) {
            let label = communities.isEmpty ? 0 : communities[i]
            var g = groups[label] ?? (.zero, 0, [])
            g.sum += positions[i]; g.count += 1
            if g.pts.count < 64 { g.pts.append(positions[i]) }
            groups[label] = g
        }
        let clusters = groups.map { label, g -> ClusterSummary in
            let c = g.sum / Float(g.count)
            let r = g.pts.map { vlen($0 - c) }.max() ?? 1
            return ClusterSummary(label: label, centroid: c, memberCount: g.count, radius: max(1, r))
        }
        return (Array(chosen).sorted(), clusters)
    }
}

/// CPU-side scene description handed to the Metal renderer.
public struct UniverseSceneData: Sendable {
    public var nodeIndices: [Int32]
    public var nodes: [NodeInstance]
    public var branchVertices: [BranchVertex]
    public var branchIndices: [UInt32]
    /// Graph edge index for each scene edge slot (the renderer's per-edge state buffer is indexed by slot).
    public var edgeSlots: [Int32]
    public var clusters: [ClusterSummary]
}

public enum UniverseSceneBuilder {
    public static func build(graph: GraphIndex, positions: [SIMD3<Float>], attributes: [NodeAttributes], filter: UniverseFilter,
                             communities: [Int32], cameraPosition: SIMD3<Float>, highlighted: Set<Int32>,
                             quality: RenderQuality) -> UniverseSceneData {
        let visible = filter.visibleNodes(graph: graph, attributes: attributes)
        let (chosen, clusters) = ViewportSelector.select(graph: graph, positions: positions, visible: visible, communities: communities,
                                                         cameraPosition: cameraPosition, mustInclude: highlighted, budget: quality.maxVisibleNodes)
        let chosenSet = Set(chosen)
        let edgeFilter = filter.edgeFilter
        var vertices: [BranchVertex] = [], indices: [UInt32] = [], slots: [Int32] = []
        vertices.reserveCapacity(min(graph.edgeCount, quality.maxVisibleEdges) * (quality.segmentsPerBranch + 1) * 2)
        // Highlighted edges first so they're never cut by the edge budget.
        let candidateEdges = graph.edges.indices.filter { i in
            let e = graph.edges[i]
            return chosenSet.contains(e.from) && chosenSet.contains(e.to) && edgeFilter.allows(e)
        }.sorted { a, b in
            let ha = highlighted.contains(graph.edges[a].from) && highlighted.contains(graph.edges[a].to)
            let hb = highlighted.contains(graph.edges[b].from) && highlighted.contains(graph.edges[b].to)
            return ha && !hb
        }
        for ei in candidateEdges.prefix(quality.maxVisibleEdges) {
            let e = graph.edges[ei]
            let slot = slots.count
            slots.append(Int32(ei))
            let seed = stableHash(e.id)
            let line = BranchGeometry.centerline(from: positions[Int(e.from)], to: positions[Int(e.to)], seed: seed,
                                                 segments: quality.segmentsPerBranch)
            let color = CosmicPalette.color(for: e.type.category)
            let width: Float = e.verification.isEstablished ? 0.22 + 0.18 * Float(e.strength) : 0.12
            BranchGeometry.appendRibbon(line, width: width, color: color, edgeIndex: slot, kind: 0,
                                        established: e.verification.isEstablished, vertices: &vertices, indices: &indices)
            for t in BranchGeometry.tendrils(along: line, count: quality.tendrilsPerBranch, seed: seed) {
                BranchGeometry.appendRibbon(t, width: width * 0.35, color: color * SIMD4(0.8, 0.9, 1, 0.6), edgeIndex: slot, kind: 1,
                                            established: e.verification.isEstablished, vertices: &vertices, indices: &indices)
            }
        }
        let nodes = chosen.map { i -> NodeInstance in
            let deg = Float(graph.degree(of: i))
            let size = 0.6 + min(2.2, log(deg + 1) * 0.45)
            return NodeInstance(position: SIMD4(positions[Int(i)], size), color: CosmicPalette.nodeColor(for: graph.categories[Int(i)]),
                                params: SIMD4(highlighted.contains(i) ? 1 : 0, Float(i), Float(i % 97) / 97, 0))
        }
        return UniverseSceneData(nodeIndices: chosen, nodes: nodes, branchVertices: vertices, branchIndices: indices,
                                 edgeSlots: slots, clusters: clusters)
    }
}

/// FNV-1a — stable across launches (unlike `hashValue`) so each branch keeps its shape.
func stableHash(_ s: String) -> UInt32 {
    var h: UInt32 = 2_166_136_261
    for b in s.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
    return h
}
