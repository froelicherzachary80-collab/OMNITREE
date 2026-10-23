import XCTest
@testable import MultiverseCore

final class DatabaseTests: XCTestCase {
    func testPersonRoundTrip() throws {
        let store = try makeStore()
        var p = Person(displayName: "Ada Example", givenName: "Ada", surname: "Example", aliases: ["A. E."],
                       categories: [.scientist, .author], sex: .female, birth: HistoricalDate.parse("ABT 1815"), birthPlace: "London")
        p = try store.upsert(p)
        let loaded = try XCTUnwrap(try store.person(p.id))
        XCTAssertEqual(loaded.displayName, "Ada Example")
        XCTAssertEqual(loaded.categories, [.scientist, .author])
        XCTAssertEqual(loaded.aliases, ["A. E."])
        XCTAssertEqual(loaded.birth?.year, 1815)
        XCTAssertEqual(loaded.birth?.qualifier, .about)
        XCTAssertEqual(try store.searchPeople("a. e.").first?.id, p.id, "alias search")
    }

    func testMigrationsAreIdempotent() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try Schema.migrate(db)
        try Schema.migrate(db)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM schema_migrations"), Schema.currentVersion)
    }

    func testRelationshipRequiresEvidence() throws {
        let store = try makeStore()
        let a = try person(store, "A"), b = try person(store, "B")
        XCTAssertThrowsError(try store.addRelationship(Relationship(fromID: a.id, toID: b.id, type: .sibling, verification: .sourced, confidence: 1, provenance: "t"), evidence: []))
        XCTAssertThrowsError(try link(store, a, a, .sibling))
    }

    func testUndirectedEdgesDeduplicateAndAccumulateEvidence() throws {
        let store = try makeStore()
        let a = try person(store, "A"), b = try person(store, "B")
        let r1 = try link(store, a, b, .sibling, status: .candidate, confidence: 0.4)
        let r2 = try link(store, b, a, .sibling, status: .sourced, confidence: 0.9)
        XCTAssertEqual(r1.id, r2.id)
        XCTAssertEqual(try store.relationshipCount(), 1)
        XCTAssertEqual(r2.verification, .sourced, "verification upgrades")
        XCTAssertEqual(r2.confidence, 0.9)
        XCTAssertEqual(try store.evidence(for: r1.id).count, 2)
    }

    func testUserRejectionIsNeverOverriddenByResearch() throws {
        let store = try makeStore()
        let a = try person(store, "A"), b = try person(store, "B")
        let r = try link(store, a, b, .publicFriendship)
        try store.setVerification(r.id, .rejected)
        let again = try link(store, a, b, .publicFriendship, status: .verified)
        XCTAssertEqual(again.verification, .rejected)
        XCTAssertEqual(try store.loadGraphIndex().edgeCount, 0, "rejected edges never enter the traversal index")
    }

    func testPrivateDataIsEncryptedAndRequiresCipher() throws {
        let store = try makeStore()
        let p = try store.upsert(Person(displayName: "Grandpa", isPrivate: true), privateData: PrivatePersonData(notes: "secret note"))
        let raw = try XCTUnwrap(try store.db.query("SELECT private_blob FROM person WHERE id = ?", p.id).first?.data("private_blob"))
        XCTAssertNil(String(data: raw, encoding: .utf8)?.range(of: "secret note"), "never stored in clear text")
        XCTAssertEqual(try store.privateData(for: p.id)?.notes, "secret note")

        let plain = try GraphStore.inMemory()   // no cipher configured
        XCTAssertThrowsError(try plain.upsert(Person(displayName: "X"), privateData: PrivatePersonData(notes: "n")))
    }

    func testPrivatePeopleExcludedFromPublicSearchAndIndex() throws {
        let store = try makeStore()
        let pub = try person(store, "Shared Name")
        let priv = try store.upsert(Person(displayName: "Shared Name Private", isPrivate: true))
        try link(store, pub, priv, .sibling)
        XCTAssertEqual(try store.searchPeople("Shared", includePrivate: false).map(\.id), [pub.id])
        XCTAssertEqual(try store.loadGraphIndex(includePrivate: false).nodeCount, 1)
        XCTAssertEqual(try store.loadGraphIndex(includePrivate: false).edgeCount, 0)
    }

    func testIdentityResolutionNeverUsesNames() throws {
        let store = try makeStore()
        let resolver = IdentityResolver(store: store)
        let (a, c1) = try resolver.resolveOrCreate(scheme: .wikidata, value: "Q1", url: nil) { Person(displayName: "John Smith") }
        let (b, c2) = try resolver.resolveOrCreate(scheme: .wikidata, value: "Q2", url: nil) { Person(displayName: "John Smith") }
        let (a2, c3) = try resolver.resolveOrCreate(scheme: .wikidata, value: "Q1", url: nil) { Person(displayName: "ignored") }
        XCTAssertTrue(c1 && c2 && !c3)
        XCTAssertNotEqual(a.id, b.id, "same name, different people")
        XCTAssertEqual(a.id, a2.id)
    }

    func testBackupAndRestore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mvt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GraphStore(path: dir.appendingPathComponent("a.sqlite").path)
        try person(store, "Kept")
        let backup = dir.appendingPathComponent("backup.sqlite").path
        try store.backup(to: backup)
        try person(store, "Added after backup")
        XCTAssertEqual(try store.personCount(), 2)
        try store.db.restore(from: backup)
        XCTAssertEqual(try store.personCount(), 1)
    }

    func testCacheExpiry() throws {
        let store = try makeStore()
        try store.cache("k", body: Data("v".utf8), ttl: 60)
        XCTAssertEqual(try store.cached("k"), Data("v".utf8))
        XCTAssertNil(try store.cached("k", now: Date().addingTimeInterval(120)))
    }

    func testHistoricalDateParsing() {
        XCTAssertEqual(HistoricalDate.parse("12 MAR 1890")?.isoString, "1890-03-12")
        XCTAssertEqual(HistoricalDate.parse("MAR 1890")?.isoString, "1890-03")
        XCTAssertEqual(HistoricalDate.parse("1890")?.isoString, "1890")
        XCTAssertEqual(HistoricalDate.parse("BEF 1700")?.qualifier, .before)
        XCTAssertEqual(HistoricalDate.parse("+1901-00-00T00:00:00Z")?.isoString, "1901")
        XCTAssertEqual(HistoricalDate.parse("+2006-06-25T00:00:00Z")?.isoString, "2006-06-25")
        XCTAssertNil(HistoricalDate.parse(""))
    }
}
