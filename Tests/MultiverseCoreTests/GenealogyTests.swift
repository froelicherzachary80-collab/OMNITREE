import XCTest
@testable import MultiverseCore

final class GenealogyTests: XCTestCase {
    func importFixture(_ store: GraphStore) throws -> GEDCOMImportResult {
        try GEDCOMImporter(store: store).importGEDCOM(text: try fixtureText("family.ged"), fileName: "family.ged")
    }

    func testParserHandlesContinuation() throws {
        let roots = try GEDCOMParser.parse(try fixtureText("family.ged"))
        let clara = try XCTUnwrap(roots.first { $0.xref == "@I5@" })
        XCTAssertEqual(clara.first("NOTE")?.value, "This is a long note that continues here\nand on a new line.")
        XCTAssertEqual(GEDCOMParser.splitName("John /Smith/ Jr.").display, "John Smith Jr.")
    }

    func testImportCreatesPeopleEdgesAndPrivacyDefaults() throws {
        let store = try makeStore()
        let r = try importFixture(store)
        XCTAssertEqual(r.peopleCreated, 7)
        XCTAssertEqual(try store.relationshipCount(), 1 + 4 + 1 + 2) // marriage, F1 2 kids × 2 parents, F2 kid, F3 kids
        let thomas = try XCTUnwrap(try store.person(r.personIDs["@I1@"]!))
        XCTAssertEqual(thomas.birth?.isoString, "1890-03-12")
        XCTAssertEqual(thomas.birthPlace, "Bristol, England")
        XCTAssertFalse(thomas.isPrivate, "deceased people are not private by default")
        let clara = try XCTUnwrap(try store.person(r.personIDs["@I5@"]!))
        XCTAssertTrue(clara.isPrivate && clara.excludeFromResearch, "possibly-living relatives are private and excluded from research")
        let sam = r.personIDs["@I7@"]!
        XCTAssertEqual(try store.relationships(of: sam).first?.type, .adoptiveParent)
        XCTAssertFalse(try store.events(of: thomas.id).isEmpty)
    }

    func testKinshipFromImportedTree() throws {
        let store = try makeStore()
        let r = try importFixture(store)
        let g = try store.loadGraphIndex()
        func idx(_ x: String) -> Int32 { g.index(of: r.personIDs[x]!)! }
        XCTAssertEqual(KinshipCalculator.relation(idx("@I5@"), idx("@I6@"), in: g)?.term, "first cousin")
        XCTAssertEqual(KinshipCalculator.relation(idx("@I3@"), idx("@I4@"), in: g)?.term, "sibling")
        XCTAssertEqual(KinshipCalculator.relation(idx("@I3@"), idx("@I6@"), in: g)?.term, "aunt/uncle of B")
        let ca = KinshipCalculator.commonAncestors(idx("@I5@"), idx("@I7@"), in: g)
        XCTAssertEqual(Set(ca.map(\.ancestor)), [idx("@I1@"), idx("@I2@")], "adoptive branches are included and labelled as adoptive")
        XCTAssertNil(KinshipCalculator.relation(idx("@I1@"), idx("@I2@"), in: g), "spouses share no ancestor")
        XCTAssertEqual(KinshipCalculator.relation(idx("@I1@"), idx("@I5@"), in: g)?.term.hasPrefix("grandparent"), true)
    }

    func testKinshipTerms() {
        XCTAssertEqual(KinshipCalculator.describe(generationsFromA: 2, generationsFromB: 3), "first cousin once removed")
        XCTAssertEqual(KinshipCalculator.describe(generationsFromA: 3, generationsFromB: 3), "second cousin")
        XCTAssertEqual(KinshipCalculator.describe(generationsFromA: 1, generationsFromB: 1, halfRelation: true), "half-sibling")
        XCTAssertEqual(KinshipCalculator.describe(generationsFromA: 4, generationsFromB: 7), "third cousin 3 times removed")
        XCTAssertEqual(KinshipCalculator.describe(generationsFromA: 1, generationsFromB: 3), "great-aunt/uncle of B")
    }

    func testHalfSiblings() throws {
        let store = try makeStore()
        let mom = try person(store, "Mom"), dad1 = try person(store, "Dad One"), dad2 = try person(store, "Dad Two")
        let k1 = try person(store, "Kid One"), k2 = try person(store, "Kid Two")
        for (p, c) in [(mom, k1), (dad1, k1), (mom, k2), (dad2, k2)] { try link(store, p, c, .parent) }
        let g = try store.loadGraphIndex()
        XCTAssertEqual(KinshipCalculator.relation(g.index(of: k1.id)!, g.index(of: k2.id)!, in: g)?.term, "half-sibling")
    }

    func testExportRoundTrip() throws {
        let store = try makeStore()
        _ = try importFixture(store)
        let ged = try GEDCOMExporter(store: store).export(includePrivate: true)
        XCTAssertTrue(ged.contains("0 HEAD") && ged.contains("0 TRLR") && ged.contains("2 PEDI adopted"))
        let store2 = try makeStore()
        let r2 = try GEDCOMImporter(store: store2).importGEDCOM(text: ged, fileName: "roundtrip.ged")
        XCTAssertEqual(r2.peopleCreated, 7)
        XCTAssertEqual(try store2.relationshipCount(), try store.relationshipCount())

        let publicOnly = try GEDCOMExporter(store: store).export(includePrivate: false)
        XCTAssertFalse(publicOnly.contains("Clara"), "private living relatives are not exported by default")
    }

    func testRemoveImport() throws {
        let store = try makeStore()
        let r = try importFixture(store)
        XCTAssertEqual(try GEDCOMImporter(store: store).removeImport(r.importID), 7)
        XCTAssertEqual(try store.personCount(), 0)
        XCTAssertEqual(try store.relationshipCount(), 0)
    }

    func testDuplicateDetectionNeedsMoreThanAName() throws {
        let store = try makeStore()
        let engine = MergeEngine(store: store)
        try person(store, "John Smith", birth: 1900)
        try person(store, "John Smith", birth: 1950)
        XCTAssertTrue(try engine.scanForDuplicates().isEmpty, "same name, incompatible births → never proposed")

        let store2 = try makeStore()
        _ = try importFixture(store2)
        _ = try GEDCOMImporter(store: store2).importGEDCOM(text: try fixtureText("family.ged"), fileName: "copy.ged")
        let proposals = try MergeEngine(store: store2).scanForDuplicates()
        XCTAssertGreaterThanOrEqual(proposals.count, 5, "same people from two files with matching dates/parents")
        XCTAssertEqual(try store2.personCount(), 14, "nothing merged without approval")
        XCTAssertTrue(proposals.allSatisfy { $0.reasons.count > 1 })
    }

    func testConflictingExternalIDsBlockMerge() throws {
        let store = try makeStore()
        let a = try person(store, "Jane Doe", birth: 1980), b = try person(store, "Jane Doe", birth: 1980)
        try store.addIdentity(Identity(personID: a.id, scheme: .wikidata, value: "Q1"))
        try store.addIdentity(Identity(personID: b.id, scheme: .wikidata, value: "Q2"))
        let c = try MergeEngine(store: store).compare(a, b)
        XCTAssertTrue(c.blocked)
        XCTAssertLessThan(c.score, 0.3)
    }

    func testApprovedMergePreservesOriginals() throws {
        let store = try makeStore()
        _ = try importFixture(store)
        _ = try GEDCOMImporter(store: store).importGEDCOM(text: try fixtureText("family.ged"), fileName: "copy.ged")
        let engine = MergeEngine(store: store)
        let proposal = try XCTUnwrap(try engine.scanForDuplicates().first)
        try engine.approve(proposal.id)
        XCTAssertEqual(try store.personCount(), 13)
        XCTAssertEqual(try store.db.scalarInt("SELECT COUNT(*) FROM merge_history"), 1)
        XCTAssertEqual(try store.identities(of: proposal.personA).filter { $0.scheme == .gedcomXref }.count, 2, "both source identities kept")
        XCTAssertEqual(try engine.proposals(status: .approved).count, 1)
    }

    func testNameMatching() {
        XCTAssertGreaterThan(NameMatching.nameSimilarity("José Álvarez", "Jose Alvarez"), 0.99)
        XCTAssertGreaterThan(NameMatching.nameSimilarity("Robert James Hale", "Robert Hale"), 0.95)
        XCTAssertLessThan(NameMatching.nameSimilarity("Robert Hale", "Maria Gonzales"), 0.7)
    }
}
