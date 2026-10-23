import Foundation

/// A documented path through the graph. Every hop is a stored relationship — paths never contain invented edges.
public struct GraphPath: Sendable, Hashable {
    public let nodes: [Int32]
    public let edges: [Int32]

    public var hopCount: Int { edges.count }

    public func personIDs(in g: GraphIndex) -> [EntityID] { nodes.map(g.id(of:)) }
    public func relationshipIDs(in g: GraphIndex) -> [EntityID] { edges.map { g.edges[Int($0)].id } }

    /// Product of edge strengths — the joint confidence of the whole chain.
    public func strength(in g: GraphIndex) -> Double { edges.reduce(1.0) { $0 * g.edges[Int($1)].strength } }

    public func categories(in g: GraphIndex) -> Set<RelationshipCategory> { Set(edges.map { g.edges[Int($0)].type.category }) }
}

public struct ConnectionReport: Sendable {
    public let from: EntityID
    public let to: EntityID
    public let shortest: GraphPath?
    public let strongest: GraphPath?
    public let familyOnly: GraphPath?
    public let collaborationOnly: GraphPath?
    /// Alternative paths (K-shortest) that mix relationship categories.
    public let mixed: [GraphPath]
    /// Paths that exist only if unverified candidate edges are used. Shown as "Possible connection — research required".
    public let possibleViaCandidates: GraphPath?

    public var isConnected: Bool { shortest != nil }
}

public struct MultiConnectionReport: Sendable {
    public struct Pair: Sendable { public let a: EntityID; public let b: EntityID; public let path: GraphPath? }
    public let people: [EntityID]
    public let pairs: [Pair]
    /// Union of all pairwise shortest paths: a compact shared connection network.
    public let networkNodes: Set<Int32>
    public let networkEdges: Set<Int32>
    public var disconnectedPairs: [Pair] { pairs.filter { $0.path == nil } }
}

/// Graph algorithms over a `GraphIndex`: BFS, bidirectional BFS, Dijkstra, Yen's K-shortest paths,
/// connected components and label-propagation community detection.
public struct PathFinder: Sendable {
    public let graph: GraphIndex
    public init(graph: GraphIndex) { self.graph = graph }

    // MARK: Breadth-first

    /// Unweighted single-source BFS. Returns hop distances (Int.max = unreachable).
    public func bfsDistances(from source: Int32, filter: EdgeFilter = .established, maxDepth: Int = .max) -> [Int] {
        var dist = [Int](repeating: .max, count: graph.nodeCount)
        dist[Int(source)] = 0
        var queue = [source]
        var head = 0
        while head < queue.count {
            let u = queue[head]; head += 1
            let du = dist[Int(u)]
            if du >= maxDepth { continue }
            for n in graph.neighbors(of: u) where dist[Int(n.node)] == .max && filter.allows(graph.edges[Int(n.edge)]) {
                dist[Int(n.node)] = du + 1
                queue.append(n.node)
            }
        }
        return dist
    }

    /// Bidirectional BFS shortest path by number of edges.
    public func shortestPath(from a: Int32, to b: Int32, filter: EdgeFilter = .established,
                             bannedNodes: Set<Int32> = [], bannedEdges: Set<Int32> = []) -> GraphPath? {
        if a == b { return GraphPath(nodes: [a], edges: []) }
        // parent pointers: node -> (prevNode, edge)
        var prevA: [Int32: (Int32, Int32)] = [a: (-1, -1)]
        var prevB: [Int32: (Int32, Int32)] = [b: (-1, -1)]
        var frontierA = [a], frontierB = [b]

        func expand(_ frontier: inout [Int32], _ mine: inout [Int32: (Int32, Int32)], _ theirs: [Int32: (Int32, Int32)]) -> Int32? {
            var next: [Int32] = []
            var meet: Int32? = nil
            for u in frontier {
                for n in graph.neighbors(of: u) {
                    if mine[n.node] != nil || bannedNodes.contains(n.node) || bannedEdges.contains(n.edge) { continue }
                    guard filter.allows(graph.edges[Int(n.edge)]) else { continue }
                    mine[n.node] = (u, n.edge)
                    if theirs[n.node] != nil && meet == nil { meet = n.node }
                    next.append(n.node)
                }
                if meet != nil { break }
            }
            frontier = next
            return meet
        }

        while !frontierA.isEmpty && !frontierB.isEmpty {
            let meet: Int32?
            if frontierA.count <= frontierB.count { meet = expand(&frontierA, &prevA, prevB) }
            else { meet = expand(&frontierB, &prevB, prevA) }
            if let m = meet {
                var nodes: [Int32] = [m], edges: [Int32] = []
                var cur = m
                while let (p, e) = prevA[cur], p != -1 { nodes.insert(p, at: 0); edges.insert(e, at: 0); cur = p }
                cur = m
                while let (p, e) = prevB[cur], p != -1 { nodes.append(p); edges.append(e); cur = p }
                return GraphPath(nodes: nodes, edges: edges)
            }
        }
        return nil
    }

    // MARK: Weighted

    public enum Weighting: Sendable {
        /// Every hop costs 1.
        case hops
        /// Cost = −ln(strength) + 0.01, so the strongest documented chain is cheapest.
        case evidenceStrength
    }

    private func cost(_ e: GraphIndex.Edge, _ w: Weighting) -> Double {
        switch w {
        case .hops: return 1
        case .evidenceStrength: return -log(e.strength) + 0.01
        }
    }

    /// Dijkstra shortest path under the given weighting.
    public func dijkstra(from a: Int32, to b: Int32, weighting: Weighting = .evidenceStrength, filter: EdgeFilter = .established,
                         bannedNodes: Set<Int32> = [], bannedEdges: Set<Int32> = []) -> (path: GraphPath, cost: Double)? {
        var dist: [Int32: Double] = [a: 0]
        var prev: [Int32: (Int32, Int32)] = [:]
        var heap = MinHeap<(Double, Int32)> { $0.0 < $1.0 }
        heap.push((0, a))
        var done = Set<Int32>()
        while let (d, u) = heap.pop() {
            if done.contains(u) { continue }
            done.insert(u)
            if u == b { break }
            for n in graph.neighbors(of: u) {
                if bannedNodes.contains(n.node) || bannedEdges.contains(n.edge) || done.contains(n.node) { continue }
                let e = graph.edges[Int(n.edge)]
                guard filter.allows(e) else { continue }
                let nd = d + cost(e, weighting)
                if nd < dist[n.node] ?? .infinity {
                    dist[n.node] = nd
                    prev[n.node] = (u, n.edge)
                    heap.push((nd, n.node))
                }
            }
        }
        guard let total = dist[b], done.contains(b) else { return nil }
        var nodes: [Int32] = [b], edges: [Int32] = []
        var cur = b
        while cur != a, let (p, e) = prev[cur] { nodes.insert(p, at: 0); edges.insert(e, at: 0); cur = p }
        return (GraphPath(nodes: nodes, edges: edges), total)
    }

    private func pathCost(_ p: GraphPath, _ w: Weighting) -> Double {
        p.edges.reduce(0) { $0 + cost(graph.edges[Int($1)], w) }
    }

    /// Yen's K-shortest loopless paths.
    public func kShortestPaths(from a: Int32, to b: Int32, k: Int, weighting: Weighting = .hops,
                               filter: EdgeFilter = .established) -> [GraphPath] {
        guard k > 0, let first = dijkstra(from: a, to: b, weighting: weighting, filter: filter) else { return [] }
        var accepted: [GraphPath] = [first.path]
        var candidates: [(GraphPath, Double)] = []
        var seen: Set<GraphPath> = [first.path]

        while accepted.count < k {
            let last = accepted[accepted.count - 1]
            for i in 0..<max(0, last.nodes.count - 1) {
                let spur = last.nodes[i]
                let rootNodes = Array(last.nodes[0...i])
                let rootEdges = Array(last.edges[0..<i])
                var bannedEdges = Set<Int32>()
                for p in accepted where p.nodes.count > i + 1 && Array(p.nodes[0...i]) == rootNodes {
                    bannedEdges.insert(p.edges[i])
                }
                let bannedNodes = Set(rootNodes.dropLast())
                if let (spurPath, _) = dijkstra(from: spur, to: b, weighting: weighting, filter: filter,
                                                bannedNodes: bannedNodes, bannedEdges: bannedEdges) {
                    let total = GraphPath(nodes: rootNodes.dropLast() + spurPath.nodes, edges: rootEdges + spurPath.edges)
                    if !seen.contains(total) {
                        seen.insert(total)
                        candidates.append((total, pathCost(total, weighting)))
                    }
                }
            }
            guard !candidates.isEmpty else { break }
            candidates.sort { $0.1 < $1.1 || ($0.1 == $1.1 && $0.0.hopCount < $1.0.hopCount) }
            accepted.append(candidates.removeFirst().0)
        }
        return accepted
    }

    // MARK: Reports

    /// The five path classes requested for a pair of people, plus a candidate-only "possible" path.
    public func connectionReport(from aID: EntityID, to bID: EntityID, baseFilter: EdgeFilter = .established,
                                 alternatives: Int = 3) -> ConnectionReport? {
        guard let a = graph.index(of: aID), let b = graph.index(of: bID) else { return nil }
        var family = baseFilter; family.categories = [.family]
        var collab = baseFilter; collab.types = Set(RelationshipType.allCases.filter(\.isCollaboration))
        let shortest = shortestPath(from: a, to: b, filter: baseFilter)
        let strongest = dijkstra(from: a, to: b, weighting: .evidenceStrength, filter: baseFilter)?.path
        let alts = kShortestPaths(from: a, to: b, k: alternatives + 1, weighting: .hops, filter: baseFilter)
        let mixed = alts.filter { $0.categories(in: graph).count > 1 }
        var possible: GraphPath? = nil
        if shortest == nil {
            var loose = baseFilter
            loose.statuses.insert(.candidate)
            possible = shortestPath(from: a, to: b, filter: loose)
        }
        return ConnectionReport(from: aID, to: bID, shortest: shortest, strongest: strongest,
                                familyOnly: shortestPath(from: a, to: b, filter: family),
                                collaborationOnly: shortestPath(from: a, to: b, filter: collab),
                                mixed: mixed, possibleViaCandidates: possible)
    }

    /// Pairwise paths between several people and their compact shared network.
    public func multiConnection(_ ids: [EntityID], filter: EdgeFilter = .established) -> MultiConnectionReport {
        var pairs: [MultiConnectionReport.Pair] = []
        var nodes = Set<Int32>(), edges = Set<Int32>()
        for i in 0..<ids.count {
            for j in (i + 1)..<max(i + 1, ids.count) {
                var path: GraphPath? = nil
                if let a = graph.index(of: ids[i]), let b = graph.index(of: ids[j]) {
                    path = shortestPath(from: a, to: b, filter: filter)
                }
                if let path { nodes.formUnion(path.nodes); edges.formUnion(path.edges) }
                pairs.append(.init(a: ids[i], b: ids[j], path: path))
            }
        }
        for id in ids { if let n = graph.index(of: id) { nodes.insert(n) } }
        return MultiConnectionReport(people: ids, pairs: pairs, networkNodes: nodes, networkEdges: edges)
    }

    /// Nearest node (by hops) satisfying `predicate`, e.g. "my closest Minecraft creator".
    public func nearest(from a: Int32, filter: EdgeFilter = .established, where predicate: (Int32) -> Bool) -> GraphPath? {
        var prev: [Int32: (Int32, Int32)] = [a: (-1, -1)]
        var queue = [a]; var head = 0
        while head < queue.count {
            let u = queue[head]; head += 1
            if u != a && predicate(u) {
                var nodes = [u], edges: [Int32] = []
                var cur = u
                while let (p, e) = prev[cur], p != -1 { nodes.insert(p, at: 0); edges.insert(e, at: 0); cur = p }
                return GraphPath(nodes: nodes, edges: edges)
            }
            for n in graph.neighbors(of: u) where prev[n.node] == nil && filter.allows(graph.edges[Int(n.edge)]) {
                prev[n.node] = (u, n.edge)
                queue.append(n.node)
            }
        }
        return nil
    }

    // MARK: Structure

    /// Connected components (union-find). Returns component label per node.
    public func connectedComponents(filter: EdgeFilter = .established) -> [Int32] {
        var parent = (0..<Int32(graph.nodeCount)).map { $0 }
        func find(_ x: Int32) -> Int32 {
            var x = x
            while parent[Int(x)] != x { parent[Int(x)] = parent[Int(parent[Int(x)])]; x = parent[Int(x)] }
            return x
        }
        for e in graph.edges where filter.allows(e) {
            let ra = find(e.from), rb = find(e.to)
            if ra != rb { parent[Int(max(ra, rb))] = min(ra, rb) }
        }
        return (0..<Int32(graph.nodeCount)).map(find)
    }

    /// Weighted label propagation community detection. Deterministic for a given seed.
    public func communities(filter: EdgeFilter = .established, iterations: Int = 20, seed: UInt64 = 42) -> [Int32] {
        var labels = (0..<Int32(graph.nodeCount)).map { $0 }
        var order = Array(0..<Int32(graph.nodeCount))
        var rng = SplitMix64(seed: seed)
        for _ in 0..<iterations {
            order.shuffle(using: &rng)
            var changed = false
            for u in order {
                var weights: [Int32: Double] = [:]
                for n in graph.neighbors(of: u) {
                    let e = graph.edges[Int(n.edge)]
                    guard filter.allows(e) else { continue }
                    weights[labels[Int(n.node)], default: 0] += e.strength
                }
                guard let best = weights.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })?.key else { continue }
                if best != labels[Int(u)] { labels[Int(u)] = best; changed = true }
            }
            if !changed { break }
        }
        return labels
    }
}

/// Binary min-heap.
public struct MinHeap<T> {
    private var items: [T] = []
    private let less: (T, T) -> Bool
    public init(_ less: @escaping (T, T) -> Bool) { self.less = less }
    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    public mutating func push(_ x: T) {
        items.append(x)
        var i = items.count - 1
        while i > 0 {
            let p = (i - 1) / 2
            guard less(items[i], items[p]) else { break }
            items.swapAt(i, p); i = p
        }
    }

    public mutating func pop() -> T? {
        guard !items.isEmpty else { return nil }
        items.swapAt(0, items.count - 1)
        let top = items.removeLast()
        var i = 0
        while true {
            let l = 2 * i + 1, r = l + 1
            var m = i
            if l < items.count && less(items[l], items[m]) { m = l }
            if r < items.count && less(items[r], items[m]) { m = r }
            if m == i { break }
            items.swapAt(i, m); i = m
        }
        return top
    }
}

/// Small deterministic PRNG so layouts and community detection are reproducible.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
