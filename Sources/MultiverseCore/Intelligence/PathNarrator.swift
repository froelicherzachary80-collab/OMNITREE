import Foundation

/// One explained hop of a path, with its evidence — rendered in the evidence panel.
public struct ExplainedHop: Sendable, Hashable {
    public let fromID: EntityID
    public let toID: EntityID
    public let fromName: String
    public let toName: String
    public let relationshipID: EntityID
    public let type: RelationshipType
    public let label: String
    public let verification: VerificationStatus
    public let confidence: Double
    public let context: String?
    public let evidence: [String]
    public let sourceURLs: [String]
}

public struct ExplainedPath: Sendable, Hashable {
    public let title: String
    public let hops: [ExplainedHop]
    public let strength: Double
    public let personIDs: [EntityID]
    public let relationshipIDs: [EntityID]

    public var sentence: String {
        guard let first = hops.first else { return title }
        var s = first.fromName
        for h in hops { s += " —(\(h.label)\(h.context.map { ": \($0)" } ?? ""))→ \(h.toName)" }
        return s
    }
}

/// Turns graph paths into human-readable, fully cited explanations.
public struct PathNarrator {
    public let store: GraphStore
    public let graph: GraphIndex
    public init(store: GraphStore, graph: GraphIndex) { self.store = store; self.graph = graph }

    public func explain(_ path: GraphPath, title: String) throws -> ExplainedPath {
        let ids = path.personIDs(in: graph)
        let names = Dictionary(uniqueKeysWithValues: try store.people(ids).map { ($0.id, $0.displayName) })
        var hops: [ExplainedHop] = []
        for (i, e) in path.edges.enumerated() {
            let edge = graph.edges[Int(e)]
            let from = ids[i], to = ids[i + 1]
            guard let rel = try store.relationship(edge.id) else { continue }
            let ev = try store.evidence(for: rel.id)
            hops.append(ExplainedHop(fromID: from, toID: to, fromName: names[from] ?? "?", toName: names[to] ?? "?",
                                     relationshipID: rel.id, type: rel.type, label: rel.label(from: from),
                                     verification: rel.verification, confidence: rel.confidence, context: rel.contextLabel,
                                     evidence: ev.map { $0.0.description },
                                     sourceURLs: ev.compactMap { $0.1.url ?? $0.1.documentRef }))
        }
        return ExplainedPath(title: title, hops: hops, strength: path.strength(in: graph), personIDs: ids,
                             relationshipIDs: path.relationshipIDs(in: graph))
    }
}
