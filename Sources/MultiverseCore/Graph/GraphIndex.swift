import Foundation

/// Compact in-memory traversal index (CSR adjacency) built from the SQLite graph.
/// Node and edge references are dense integer indices so million-node graphs stay cache-friendly.
public final class GraphIndex: @unchecked Sendable {
    public struct Edge: Sendable {
        public let id: EntityID
        public let from: Int32
        public let to: Int32
        public let type: RelationshipType
        public let verification: VerificationStatus
        public let confidence: Double
        /// Best reliability among the sources backing this edge.
        public let reliability: Double
        public let startYear: Int?
        public let endYear: Int?
        public let isInferred: Bool

        public func other(_ node: Int32) -> Int32 { from == node ? to : from }
        /// Evidence strength in (0, 1].
        public var strength: Double { max(1e-6, confidence * reliability) }
    }

    public struct Neighbor: Sendable {
        public let node: Int32
        public let edge: Int32
    }

    public let nodeIDs: [EntityID]
    public let edges: [Edge]
    public let categories: [Set<PersonCategory>]
    private let indexByID: [EntityID: Int32]
    private let offsets: [Int]
    private let neighbors: [Neighbor]

    init(nodeIDs: [EntityID], edges: [Edge], categories: [Set<PersonCategory>]) {
        self.nodeIDs = nodeIDs
        self.edges = edges
        self.categories = categories
        var map: [EntityID: Int32] = [:]
        map.reserveCapacity(nodeIDs.count)
        for (i, id) in nodeIDs.enumerated() { map[id] = Int32(i) }
        indexByID = map

        var degree = [Int](repeating: 0, count: nodeIDs.count)
        for e in edges { degree[Int(e.from)] += 1; degree[Int(e.to)] += 1 }
        var offs = [Int](repeating: 0, count: nodeIDs.count + 1)
        for i in 0..<nodeIDs.count { offs[i + 1] = offs[i] + degree[i] }
        var fill = offs
        var adj = [Neighbor](repeating: Neighbor(node: 0, edge: 0), count: offs[nodeIDs.count])
        for (ei, e) in edges.enumerated() {
            adj[fill[Int(e.from)]] = Neighbor(node: e.to, edge: Int32(ei)); fill[Int(e.from)] += 1
            adj[fill[Int(e.to)]] = Neighbor(node: e.from, edge: Int32(ei)); fill[Int(e.to)] += 1
        }
        offsets = offs
        neighbors = adj
    }

    public var nodeCount: Int { nodeIDs.count }
    public var edgeCount: Int { edges.count }

    public func index(of id: EntityID) -> Int32? { indexByID[id] }
    public func id(of index: Int32) -> EntityID { nodeIDs[Int(index)] }

    public func neighbors(of node: Int32) -> ArraySlice<Neighbor> {
        neighbors[offsets[Int(node)]..<offsets[Int(node) + 1]]
    }

    public func degree(of node: Int32) -> Int { offsets[Int(node) + 1] - offsets[Int(node)] }

    /// Parents via descent edges (parent → child), optionally including adoptive parents.
    public func parents(of node: Int32, includeAdoptive: Bool = true, filter: EdgeFilter = .established) -> [Int32] {
        neighbors(of: node).compactMap { n in
            let e = edges[Int(n.edge)]
            guard e.to == node, e.type == .parent || (includeAdoptive && e.type == .adoptiveParent), filter.allows(e) else { return nil }
            return e.from
        }
    }

    public func children(of node: Int32, includeAdoptive: Bool = true, filter: EdgeFilter = .established) -> [Int32] {
        neighbors(of: node).compactMap { n in
            let e = edges[Int(n.edge)]
            guard e.from == node, e.type == .parent || (includeAdoptive && e.type == .adoptiveParent), filter.allows(e) else { return nil }
            return e.to
        }
    }

    public final class Builder {
        private var ids: [EntityID] = []
        private var index: [EntityID: Int32] = [:]
        private var edges: [Edge] = []
        private var categoryMap: [EntityID: Set<PersonCategory>] = [:]

        public init() {}

        public func addNode(_ id: EntityID) {
            guard index[id] == nil else { return }
            index[id] = Int32(ids.count)
            ids.append(id)
        }

        public func setCategories(_ map: [EntityID: Set<PersonCategory>]) { categoryMap = map }

        public func addEdge(id: EntityID, from: EntityID, to: EntityID, type: RelationshipType, verification: VerificationStatus,
                            confidence: Double, reliability: Double = 0.8, startYear: Int? = nil, endYear: Int? = nil,
                            isInferred: Bool = false) {
            // Edges to nodes excluded from the index (e.g. private people in a public view) are dropped.
            guard let f = index[from], let t = index[to] else { return }
            edges.append(Edge(id: id, from: f, to: t, type: type, verification: verification, confidence: confidence,
                              reliability: reliability, startYear: startYear, endYear: endYear, isInferred: isInferred))
        }

        public func build() -> GraphIndex {
            GraphIndex(nodeIDs: ids, edges: edges, categories: ids.map { categoryMap[$0] ?? [] })
        }
    }
}

/// Which edges a traversal may use.
public struct EdgeFilter: Sendable {
    public var categories: Set<RelationshipCategory>?
    public var types: Set<RelationshipType>?
    public var excludedTypes: Set<RelationshipType>
    public var statuses: Set<VerificationStatus>
    public var minConfidence: Double
    public var minReliability: Double
    /// Edge must be active (overlap) within this year range when it has dates.
    public var yearRange: ClosedRange<Int>?
    public var allowInferred: Bool
    public var allowWeakAssociations: Bool

    public init(categories: Set<RelationshipCategory>? = nil, types: Set<RelationshipType>? = nil,
                excludedTypes: Set<RelationshipType> = [], statuses: Set<VerificationStatus> = [.verified, .sourced, .userAsserted],
                minConfidence: Double = 0, minReliability: Double = 0, yearRange: ClosedRange<Int>? = nil,
                allowInferred: Bool = true, allowWeakAssociations: Bool = true) {
        self.categories = categories; self.types = types; self.excludedTypes = excludedTypes; self.statuses = statuses
        self.minConfidence = minConfidence; self.minReliability = minReliability; self.yearRange = yearRange
        self.allowInferred = allowInferred; self.allowWeakAssociations = allowWeakAssociations
    }

    /// Only established (verified / sourced / user-provided) edges — the default for any claim shown as fact.
    public static let established = EdgeFilter()
    /// Includes candidates, for "possible connection — research required" exploration.
    public static let includingCandidates = EdgeFilter(statuses: [.verified, .sourced, .userAsserted, .candidate])
    public static let familyOnly = EdgeFilter(categories: [.family])
    public static let collaborationOnly = EdgeFilter(types: Set(RelationshipType.allCases.filter(\.isCollaboration)))

    public func allows(_ e: GraphIndex.Edge) -> Bool {
        guard statuses.contains(e.verification) else { return false }
        if let categories, !categories.contains(e.type.category) { return false }
        if let types, !types.contains(e.type) { return false }
        if excludedTypes.contains(e.type) { return false }
        if e.confidence < minConfidence || e.reliability < minReliability { return false }
        if !allowInferred && e.isInferred { return false }
        if !allowWeakAssociations && e.type.isWeakAssociation { return false }
        if let yr = yearRange {
            let s = e.startYear ?? Int.min, end = e.endYear ?? e.startYear ?? Int.max
            if e.startYear != nil || e.endYear != nil, end < yr.lowerBound || s > yr.upperBound { return false }
        }
        return true
    }
}
