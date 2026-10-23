import Foundation

/// A common ancestor of two people with the number of generations up from each.
public struct CommonAncestor: Sendable, Hashable {
    public let ancestor: Int32
    public let generationsFromA: Int
    public let generationsFromB: Int
    /// Ancestor chains (person → … → ancestor) through documented parent edges only.
    public let chainA: GraphPath
    public let chainB: GraphPath
}

public enum KinshipCalculator {
    /// Ancestors reachable by documented descent edges with their generation distance and chain.
    public static func ancestors(of node: Int32, in g: GraphIndex, filter: EdgeFilter = .established,
                                 maxGenerations: Int = 40) -> [Int32: (generation: Int, path: GraphPath)] {
        var out: [Int32: (Int, GraphPath)] = [node: (0, GraphPath(nodes: [node], edges: []))]
        var frontier = [node]
        var gen = 0
        while !frontier.isEmpty && gen < maxGenerations {
            gen += 1
            var next: [Int32] = []
            for child in frontier {
                let childPath = out[child]!.1
                for n in g.neighbors(of: child) {
                    let e = g.edges[Int(n.edge)]
                    guard e.type.isDescent, e.to == child, filter.allows(e), out[e.from] == nil else { continue }
                    out[e.from] = (gen, GraphPath(nodes: childPath.nodes + [e.from], edges: childPath.edges + [n.edge]))
                    next.append(e.from)
                }
            }
            frontier = next
        }
        return out
    }

    /// Lowest common ancestors (no descendant of theirs is also a common ancestor), closest first.
    public static func commonAncestors(_ a: Int32, _ b: Int32, in g: GraphIndex, filter: EdgeFilter = .established) -> [CommonAncestor] {
        let ancA = ancestors(of: a, in: g, filter: filter)
        let ancB = ancestors(of: b, in: g, filter: filter)
        let shared = Set(ancA.keys).intersection(ancB.keys)
        guard !shared.isEmpty else { return [] }
        // Remove ancestors that are themselves ancestors of another shared ancestor (keep lowest).
        var lowest = shared
        for s in shared {
            for (anc, info) in ancestors(of: s, in: g, filter: filter) where anc != s && info.generation > 0 {
                lowest.remove(anc)
            }
        }
        return lowest.map { s in
            CommonAncestor(ancestor: s, generationsFromA: ancA[s]!.generation, generationsFromB: ancB[s]!.generation,
                           chainA: ancA[s]!.path, chainB: ancB[s]!.path)
        }.sorted { ($0.generationsFromA + $0.generationsFromB) < ($1.generationsFromA + $1.generationsFromB) }
    }

    /// Standard English kinship term from generations to the common ancestor.
    /// (1,1) sibling, (2,2) first cousin, (2,3) first cousin once removed, (0,n) direct ancestor, etc.
    public static func describe(generationsFromA a: Int, generationsFromB b: Int, halfRelation: Bool = false) -> String {
        let half = halfRelation ? "half-" : ""
        switch (a, b) {
        case (0, 0): return "same person"
        case (0, let n): return "\(ancestorTerm(n)) of the other person (A is the ancestor)"
        case (let n, 0): return "\(descendantTerm(n)) (A descends from B)"
        case (1, 1): return "\(half)sibling"
        case (1, let n), (let n, 1):
            // aunt/uncle ↔ niece/nephew, with "great" prefixes.
            let greats = n - 2
            let prefix = greats == 0 ? "" : (greats == 1 ? "great-" : "\(greats)× great-")
            return a < b ? "\(half)\(prefix)aunt/uncle of B" : "\(half)\(prefix)niece/nephew of B"
        default:
            let degree = min(a, b) - 1
            let removed = abs(a - b)
            var s = "\(half)\(ordinal(degree)) cousin"
            if removed > 0 { s += removed == 1 ? " once removed" : removed == 2 ? " twice removed" : " \(removed) times removed" }
            return s
        }
    }

    private static func ancestorTerm(_ n: Int) -> String {
        switch n {
        case 1: return "parent"
        case 2: return "grandparent"
        default: return (n - 2 == 1 ? "great-" : "\(n - 2)× great-") + "grandparent"
        }
    }

    private static func descendantTerm(_ n: Int) -> String {
        switch n {
        case 1: return "child"
        case 2: return "grandchild"
        default: return (n - 2 == 1 ? "great-" : "\(n - 2)× great-") + "grandchild"
        }
    }

    static func ordinal(_ n: Int) -> String {
        let words = ["zeroth", "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]
        if n < words.count { return words[n] }
        let suffix: String
        switch (n % 10, n % 100) {
        case (1, let h) where h != 11: suffix = "st"
        case (2, let h) where h != 12: suffix = "nd"
        case (3, let h) where h != 13: suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    /// Full kinship analysis for two people: the closest documented relation or nil if no genealogical path exists.
    public static func relation(_ a: Int32, _ b: Int32, in g: GraphIndex, filter: EdgeFilter = .established) -> (term: String, via: CommonAncestor)? {
        let all = commonAncestors(a, b, in: g, filter: filter)
        guard let best = all.first else { return nil }
        // Half-relationship: only one shared ancestor at the closest level, when both sides have two known parents there.
        let sameLevel = all.filter { $0.generationsFromA == best.generationsFromA && $0.generationsFromB == best.generationsFromB }
        var half = false
        if sameLevel.count == 1 && best.generationsFromA > 0 && best.generationsFromB > 0 {
            let childA = best.chainA.nodes[best.chainA.nodes.count - 2]
            let childB = best.chainB.nodes[best.chainB.nodes.count - 2]
            half = g.parents(of: childA, filter: filter).count >= 2 && g.parents(of: childB, filter: filter).count >= 2
        }
        return (describe(generationsFromA: best.generationsFromA, generationsFromB: best.generationsFromB, halfRelation: half), best)
    }
}
