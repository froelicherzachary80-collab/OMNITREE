import Foundation

/// String similarity helpers used by identity resolution.
public enum NameMatching {
    public static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .components(separatedBy: CharacterSet.letters.union(.whitespaces).inverted).joined()
            .split(separator: " ").joined(separator: " ")
    }

    public static func jaroWinkler(_ a: String, _ b: String) -> Double {
        let s1 = Array(a), s2 = Array(b)
        if s1.isEmpty && s2.isEmpty { return 1 }
        if s1.isEmpty || s2.isEmpty { return 0 }
        let window = max(0, max(s1.count, s2.count) / 2 - 1)
        var m1 = [Bool](repeating: false, count: s1.count), m2 = [Bool](repeating: false, count: s2.count)
        var matches = 0
        for i in 0..<s1.count {
            let lo = max(0, i - window), hi = min(s2.count - 1, i + window)
            if lo > hi { continue }
            for j in lo...hi where !m2[j] && s1[i] == s2[j] { m1[i] = true; m2[j] = true; matches += 1; break }
        }
        guard matches > 0 else { return 0 }
        var t = 0, k = 0
        for i in 0..<s1.count where m1[i] {
            while !m2[k] { k += 1 }
            if s1[i] != s2[k] { t += 1 }
            k += 1
        }
        let m = Double(matches)
        let jaro = (m / Double(s1.count) + m / Double(s2.count) + (m - Double(t) / 2) / m) / 3
        var prefix = 0
        for i in 0..<min(4, s1.count, s2.count) { if s1[i] == s2[i] { prefix += 1 } else { break } }
        return jaro + Double(prefix) * 0.1 * (1 - jaro)
    }

    /// Token-set similarity for full names (order-insensitive, tolerant of middle names).
    public static func nameSimilarity(_ a: String, _ b: String) -> Double {
        let ta = normalize(a).split(separator: " ").map(String.init), tb = normalize(b).split(separator: " ").map(String.init)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        let (short, long) = ta.count <= tb.count ? (ta, tb) : (tb, ta)
        let total = short.reduce(0.0) { acc, t in acc + (long.map { jaroWinkler(t, $0) }.max() ?? 0) }
        return total / Double(short.count)
    }

    public static func placeSimilarity(_ a: String?, _ b: String?) -> Double? {
        guard let a, let b, !a.isEmpty, !b.isEmpty else { return nil }
        let ta = Set(normalize(a).split(separator: " ")), tb = Set(normalize(b).split(separator: " "))
        guard !ta.isEmpty, !tb.isEmpty else { return nil }
        return Double(ta.intersection(tb).count) / Double(min(ta.count, tb.count))
    }
}

/// Duplicate detection and safe, reversible-by-record merging.
/// Merges are always proposals until the user approves; names alone never trigger a merge.
public struct MergeEngine {
    public let store: GraphStore
    /// Proposals below this score are not stored.
    public var proposalThreshold = 0.62

    public init(store: GraphStore) { self.store = store }

    public struct Comparison: Sendable {
        public let score: Double
        public let reasons: [String]
        public let conflicts: [String]
        /// True when hard conflicts (e.g. different birth years far apart) make the pair implausible.
        public let blocked: Bool
    }

    private func relativesNames(_ id: EntityID, types: Set<RelationshipType>, incoming: Bool) throws -> [String] {
        let rels = try store.relationships(of: id, includeUnestablished: false).filter { types.contains($0.type) }
        let ids = rels.compactMap { r -> EntityID? in
            if !r.isDirected { return r.other(than: id) }
            return incoming ? (r.toID == id ? r.fromID : nil) : (r.fromID == id ? r.toID : nil)
        }
        return try store.people(ids).map(\.displayName)
    }

    public func compare(_ a: Person, _ b: Person) throws -> Comparison {
        var reasons: [String] = [], conflicts: [String] = []
        var score = 0.0, weight = 0.0
        var blocked = false

        // Hard identity conflicts: different IDs in the same external scheme mean different people.
        let ia = try store.identities(of: a.id), ib = try store.identities(of: b.id)
        for x in ia {
            for y in ib where x.scheme == y.scheme && x.scheme != .gedcomXref && x.value != y.value {
                conflicts.append("Different \(x.scheme.rawValue) identifiers (\(x.value) vs \(y.value))")
                blocked = true
            }
            if ib.contains(where: { $0.scheme == x.scheme && $0.value == x.value && x.scheme != .gedcomXref }) {
                reasons.append("Same \(x.scheme.rawValue) identifier \(x.value)")
                score += 3; weight += 3
            }
        }

        let nameSim = NameMatching.nameSimilarity(a.displayName, b.displayName)
        score += nameSim * 2; weight += 2
        reasons.append(String(format: "Name similarity %.0f%%", nameSim * 100))

        func compareDates(_ x: HistoricalDate?, _ y: HistoricalDate?, _ label: String) {
            guard let yx = x?.year, let yy = y?.year else { return }
            weight += 2
            let diff = abs(yx - yy)
            let approximate = x?.qualifier != .exact || y?.qualifier != .exact
            if diff == 0 {
                score += 2
                if let mx = x?.month, let my = y?.month, mx != my { conflicts.append("\(label) month differs (\(mx) vs \(my))"); score -= 0.5 }
                else { reasons.append("\(label) year matches (\(yx))") }
            } else if diff <= (approximate ? 5 : 2) {
                score += 1
                reasons.append("\(label) years close (\(yx) / \(yy))")
            } else {
                conflicts.append("\(label) years conflict (\(yx) vs \(yy))")
                if diff > 15 { blocked = true }
            }
        }
        compareDates(a.birth, b.birth, "Birth")
        compareDates(a.death, b.death, "Death")

        for (pa, pb, label) in [(a.birthPlace, b.birthPlace, "Birth place"), (a.deathPlace, b.deathPlace, "Death place")] {
            if let sim = NameMatching.placeSimilarity(pa, pb) {
                weight += 1
                score += sim
                if sim >= 0.5 { reasons.append("\(label) matches (\(pa!))") } else { conflicts.append("\(label) differs (\(pa!) vs \(pb!))") }
            }
        }

        if a.sex != .unknown && b.sex != .unknown && a.sex != b.sex {
            conflicts.append("Recorded sex differs")
            score -= 1
        }

        for (types, incoming, label) in [(Set([RelationshipType.parent, .adoptiveParent]), true, "parents"),
                                         (Set([RelationshipType.spouse, .formerSpouse]), false, "spouses")] {
            let ra = try relativesNames(a.id, types: types, incoming: incoming)
            let rb = try relativesNames(b.id, types: types, incoming: incoming)
            guard !ra.isEmpty, !rb.isEmpty else { continue }
            weight += 2
            let matched = ra.filter { n in rb.contains { NameMatching.nameSimilarity(n, $0) > 0.92 } }
            if !matched.isEmpty {
                score += 2 * Double(matched.count) / Double(min(ra.count, rb.count))
                reasons.append("Shared \(label): \(matched.joined(separator: ", "))")
            } else {
                conflicts.append("No matching \(label) (\(ra.joined(separator: ", ")) vs \(rb.joined(separator: ", ")))")
            }
        }

        // Without any corroborating evidence beyond the name, cap the score so a name match alone never qualifies.
        let corroborated = reasons.count > 1
        var normalized = weight > 0 ? max(0, score / weight) : 0
        if !corroborated { normalized = min(normalized, 0.5) }
        if blocked { normalized = min(normalized, 0.2) }
        return Comparison(score: normalized, reasons: reasons, conflicts: conflicts, blocked: blocked)
    }

    /// Blocking key: normalised surname initial + birth decade (unknown decades compare against all).
    private func blockKey(_ p: Person) -> String {
        let surname = NameMatching.normalize(p.surname ?? p.displayName.split(separator: " ").last.map(String.init) ?? "")
        return String(surname.prefix(2))
    }

    /// Scans for likely duplicates and stores pending proposals.
    @discardableResult
    public func scanForDuplicates(among people: [Person]? = nil) throws -> [MergeProposal] {
        let all = try people ?? store.allPeople(limit: .max)
        let blocks = Dictionary(grouping: all, by: blockKey)
        var out: [MergeProposal] = []
        for (_, group) in blocks where group.count > 1 {
            for i in 0..<group.count {
                for j in (i + 1)..<group.count {
                    let a = group[i], b = group[j]
                    if let ya = a.birth?.year, let yb = b.birth?.year, abs(ya - yb) > 15 { continue }
                    guard NameMatching.nameSimilarity(a.displayName, b.displayName) > 0.8 else { continue }
                    let c = try compare(a, b)
                    guard c.score >= proposalThreshold, !c.blocked else { continue }
                    let (x, y) = a.id < b.id ? (a.id, b.id) : (b.id, a.id)
                    let existing = try store.db.scalarInt("SELECT COUNT(*) FROM merge_proposal WHERE person_a = ? AND person_b = ?", x, y)
                    if existing > 0 { continue }
                    let p = MergeProposal(personA: x, personB: y, score: c.score, reasons: c.reasons, conflicts: c.conflicts)
                    try store.db.run("INSERT INTO merge_proposal VALUES (?,?,?,?,?,?,?,?,?)",
                                     params: [p.id, p.personA, p.personB, p.score, Self.json(p.reasons), Self.json(p.conflicts),
                                              p.status.rawValue, p.createdAt, p.decidedAt])
                    out.append(p)
                }
            }
        }
        return out
    }

    static func json(_ arr: [String]) -> String {
        (try? String(data: JSONEncoder().encode(arr), encoding: .utf8)) ?? "[]"
    }

    public func proposals(status: MergeStatus = .pending) throws -> [MergeProposal] {
        try store.db.query("SELECT * FROM merge_proposal WHERE status = ? ORDER BY score DESC", status.rawValue).map { r in
            MergeProposal(id: r.string("id")!, personA: r.string("person_a")!, personB: r.string("person_b")!,
                          score: r.double("score") ?? 0,
                          reasons: (try? JSONDecoder().decode([String].self, from: Data((r.string("reasons") ?? "[]").utf8))) ?? [],
                          conflicts: (try? JSONDecoder().decode([String].self, from: Data((r.string("conflicts") ?? "[]").utf8))) ?? [],
                          status: MergeStatus(rawValue: r.string("status")!) ?? .pending, createdAt: r.date("created_at") ?? Date(),
                          decidedAt: r.date("decided_at"))
        }
    }

    public func reject(_ proposalID: EntityID) throws {
        try store.db.run("UPDATE merge_proposal SET status = 'rejected', decided_at = ? WHERE id = ?", Date(), proposalID)
    }

    /// Executes an approved merge. The merged record is preserved verbatim in `merge_history`,
    /// all identities, relationships, evidence, events and credits move to the survivor.
    public func approve(_ proposalID: EntityID, survivor: EntityID? = nil) throws {
        guard let row = try store.db.query("SELECT * FROM merge_proposal WHERE id = ?", proposalID).first else { return }
        let a = row.string("person_a")!, b = row.string("person_b")!
        let keep = survivor ?? a
        let drop = keep == a ? b : a
        try store.db.transaction {
            try store.db.run("UPDATE merge_proposal SET status = 'approved', decided_at = ? WHERE id = ?", Date(), proposalID)
            try merge(keep: keep, drop: drop)
        }
    }

    public func merge(keep: EntityID, drop: EntityID) throws {
        guard var survivor = try store.person(keep) else { throw GraphStoreError.personNotFound(keep) }
        guard let merged = try store.person(drop) else { throw GraphStoreError.personNotFound(drop) }
        let db = store.db
        try db.transaction {
            let snapshot = try String(data: JSONEncoder().encode(merged), encoding: .utf8) ?? "{}"
            try db.run("INSERT INTO merge_history (survivor_id, merged_id, snapshot, merged_at) VALUES (?,?,?,?)", keep, drop, snapshot, Date())

            survivor.categories.formUnion(merged.categories)
            if merged.displayName != survivor.displayName { survivor.aliases.append(merged.displayName) }
            survivor.aliases.append(contentsOf: merged.aliases)
            survivor.birth = survivor.birth ?? merged.birth
            survivor.birthPlace = survivor.birthPlace ?? merged.birthPlace
            survivor.death = survivor.death ?? merged.death
            survivor.deathPlace = survivor.deathPlace ?? merged.deathPlace
            survivor.occupation = survivor.occupation ?? merged.occupation
            survivor.biography = survivor.biography ?? merged.biography
            survivor.isPrivate = survivor.isPrivate || merged.isPrivate
            survivor.excludeFromResearch = survivor.excludeFromResearch || merged.excludeFromResearch
            survivor.origin = .merged
            try store.upsert(survivor)

            try db.run("UPDATE OR IGNORE identity SET person_id = ? WHERE person_id = ?", keep, drop)
            try db.run("UPDATE OR IGNORE platform_account SET person_id = ? WHERE person_id = ?", keep, drop)
            try db.run("UPDATE OR IGNORE media_credit SET person_id = ? WHERE person_id = ?", keep, drop)
            try db.run("UPDATE OR IGNORE community_member SET person_id = ? WHERE person_id = ?", keep, drop)
            try db.run("UPDATE family_event SET person_id = ? WHERE person_id = ?", keep, drop)
            try db.run("UPDATE family_event SET related_person_id = ? WHERE related_person_id = ?", keep, drop)

            // Re-point relationships through addRelationship so duplicates fold together with their evidence.
            for rel in try store.relationships(of: drop) {
                var moved = rel
                if moved.fromID == drop { moved.fromID = keep }
                if moved.toID == drop { moved.toID = keep }
                let ev = try store.evidence(for: rel.id).map { EvidenceInput(sourceID: $0.1.id, description: $0.0.description, quote: $0.0.quote, extractedBy: $0.0.extractedBy) }
                try store.deleteRelationship(rel.id)
                if moved.fromID == moved.toID || ev.isEmpty { continue }
                moved.id = IDGen.make()
                try store.addRelationship(moved, evidence: ev)
            }
            try store.deletePerson(drop)
        }
    }
}
