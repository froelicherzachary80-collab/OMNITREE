import XCTest
@testable import MultiverseCore

final class IntelligenceTests: XCTestCase {
    func testIntentParsing() {
        XCTAssertEqual(IntentParser.parse("How am I connected to McKenna Grace?"), .connect("me", "McKenna Grace", exhaustive: false))
        XCTAssertEqual(IntentParser.parse("How are all my friends connected?"), .connectGroup(.friend))
        XCTAssertEqual(IntentParser.parse("Find my shortest connection to a Minecraft YouTuber."), .nearest(from: "me", category: .minecraftCreator))
        XCTAssertEqual(IntentParser.parse("Show every documented connection between Ada Lovelace and Charles Babbage"),
                       .connect("Ada Lovelace", "Charles Babbage", exhaustive: true))
        XCTAssertEqual(IntentParser.parse("Do I share any documented ancestors with this actor Tom Hanks?"), .commonAncestors("me", "this actor Tom Hanks"))
        XCTAssertEqual(IntentParser.parse("Research all the members of Hermitcraft and connect them."), .researchGroup("Hermitcraft"))
        XCTAssertEqual(IntentParser.parse("Find public collaborations between Minecraft creators and actors."), .collaborationsBetween(.minecraftCreator, .actor))
        XCTAssertEqual(IntentParser.parse("Research this channel https://www.youtube.com/@example and add its verified connections"),
                       .researchChannel("https://www.youtube.com/@example"))
        XCTAssertEqual(IntentParser.parse("Research McKenna Grace"), .researchPerson("McKenna Grace"))
        XCTAssertEqual(IntentParser.parse("filmography of McKenna Grace"), .researchFilmography("McKenna Grace"))
        XCTAssertEqual(IntentParser.parse("Find the shortest verified connection between Isaac Newton and Albert Einstein"),
                       .connect("Isaac Newton", "Albert Einstein", exhaustive: false))
        if case .unknown = IntentParser.parse("blorp zing") {} else { XCTFail() }
    }

    func testModelJSONIsGroundedInRequest() {
        let q = "whats the link between alice and bob"
        XCTAssertEqual(IntentParser.intent(fromModelJSON: #"{"tool":"connect","a":"alice","b":"bob"}"#, original: q), .connect("alice", "bob", exhaustive: false))
        if case .unknown = IntentParser.intent(fromModelJSON: #"{"tool":"connect","a":"alice","b":"Carol"}"#, original: q) {} else {
            XCTFail("names the user never mentioned are rejected")
        }
    }

    func makeMIE() throws -> (MultiverseIntelligence, GraphStore) {
        let store = try makeStore()
        let me = try SampleData.load(into: store)
        try store.setPreference(MultiverseIntelligence.selfPersonPreference, me)
        let scheduler = ResearchScheduler(store: store, http: ResearchHTTP(client: MockHTTPClient(), store: store, offline: true))
        return (MultiverseIntelligence(store: store, scheduler: scheduler), store)
    }

    func testAskConnectReturnsCitedPaths() async throws {
        let (mie, store) = try makeMIE()
        let r = await mie.ask("How am I connected to Elara Quinn (sample)?", runResearchNow: false)
        XCTAssertFalse(r.paths.isEmpty, r.text)
        XCTAssertTrue(r.steps.contains { $0.tool == "pathfinder.connectionReport" })
        for path in r.paths {
            XCTAssertEqual(path.personIDs.first, try store.preference(MultiverseIntelligence.selfPersonPreference))
            for hop in path.hops {
                XCTAssertFalse(hop.evidence.isEmpty, "every hop carries evidence")
                XCTAssertTrue(hop.verification.isEstablished)
                XCTAssertNotNil(try store.relationship(hop.relationshipID), "every hop is a stored edge")
            }
        }
        XCTAssertFalse(r.highlightRelationshipIDs.isEmpty)
    }

    func testAskKinship() async throws {
        let (mie, _) = try makeMIE()
        let r = await mie.ask("Do I share any documented ancestors with Juniper Marsh (sample)?")
        XCTAssertTrue(r.text.contains("first cousin"), r.text)
    }

    func testAskReportsNoConnectionHonestly() async throws {
        let (mie, store) = try makeMIE()
        try store.upsert(Person(displayName: "Isolated Person"))
        let r = await mie.ask("How am I connected to Isolated Person?", runResearchNow: false)
        XCTAssertTrue(r.text.contains("No documented connection"), r.text)
        XCTAssertTrue(r.paths.isEmpty)
    }

    func testAskPossibleConnectionThroughCandidate() async throws {
        let (mie, store) = try makeMIE()
        let a = try person(store, "Alpha Only"), b = try person(store, "Beta Only")
        try link(store, a, b, .channelMention, status: .candidate, confidence: 0.2)
        let r = await mie.ask("How is Alpha Only connected to Beta Only?", runResearchNow: false)
        XCTAssertTrue(r.text.contains("Possible connection — research required"), r.text)
    }

    func testSameNameAsksForDisambiguation() async throws {
        let (mie, store) = try makeMIE()
        try person(store, "Jordan Lee", birth: 1950)
        try person(store, "Jordan Lee", birth: 1990)
        let r = await mie.ask("How am I connected to Jordan Lee?", runResearchNow: false)
        XCTAssertEqual(r.disambiguation.count, 2)
        XCTAssertTrue(r.paths.isEmpty)
    }

    func testNearestAndGroup() async throws {
        let (mie, _) = try makeMIE()
        let nearest = await mie.ask("Find my shortest connection to a Minecraft YouTuber")
        XCTAssertEqual(nearest.paths.first?.hops.last?.toName, "Juniper Marsh (sample)")
        let friends = await mie.ask("How are all my friends connected?")
        XCTAssertEqual(friends.paths.count, 1)
        let smp = await mie.ask("Research the members of Starlight SMP (sample)", runResearchNow: false)
        XCTAssertTrue(smp.steps.contains { $0.tool == "graph.community" }, smp.text)
    }

    func testUnknownNeverFabricates() async throws {
        let (mie, _) = try makeMIE()
        let r = await mie.ask("blorp zing quux")
        XCTAssertTrue(r.paths.isEmpty && r.highlightPersonIDs.isEmpty)
    }
}
