import Foundation

/// Evidence to attach when storing a relationship.
public struct EvidenceInput: Sendable {
    public var sourceID: EntityID
    public var description: String
    public var quote: String?
    public var extractedBy: String
    public init(sourceID: EntityID, description: String, quote: String? = nil, extractedBy: String) {
        self.sourceID = sourceID; self.description = description; self.quote = quote; self.extractedBy = extractedBy
    }
}

public enum GraphStoreError: Error, CustomStringConvertible {
    case relationshipWithoutEvidence
    case selfRelationship
    case personNotFound(EntityID)
    case privateDataNeedsCipher

    public var description: String {
        switch self {
        case .relationshipWithoutEvidence: return "Every relationship needs at least one piece of evidence."
        case .selfRelationship: return "A person cannot be related to themselves."
        case .personNotFound(let id): return "Person \(id) not found."
        case .privateDataNeedsCipher: return "Private data can only be stored when encryption is configured."
        }
    }
}

/// The evidence-backed graph database. All persistent graph operations go through here.
public final class GraphStore: @unchecked Sendable {
    public let db: SQLiteDatabase
    private let cipher: FieldCipher
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Posted (on whatever thread made the change) when the graph changes.
    public static let didChangeNotification = Notification.Name("MultiverseGraphStoreDidChange")

    public init(db: SQLiteDatabase, cipher: FieldCipher = UnavailableCipher()) throws {
        self.db = db
        self.cipher = cipher
        try Schema.migrate(db)
    }

    public convenience init(path: String, cipher: FieldCipher = UnavailableCipher()) throws {
        try self.init(db: SQLiteDatabase(path: path), cipher: cipher)
    }

    public static func inMemory(cipher: FieldCipher = UnavailableCipher()) throws -> GraphStore {
        try GraphStore(db: SQLiteDatabase(path: ":memory:"), cipher: cipher)
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    // MARK: - People

    @discardableResult
    public func upsert(_ person: Person, privateData: PrivatePersonData? = nil) throws -> Person {
        var p = person
        p.updatedAt = Date()
        var blob: Data? = nil
        if let privateData {
            do { blob = try cipher.seal(try encoder.encode(privateData)) }
            catch { throw GraphStoreError.privateDataNeedsCipher }
        }
        try db.transaction {
            try db.run("""
                INSERT INTO person (id, display_name, given_name, surname, sex,
                    birth_date, birth_raw, birth_qualifier, birth_year, birth_place,
                    death_date, death_raw, death_qualifier, death_year, death_place,
                    occupation, biography, country, image_url, image_license,
                    is_private, exclude_from_research, is_living, is_sample, origin, private_blob, created_at, updated_at)
                VALUES (?,?,?,?,?, ?,?,?,?,?, ?,?,?,?,?, ?,?,?,?,?, ?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                    display_name=excluded.display_name, given_name=excluded.given_name, surname=excluded.surname,
                    sex=excluded.sex, birth_date=excluded.birth_date, birth_raw=excluded.birth_raw,
                    birth_qualifier=excluded.birth_qualifier, birth_year=excluded.birth_year, birth_place=excluded.birth_place,
                    death_date=excluded.death_date, death_raw=excluded.death_raw, death_qualifier=excluded.death_qualifier,
                    death_year=excluded.death_year, death_place=excluded.death_place, occupation=excluded.occupation,
                    biography=excluded.biography, country=excluded.country, image_url=excluded.image_url,
                    image_license=excluded.image_license, is_private=excluded.is_private,
                    exclude_from_research=excluded.exclude_from_research, is_living=excluded.is_living,
                    is_sample=excluded.is_sample, origin=excluded.origin,
                    private_blob=COALESCE(excluded.private_blob, person.private_blob), updated_at=excluded.updated_at
                """, params: [
                    p.id, p.displayName, p.givenName, p.surname, p.sex.rawValue,
                    p.birth?.isoString, p.birth?.raw, p.birth?.qualifier.rawValue, p.birth?.year, p.birthPlace,
                    p.death?.isoString, p.death?.raw, p.death?.qualifier.rawValue, p.death?.year, p.deathPlace,
                    p.occupation, p.biography, p.country, p.imageURL, p.imageLicense,
                    p.isPrivate, p.excludeFromResearch, p.isLiving.map { $0 ? 1 : 0 }, p.isSample, p.origin.rawValue,
                    blob, p.createdAt, p.updatedAt,
                ])
            try db.run("DELETE FROM person_category WHERE person_id = ?", p.id)
            for c in p.categories { try db.run("INSERT INTO person_category VALUES (?, ?)", p.id, c.rawValue) }
            try db.run("DELETE FROM person_alias WHERE person_id = ?", p.id)
            for a in Set(p.aliases) { try db.run("INSERT INTO person_alias VALUES (?, ?)", p.id, a) }
        }
        notifyChange()
        return p
    }

    private func date(_ row: Row, _ prefix: String) -> HistoricalDate? {
        let iso = row.string("\(prefix)_date")
        let raw = row.string("\(prefix)_raw")
        guard iso != nil || raw != nil else { return nil }
        var d = HistoricalDate.parse(iso) ?? HistoricalDate(year: nil)
        d.raw = raw
        d.qualifier = row.string("\(prefix)_qualifier").flatMap(HistoricalDate.Qualifier.init(rawValue:)) ?? .exact
        return d
    }

    private func decodePeople(_ rows: [Row]) throws -> [Person] {
        guard !rows.isEmpty else { return [] }
        let ids = rows.compactMap { $0.string("id") }
        var cats: [EntityID: Set<PersonCategory>] = [:]
        var aliases: [EntityID: [String]] = [:]
        for chunk in ids.chunked(500) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            for r in try db.query("SELECT person_id, category FROM person_category WHERE person_id IN (\(marks))", params: chunk) {
                if let id = r.string("person_id"), let c = r.string("category").flatMap(PersonCategory.init(rawValue:)) {
                    cats[id, default: []].insert(c)
                }
            }
            for r in try db.query("SELECT person_id, alias FROM person_alias WHERE person_id IN (\(marks))", params: chunk) {
                if let id = r.string("person_id"), let a = r.string("alias") { aliases[id, default: []].append(a) }
            }
        }
        return rows.map { r in
            let id = r.string("id")!
            return Person(
                id: id, displayName: r.string("display_name") ?? "", givenName: r.string("given_name"),
                surname: r.string("surname"), aliases: (aliases[id] ?? []).sorted(), categories: cats[id] ?? [],
                sex: Sex(rawValue: r.string("sex") ?? "U") ?? .unknown,
                birth: date(r, "birth"), birthPlace: r.string("birth_place"),
                death: date(r, "death"), deathPlace: r.string("death_place"),
                occupation: r.string("occupation"), biography: r.string("biography"), country: r.string("country"),
                imageURL: r.string("image_url"), imageLicense: r.string("image_license"),
                isPrivate: r.bool("is_private"), excludeFromResearch: r.bool("exclude_from_research"),
                isLiving: r.int("is_living").map { $0 != 0 }, isSample: r.bool("is_sample"),
                origin: RecordOrigin(rawValue: r.string("origin") ?? "user") ?? .user,
                createdAt: r.date("created_at") ?? Date(), updatedAt: r.date("updated_at") ?? Date())
        }
    }

    public func person(_ id: EntityID) throws -> Person? {
        try decodePeople(try db.query("SELECT * FROM person WHERE id = ?", id)).first
    }

    public func people(_ ids: [EntityID]) throws -> [Person] {
        var out: [Person] = []
        for chunk in ids.chunked(500) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            out += try decodePeople(try db.query("SELECT * FROM person WHERE id IN (\(marks))", params: chunk))
        }
        return out
    }

    public func privateData(for personID: EntityID) throws -> PrivatePersonData? {
        guard let blob = try db.query("SELECT private_blob FROM person WHERE id = ?", personID).first?.data("private_blob") else { return nil }
        return try decoder.decode(PrivatePersonData.self, from: try cipher.open(blob))
    }

    /// Name / alias search. Private people are only returned when `includePrivate` is set
    /// (the on-device owner); research agents always pass false.
    public func searchPeople(_ query: String, includePrivate: Bool = true, limit: Int = 50) throws -> [Person] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return try allPeople(limit: limit, includePrivate: includePrivate) }
        let like = "%\(q.replacingOccurrences(of: "%", with: ""))%"
        let rows = try db.query("""
            SELECT DISTINCT p.* FROM person p LEFT JOIN person_alias a ON a.person_id = p.id
            WHERE (p.display_name LIKE ? COLLATE NOCASE OR a.alias LIKE ? COLLATE NOCASE)
              AND (? = 1 OR p.is_private = 0)
            ORDER BY CASE WHEN p.display_name LIKE ? COLLATE NOCASE THEN 0 ELSE 1 END, length(p.display_name)
            LIMIT ?
            """, like, like, includePrivate, q, limit)
        return try decodePeople(rows)
    }

    public func allPeople(limit: Int = 1000, offset: Int = 0, includePrivate: Bool = true) throws -> [Person] {
        try decodePeople(try db.query("SELECT * FROM person WHERE (? = 1 OR is_private = 0) ORDER BY display_name LIMIT ? OFFSET ?",
                                      includePrivate, limit, offset))
    }

    public func people(inCategory category: PersonCategory) throws -> [Person] {
        try decodePeople(try db.query("SELECT p.* FROM person p JOIN person_category c ON c.person_id = p.id WHERE c.category = ?",
                                      category.rawValue))
    }

    public func personCount() throws -> Int { try db.scalarInt("SELECT COUNT(*) FROM person") }
    public func relationshipCount() throws -> Int { try db.scalarInt("SELECT COUNT(*) FROM relationship") }

    public func deletePerson(_ id: EntityID) throws {
        try db.run("DELETE FROM merge_proposal WHERE status = 'pending' AND (person_a = ? OR person_b = ?)", id, id)
        try db.run("DELETE FROM person WHERE id = ?", id)
        notifyChange()
    }

    public func setPrivacy(_ id: EntityID, isPrivate: Bool? = nil, excludeFromResearch: Bool? = nil) throws {
        if let isPrivate { try db.run("UPDATE person SET is_private = ?, updated_at = ? WHERE id = ?", isPrivate, Date(), id) }
        if let excludeFromResearch {
            try db.run("UPDATE person SET exclude_from_research = ?, updated_at = ? WHERE id = ?", excludeFromResearch, Date(), id)
        }
        notifyChange()
    }

    // MARK: - Identities

    @discardableResult
    public func addIdentity(_ identity: Identity) throws -> Identity {
        try db.run("INSERT OR IGNORE INTO identity (id, person_id, scheme, value, url) VALUES (?,?,?,?,?)",
                   identity.id, identity.personID, identity.scheme.rawValue, identity.value, identity.url)
        return identity
    }

    public func identities(of personID: EntityID) throws -> [Identity] {
        try db.query("SELECT * FROM identity WHERE person_id = ? ORDER BY scheme", personID).compactMap { r in
            guard let scheme = r.string("scheme").flatMap(IdentityScheme.init(rawValue:)) else { return nil }
            return Identity(id: r.string("id")!, personID: personID, scheme: scheme, value: r.string("value")!, url: r.string("url"))
        }
    }

    /// Identity resolution by external ID only — never by name.
    public func personID(scheme: IdentityScheme, value: String) throws -> EntityID? {
        try db.query("SELECT person_id FROM identity WHERE scheme = ? AND value = ?", scheme.rawValue, value).first?.string("person_id")
    }

    // MARK: - Platform accounts

    public func addPlatformAccount(_ a: PlatformAccount) throws {
        try db.run("""
            INSERT INTO platform_account (id, person_id, platform, handle, external_id, url, title, subscriber_count)
            VALUES (?,?,?,?,?,?,?,?)
            ON CONFLICT(platform, external_id) DO UPDATE SET handle=excluded.handle, url=excluded.url,
                title=excluded.title, subscriber_count=excluded.subscriber_count
            """, a.id, a.personID, a.platform, a.handle, a.externalID, a.url, a.title, a.subscriberCount)
    }

    public func platformAccounts(of personID: EntityID) throws -> [PlatformAccount] {
        try db.query("SELECT * FROM platform_account WHERE person_id = ?", personID).map { r in
            PlatformAccount(id: r.string("id")!, personID: personID, platform: r.string("platform")!, handle: r.string("handle"),
                            externalID: r.string("external_id"), url: r.string("url"), title: r.string("title"),
                            subscriberCount: r.int("subscriber_count"))
        }
    }

    // MARK: - Sources

    /// Inserts a source, reusing an existing row with the same URL.
    @discardableResult
    public func addSource(_ source: Source) throws -> Source {
        if let url = source.url, let existing = try db.query("SELECT * FROM source WHERE url = ?", url).first.map(decodeSource) {
            try db.run("UPDATE source SET retrieved_at = ? WHERE id = ?", source.retrievedAt, existing.id)
            return existing
        }
        try db.run("""
            INSERT INTO source (id, kind, title, url, document_ref, publisher, license, reliability, retrieved_at)
            VALUES (?,?,?,?,?,?,?,?,?)
            """, source.id, source.kind.rawValue, source.title, source.url, source.documentRef, source.publisher,
                   source.license, source.reliability, source.retrievedAt)
        return source
    }

    private func decodeSource(_ r: Row) -> Source {
        Source(id: r.string("id")!, kind: SourceKind(rawValue: r.string("kind") ?? "") ?? .userEntry, title: r.string("title") ?? "",
               url: r.string("url"), documentRef: r.string("document_ref"), publisher: r.string("publisher"),
               license: r.string("license"), reliability: r.double("reliability") ?? 0.5, retrievedAt: r.date("retrieved_at") ?? Date())
    }

    public func source(_ id: EntityID) throws -> Source? {
        try db.query("SELECT * FROM source WHERE id = ?", id).first.map(decodeSource)
    }

    public func allSources(limit: Int = 500) throws -> [Source] {
        try db.query("SELECT * FROM source ORDER BY retrieved_at DESC LIMIT ?", limit).map(decodeSource)
    }

    /// Sources cited by any relationship touching this person.
    public func sources(forPerson personID: EntityID) throws -> [Source] {
        try db.query("""
            SELECT DISTINCT s.* FROM source s
            JOIN relationship_evidence e ON e.source_id = s.id
            JOIN relationship r ON r.id = e.relationship_id
            WHERE r.from_id = ? OR r.to_id = ?
            ORDER BY s.reliability DESC
            """, personID, personID).map(decodeSource)
    }

    // MARK: - Relationships

    private static let verificationRank: [VerificationStatus: Int] = [
        .rejected: -1, .disputed: 0, .candidate: 1, .userAsserted: 2, .sourced: 3, .verified: 4,
    ]

    /// Stores a relationship with its evidence. If the same (from, to, type, context) edge exists,
    /// evidence is appended and confidence/verification are upgraded — never silently downgraded,
    /// and a user rejection is never overridden by automated research.
    @discardableResult
    public func addRelationship(_ input: Relationship, evidence: [EvidenceInput]) throws -> Relationship {
        guard !evidence.isEmpty else { throw GraphStoreError.relationshipWithoutEvidence }
        guard input.fromID != input.toID else { throw GraphStoreError.selfRelationship }
        var rel = input
        if !rel.isDirected && rel.fromID > rel.toID { swap(&rel.fromID, &rel.toID) }
        let contextKey = rel.contextProjectID ?? rel.contextLabel ?? ""

        let stored: Relationship = try db.transaction {
            if var existing = try db.query("SELECT * FROM relationship WHERE from_id = ? AND to_id = ? AND type = ? AND context_key = ?",
                                           rel.fromID, rel.toID, rel.type.rawValue, contextKey).first.flatMap(decodeRelationship) {
                let oldRank = Self.verificationRank[existing.verification] ?? 0
                let newRank = Self.verificationRank[rel.verification] ?? 0
                if existing.verification != .rejected && newRank > oldRank { existing.verification = rel.verification }
                existing.confidence = max(existing.confidence, rel.confidence)
                existing.lastChecked = Date()
                existing.startDate = existing.startDate ?? rel.startDate
                existing.endDate = existing.endDate ?? rel.endDate
                try db.run("UPDATE relationship SET verification = ?, confidence = ?, last_checked = ?, start_date = ?, start_year = ?, end_date = ?, end_year = ? WHERE id = ?",
                           existing.verification.rawValue, existing.confidence, existing.lastChecked,
                           existing.startDate?.isoString, existing.startDate?.year, existing.endDate?.isoString, existing.endDate?.year, existing.id)
                rel = existing
            } else {
                try db.run("""
                    INSERT INTO relationship (id, from_id, to_id, type, category, directed, is_inferred, verification, confidence,
                        start_date, start_year, end_date, end_year, last_checked, provenance, context_project_id, context_label,
                        context_key, created_at)
                    VALUES (?,?,?,?,?,?,?,?,?, ?,?,?,?,?,?,?,?, ?,?)
                    """, params: [rel.id, rel.fromID, rel.toID, rel.type.rawValue, rel.category.rawValue, rel.isDirected,
                                  rel.isInferred, rel.verification.rawValue, rel.confidence,
                                  rel.startDate?.isoString, rel.startDate?.year, rel.endDate?.isoString, rel.endDate?.year,
                                  rel.lastChecked, rel.provenance, rel.contextProjectID, rel.contextLabel, contextKey, rel.createdAt])
            }
            for e in evidence {
                let dup = try db.scalarInt("SELECT COUNT(*) FROM relationship_evidence WHERE relationship_id = ? AND source_id = ? AND description = ?",
                                           rel.id, e.sourceID, e.description)
                if dup == 0 {
                    try db.run("INSERT INTO relationship_evidence (id, relationship_id, source_id, description, quote, extracted_by, created_at) VALUES (?,?,?,?,?,?,?)",
                               IDGen.make(), rel.id, e.sourceID, e.description, e.quote, e.extractedBy, Date())
                }
            }
            return rel
        }
        notifyChange()
        return stored
    }

    private func decodeRelationship(_ r: Row) -> Relationship? {
        guard let type = r.string("type").flatMap(RelationshipType.init(rawValue:)),
              let ver = r.string("verification").flatMap(VerificationStatus.init(rawValue:)) else { return nil }
        return Relationship(id: r.string("id")!, fromID: r.string("from_id")!, toID: r.string("to_id")!, type: type,
                            verification: ver, confidence: r.double("confidence") ?? 0, isInferred: r.bool("is_inferred"),
                            startDate: HistoricalDate.parse(r.string("start_date")), endDate: HistoricalDate.parse(r.string("end_date")),
                            lastChecked: r.date("last_checked") ?? Date(), provenance: r.string("provenance") ?? "",
                            contextProjectID: r.string("context_project_id"), contextLabel: r.string("context_label"),
                            createdAt: r.date("created_at") ?? Date())
    }

    public func relationship(_ id: EntityID) throws -> Relationship? {
        try db.query("SELECT * FROM relationship WHERE id = ?", id).first.flatMap(decodeRelationship)
    }

    public func relationships(of personID: EntityID, includeUnestablished: Bool = true) throws -> [Relationship] {
        try db.query("SELECT * FROM relationship WHERE from_id = ? OR to_id = ? ORDER BY category, type", personID, personID)
            .compactMap(decodeRelationship)
            .filter { includeUnestablished || $0.verification.isEstablished }
    }

    public func relationships(between a: EntityID, and b: EntityID) throws -> [Relationship] {
        try db.query("SELECT * FROM relationship WHERE (from_id = ? AND to_id = ?) OR (from_id = ? AND to_id = ?)", a, b, b, a)
            .compactMap(decodeRelationship)
    }

    public func relationships(withStatus status: VerificationStatus, limit: Int = 500) throws -> [Relationship] {
        try db.query("SELECT * FROM relationship WHERE verification = ? ORDER BY created_at DESC LIMIT ?", status.rawValue, limit)
            .compactMap(decodeRelationship)
    }

    public func evidence(for relationshipID: EntityID) throws -> [(RelationshipEvidence, Source)] {
        try db.query("""
            SELECT e.id AS eid, e.description, e.quote, e.extracted_by, e.created_at AS ecreated, s.*
            FROM relationship_evidence e JOIN source s ON s.id = e.source_id
            WHERE e.relationship_id = ? ORDER BY s.reliability DESC
            """, relationshipID).map { r in
            (RelationshipEvidence(id: r.string("eid")!, relationshipID: relationshipID, sourceID: r.string("id")!,
                                  description: r.string("description") ?? "", quote: r.string("quote"),
                                  extractedBy: r.string("extracted_by") ?? "", createdAt: r.date("ecreated") ?? Date()),
             decodeSource(r))
        }
    }

    public func setVerification(_ relationshipID: EntityID, _ status: VerificationStatus) throws {
        try db.run("UPDATE relationship SET verification = ?, last_checked = ? WHERE id = ?", status.rawValue, Date(), relationshipID)
        notifyChange()
    }

    public func deleteRelationship(_ id: EntityID) throws {
        try db.run("DELETE FROM relationship WHERE id = ?", id)
        notifyChange()
    }

    // MARK: - Media, communities, events

    @discardableResult
    public func upsertProject(_ p: MediaProject) throws -> MediaProject {
        if let qid = p.wikidataQID, let r = try db.query("SELECT * FROM media_project WHERE wikidata_qid = ?", qid).first {
            return MediaProject(id: r.string("id")!, title: r.string("title")!, kind: r.string("kind")!, year: r.int("year"),
                                wikidataQID: qid, url: r.string("url"))
        }
        try db.run("INSERT OR REPLACE INTO media_project (id, title, kind, year, wikidata_qid, url) VALUES (?,?,?,?,?,?)",
                   p.id, p.title, p.kind, p.year, p.wikidataQID, p.url)
        return p
    }

    public func addCredit(_ c: MediaCredit) throws {
        try db.run("INSERT OR IGNORE INTO media_credit VALUES (?,?,?)", c.projectID, c.personID, c.role)
    }

    public func projects(of personID: EntityID) throws -> [(MediaProject, String)] {
        try db.query("SELECT m.*, c.role FROM media_project m JOIN media_credit c ON c.project_id = m.id WHERE c.person_id = ? ORDER BY m.year DESC",
                     personID).map { r in
            (MediaProject(id: r.string("id")!, title: r.string("title")!, kind: r.string("kind")!, year: r.int("year"),
                          wikidataQID: r.string("wikidata_qid"), url: r.string("url")), r.string("role") ?? "")
        }
    }

    @discardableResult
    public func upsertCommunity(_ c: Community) throws -> Community {
        if let r = try db.query("SELECT * FROM community WHERE name = ? COLLATE NOCASE AND kind = ?", c.name, c.kind).first {
            return Community(id: r.string("id")!, name: r.string("name")!, kind: r.string("kind")!, summary: r.string("summary"),
                             wikidataQID: r.string("wikidata_qid"))
        }
        try db.run("INSERT INTO community (id, name, kind, summary, wikidata_qid) VALUES (?,?,?,?,?)",
                   c.id, c.name, c.kind, c.summary, c.wikidataQID)
        return c
    }

    public func addMember(communityID: EntityID, personID: EntityID, role: String? = nil, sourceID: EntityID? = nil) throws {
        try db.run("INSERT OR IGNORE INTO community_member VALUES (?,?,?,?)", communityID, personID, role, sourceID)
    }

    public func communities(of personID: EntityID) throws -> [Community] {
        try db.query("SELECT c.* FROM community c JOIN community_member m ON m.community_id = c.id WHERE m.person_id = ?", personID).map { r in
            Community(id: r.string("id")!, name: r.string("name")!, kind: r.string("kind")!, summary: r.string("summary"),
                      wikidataQID: r.string("wikidata_qid"))
        }
    }

    public func allCommunities() throws -> [Community] {
        try db.query("SELECT * FROM community ORDER BY name").map { r in
            Community(id: r.string("id")!, name: r.string("name")!, kind: r.string("kind")!, summary: r.string("summary"),
                      wikidataQID: r.string("wikidata_qid"))
        }
    }

    public func members(ofCommunity communityID: EntityID) throws -> [EntityID] {
        try db.query("SELECT person_id FROM community_member WHERE community_id = ?", communityID).compactMap { $0.string("person_id") }
    }

    public func addEvent(_ e: FamilyEvent) throws {
        try db.run("INSERT OR REPLACE INTO family_event (id, person_id, type, date, date_raw, year, place, source_id, details, related_person_id) VALUES (?,?,?,?,?,?,?,?,?,?)",
                   params: [e.id, e.personID, e.type.rawValue, e.date?.isoString, e.date?.raw, e.date?.year, e.place, e.sourceID, e.details, e.relatedPersonID])
    }

    public func events(of personID: EntityID) throws -> [FamilyEvent] {
        try db.query("SELECT * FROM family_event WHERE person_id = ? ORDER BY year", personID).map { r in
            var d = HistoricalDate.parse(r.string("date"))
            if d != nil { d?.raw = r.string("date_raw") } else if let raw = r.string("date_raw") { d = HistoricalDate.parse(raw) }
            return FamilyEvent(id: r.string("id")!, personID: personID, type: FamilyEventType(rawValue: r.string("type")!) ?? .other,
                               date: d, place: r.string("place"), sourceID: r.string("source_id"), details: r.string("details"),
                               relatedPersonID: r.string("related_person_id"))
        }
    }

    // MARK: - Preferences & cache

    public func preference(_ key: String) throws -> String? {
        try db.query("SELECT value FROM user_preference WHERE key = ?", key).first?.string("value")
    }

    public func setPreference(_ key: String, _ value: String?) throws {
        if let value { try db.run("INSERT OR REPLACE INTO user_preference VALUES (?, ?)", key, value) }
        else { try db.run("DELETE FROM user_preference WHERE key = ?", key) }
    }

    public func cached(_ key: String, now: Date = Date()) throws -> Data? {
        try db.query("SELECT body FROM source_cache WHERE key = ? AND expires_at > ?", key, now).first?.data("body")
    }

    public func cache(_ key: String, body: Data, ttl: TimeInterval) throws {
        try db.run("INSERT OR REPLACE INTO source_cache VALUES (?,?,?,?)", key, body, Date(), Date().addingTimeInterval(ttl))
    }

    public func clearCache() throws { try db.run("DELETE FROM source_cache") }

    // MARK: - Layout

    public func saveLayout(_ positions: [EntityID: SIMD3<Float>], clusters: [EntityID: Int] = [:]) throws {
        try db.transaction {
            for (id, p) in positions {
                try db.run("INSERT OR REPLACE INTO node_layout VALUES (?,?,?,?,?)", id, Double(p.x), Double(p.y), Double(p.z), clusters[id] ?? 0)
            }
        }
    }

    public func loadLayout() throws -> [EntityID: SIMD3<Float>] {
        var out: [EntityID: SIMD3<Float>] = [:]
        try db.forEach("SELECT * FROM node_layout") { r in
            out[r.string("person_id")!] = SIMD3(Float(r.double("x") ?? 0), Float(r.double("y") ?? 0), Float(r.double("z") ?? 0))
        }
        return out
    }

    // MARK: - Snapshots, storage, backup

    @discardableResult
    public func snapshot(label: String) throws -> GraphSnapshot {
        let s = GraphSnapshot(label: label, nodeCount: try personCount(), edgeCount: try relationshipCount())
        try db.run("INSERT INTO graph_snapshot VALUES (?,?,?,?,?)", s.id, s.label, s.createdAt, s.nodeCount, s.edgeCount)
        return s
    }

    public func storageBytes() throws -> Int {
        try db.scalarInt("SELECT page_count * page_size FROM pragma_page_count(), pragma_page_size()")
    }

    public func backup(to path: String) throws { try db.backup(to: path) }

    // MARK: - Graph loading

    /// Loads the traversal index. Rejected edges are excluded entirely; candidates are kept
    /// (filters decide whether they participate).
    public func loadGraphIndex(includePrivate: Bool = true) throws -> GraphIndex {
        let builder = GraphIndex.Builder()
        try db.forEach("SELECT id, is_private FROM person") { r in
            if includePrivate || !r.bool("is_private") { builder.addNode(r.string("id")!) }
        }
        var categories: [EntityID: Set<PersonCategory>] = [:]
        try db.forEach("SELECT person_id, category FROM person_category") { r in
            if let c = r.string("category").flatMap(PersonCategory.init(rawValue:)) { categories[r.string("person_id")!, default: []].insert(c) }
        }
        builder.setCategories(categories)
        try db.forEach("""
            SELECT r.id, r.from_id, r.to_id, r.type, r.verification, r.confidence, r.start_year, r.end_year, r.is_inferred,
                   COALESCE((SELECT MAX(s.reliability) FROM relationship_evidence e JOIN source s ON s.id = e.source_id
                             WHERE e.relationship_id = r.id), 0.5) AS reliability
            FROM relationship r WHERE r.verification <> 'rejected'
            """) { r in
            guard let type = r.string("type").flatMap(RelationshipType.init(rawValue:)),
                  let ver = r.string("verification").flatMap(VerificationStatus.init(rawValue:)) else { return }
            builder.addEdge(id: r.string("id")!, from: r.string("from_id")!, to: r.string("to_id")!, type: type, verification: ver,
                            confidence: r.double("confidence") ?? 0, reliability: r.double("reliability") ?? 0.5,
                            startYear: r.int("start_year"), endYear: r.int("end_year"), isInferred: r.bool("is_inferred"))
        }
        return builder.build()
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
