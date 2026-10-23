import XCTest
@testable import MultiverseCore

final class ResearchTests: XCTestCase {
    func wikidataMock() -> MockHTTPClient {
        let m = MockHTTPClient()
        m.route("wbsearchentities", fixture: "wikidata_search.json")
        m.route("P2397", fixture: "wikidata_person.json")          // person query
        m.route("VALUES (?p ?ps ?prop)", fixture: "wikidata_relations.json")
        m.route("wdt:P161 wd:", fixture: "wikidata_credits.json")
        return m
    }

    func testParsers() throws {
        let person = WikidataConnector.parsePerson(qid: "Q900001", rows: WikidataConnector.parseBindings(
            try JSONSerialization.jsonObject(with: try fixtureData("wikidata_person.json"))))
        XCTAssertEqual(person?.label, "Test Performer")
        XCTAssertEqual(person?.birth?.isoString, "2006-06-25")
        XCTAssertEqual(person?.sex, .female)
        XCTAssertEqual(person?.occupations, ["film actor", "television actor"])
        XCTAssertEqual(person?.wikipediaTitle, "Test_Performer")
        XCTAssertTrue(person?.isHuman == true)
        let cats = WikidataConnector.categories(occupations: person!.occupations, description: nil, birthYear: 2006, deathYear: nil)
        XCTAssertEqual(cats, [.actor])
        XCTAssertEqual(WikidataConnector.categories(occupations: ["physicist"], description: nil, birthYear: 1879, deathYear: 1955), [.scientist])
        XCTAssertTrue(WikidataConnector.categories(occupations: ["mathematician"], description: nil, birthYear: 1815, deathYear: 1852).contains(.historicalFigure))
    }

    func testWikidataAgentImportsCitedRelationships() async throws {
        let store = try makeStore()
        let http = ResearchHTTP(client: wikidataMock(), store: store, limiter: RateLimiter(intervals: [:], defaultInterval: 0))
        let agent = WikidataResearchAgent(store: store, http: http)
        let (pid, report) = try await agent.importPerson(qid: "Q900001")
        let id = try XCTUnwrap(pid)
        XCTAssertEqual(report.discoveries.count, 3)
        let rels = try store.relationships(of: id)
        let mother = try XCTUnwrap(rels.first { $0.type == .parent })
        XCTAssertEqual(mother.toID, id, "mother → child orientation")
        XCTAssertTrue(rels.contains { $0.type == .formerSpouse }, "spouse with end date becomes former spouse")
        for r in rels {
            XCTAssertEqual(r.verification, .sourced)
            let ev = try store.evidence(for: r.id)
            XCTAssertFalse(ev.isEmpty)
            XCTAssertTrue(ev[0].1.url!.hasPrefix("https://www.wikidata.org/wiki/Q900001#P"))
        }
        // Re-import is idempotent: same QIDs resolve to the same people.
        _ = try await agent.importPerson(qid: "Q900001")
        XCTAssertEqual(try store.personCount(), 4)
        XCTAssertEqual(try store.relationshipCount(), 3)

        let film = try await agent.importFilmography(of: id)
        XCTAssertEqual(film.discoveries.count, 3, "co-star in film, co-star in series, director")
        let types = Set(try store.relationships(of: id).map(\.type))
        XCTAssertTrue(types.isSuperset(of: [.sameFilm, .sameTelevisionSeries, .directorActor]))
        XCTAssertEqual(try store.projects(of: id).count, 2)
    }

    func testExcludedPeopleAreNotResearched() async throws {
        let store = try makeStore()
        let p = try store.upsert(Person(displayName: "Private", excludeFromResearch: true))
        try store.addIdentity(Identity(personID: p.id, scheme: .wikidata, value: "Q900001"))
        let mock = wikidataMock()
        let agent = WikidataResearchAgent(store: store, http: ResearchHTTP(client: mock, store: store, limiter: RateLimiter(intervals: [:], defaultInterval: 0)))
        let report = try await agent.importFilmography(of: p.id)
        XCTAssertFalse(report.rejectedClaims.isEmpty)
        XCTAssertTrue(mock.requests.isEmpty)
    }

    func testOfflineModeUsesCacheOnly() async throws {
        let store = try makeStore()
        let mock = wikidataMock()
        let http = ResearchHTTP(client: mock, store: store, limiter: RateLimiter(intervals: [:], defaultInterval: 0))
        let hits = try await WikidataConnector(http: http).search("Test Performer")
        XCTAssertEqual(hits.count, 2)
        http.offline = true
        let cached = try await WikidataConnector(http: http).search("Test Performer")
        XCTAssertEqual(cached.count, 2)
        do { _ = try await WikidataConnector(http: http).search("Uncached"); XCTFail() } catch HTTPError.offline {}
        XCTAssertEqual(mock.requests.count, 1)
    }

    func testYouTubeCandidatesAreNeverFriendships() throws {
        let json = try JSONSerialization.jsonObject(with: try fixtureData("youtube_uploads.json")) as! [String: Any]
        let video = try XCTUnwrap(YouTubeConnector.parsePlaylistItems(json).first)
        let cands = YouTubeConnector.extractCandidates(from: video, ownHandle: "@testbuilder")
        XCTAssertTrue(cands.contains { $0.signal == .featuringInTitle && $0.mentionedHandle == "@otherbuilder" })
        XCTAssertTrue(cands.contains { $0.mentionedChannelID == "UCbbbbbbbbbbbbbbbbbbbbbb" })
        XCTAssertTrue(cands.allSatisfy { $0.relationshipType == .channelMention || $0.relationshipType == .videoCollaboration })
        XCTAssertTrue(cands.allSatisfy { $0.confidence < 0.6 })
        let ch = YouTubeConnector.parseChannels(try JSONSerialization.jsonObject(with: try fixtureData("youtube_channels.json")) as! [String: Any])
        XCTAssertEqual(ch.first?.uploadsPlaylistID, "UUaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertEqual(YouTubeConnector.parseChannelReference("https://www.youtube.com/@Some.Creator/videos").handle, "@Some.Creator")
        XCTAssertEqual(YouTubeConnector.parseChannelReference("https://youtube.com/channel/UCbbbbbbbbbbbbbbbbbbbbbb").id, "UCbbbbbbbbbbbbbbbbbbbbbb")
    }

    func testYouTubeAgentStoresCandidatesForReview() async throws {
        let store = try makeStore()
        let mock = MockHTTPClient()
        mock.route("playlistItems", fixture: "youtube_uploads.json")
        mock.route("channels", fixture: "youtube_channels.json")
        let http = ResearchHTTP(client: mock, store: store, limiter: RateLimiter(intervals: [:], defaultInterval: 0))
        let agent = YouTubeResearchAgent(store: store, youtube: YouTubeConnector(http: http, apiKey: "test"))
        let (pid, _) = try await agent.importChannel("UCaaaaaaaaaaaaaaaaaaaaaa")
        let other = try store.upsert(Person(displayName: "Other Builder", categories: [.youtuber]))
        try store.addIdentity(Identity(personID: other.id, scheme: .youtubeChannel, value: "UCbbbbbbbbbbbbbbbbbbbbbb"))
        let (report, _) = try await agent.scanUploads(personID: pid!, channelID: "UCaaaaaaaaaaaaaaaaaaaaaa", pageToken: nil, resolveMentions: 0)
        XCTAssertFalse(report.discoveries.isEmpty)
        XCTAssertTrue(try store.relationships(of: pid!).allSatisfy { $0.verification == .candidate })
        XCTAssertFalse(mock.requests.contains { $0.absoluteString.contains("key=test") && $0.absoluteString.contains("search?") })
        XCTAssertNil(try store.cached("https://www.googleapis.com/youtube/v3/channels?key=test"), "API key never used as cache key")
        // The approval queue turns a candidate into a verified edge only by user action.
        let candidate = try XCTUnwrap(try store.relationships(withStatus: .candidate).first)
        try SourceVerificationAgent(store: store).approve(candidate.id)
        XCTAssertEqual(try store.relationship(candidate.id)?.verification, .verified)
    }

    func testSchedulerDedupRetryAndResume() async throws {
        let store = try makeStore()
        let mock = wikidataMock()
        mock.failuresBeforeSuccess = 1
        let http = ResearchHTTP(client: mock, store: store, limiter: RateLimiter(intervals: [:], defaultInterval: 0))
        let scheduler = ResearchScheduler(store: store, http: http)
        let j1 = try scheduler.enqueue(ResearchJob(kind: .wikidataSearch, target: "Test Performer"))
        let j2 = try scheduler.enqueue(ResearchJob(kind: .wikidataSearch, target: "test performer"))
        XCTAssertEqual(j1.id, j2.id, "duplicate jobs are avoided")

        await scheduler.run(j1)
        var job = try XCTUnwrap(try scheduler.job(j1.id))
        XCTAssertEqual(job.status, .queued, "transient failure → retry with backoff")
        XCTAssertGreaterThan(job.scheduledFor, Date())
        XCTAssertNil(try scheduler.nextRunnable())
        XCTAssertNotNil(try scheduler.nextRunnable(now: Date().addingTimeInterval(3600)))

        await scheduler.run(job)
        job = try XCTUnwrap(try scheduler.job(j1.id))
        XCTAssertEqual(job.status, .completed)
        let report = try XCTUnwrap(scheduler.report(for: j1.id))
        XCTAssertTrue(report.uncertainClaims.first?.contains("Several Wikidata matches") == true, "same-name ambiguity is surfaced")
        XCTAssertFalse(try scheduler.history(j1.id).isEmpty)

        // Interrupted jobs are recovered.
        var stuck = ResearchJob(kind: .duplicateScan, target: "all")
        stuck.status = .running
        try scheduler.save(stuck)
        XCTAssertEqual(try scheduler.recoverInterruptedJobs(), 1)
        XCTAssertEqual(try scheduler.job(stuck.id)?.status, .queued)
    }

    func testListImport() throws {
        let rows = ListImporter.parseCSV("name,category,wikidata,notes\n\"Doe, Jane\",friend,,\"likes \"\"chess\"\"\"\nCreator X,youtuber,Q900001,\n")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].name, "Doe, Jane")
        XCTAssertEqual(rows[0].notes, "likes \"chess\"")
        XCTAssertEqual(rows[0].category, .friend)
        let store = try makeStore()
        let scheduler = ResearchScheduler(store: store, http: ResearchHTTP(client: MockHTTPClient(), offline: true))
        let r = try ListImporter(store: store).importRows(rows, defaultCategory: .userImported, scheduler: scheduler, fileName: "list.csv")
        XCTAssertEqual(r.created.count, 1)
        XCTAssertEqual(r.jobs.count, 1)
        let jane = try XCTUnwrap(try store.person(r.created[0]))
        XCTAssertTrue(jane.isPrivate, "friends are private by default")
        XCTAssertEqual(try store.privateData(for: jane.id)?.notes, "likes \"chess\"")
    }

    func testDataExportContainsEvidence() throws {
        let store = try makeStore()
        try SampleData.load(into: store)
        let data = try DataExporter(store: store).exportJSON(includePrivateData: false)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual((json["people"] as? [Any])?.count, try store.personCount())
        XCTAssertEqual((json["relationships"] as? [Any])?.count, try store.relationshipCount())
        XCTAssertFalse((json["evidence"] as? [Any])?.isEmpty ?? true)
        XCTAssertEqual(try SampleData.remove(from: store), 19)
        XCTAssertEqual(try store.relationshipCount(), 0)
    }
}
