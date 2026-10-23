import XCTest
@testable import MultiverseCore

final class PathFinderTests: XCTestCase {
    /// a — b — c — d (family) plus a weak shortcut a — d (candidate) and a creator route a — e — d.
    func makeGraph() throws -> (GraphStore, [String: Person]) {
        let store = try makeStore()
        var p: [String: Person] = [:]
        for n in ["a", "b", "c", "d", "e", "x"] { p[n] = try person(store, n.uppercased()) }
        try link(store, p["a"]!, p["b"]!, .parent)
        try link(store, p["b"]!, p["c"]!, .parent)
        try link(store, p["c"]!, p["d"]!, .parent)
        try link(store, p["a"]!, p["d"]!, .channelMention, status: .candidate, confidence: 0.2)
        let weak = try source(store, reliability: 0.3)
        try link(store, p["a"]!, p["e"]!, .videoCollaboration, confidence: 0.4, src: weak)
        try link(store, p["e"]!, p["d"]!, .videoCollaboration, confidence: 0.4, src: weak)
        return (store, p)
    }

    func testShortestUsesOnlyEstablishedEdges() throws {
        let (store, p) = try makeGraph()
        let g = try store.loadGraphIndex()
        let f = PathFinder(graph: g)
        let path = try XCTUnwrap(f.shortestPath(from: g.index(of: p["a"]!.id)!, to: g.index(of: p["d"]!.id)!))
        XCTAssertEqual(path.hopCount, 2, "via e, not via the candidate shortcut")
        XCTAssertEqual(path.personIDs(in: g), [p["a"]!.id, p["e"]!.id, p["d"]!.id])
        let loose = try XCTUnwrap(f.shortestPath(from: g.index(of: p["a"]!.id)!, to: g.index(of: p["d"]!.id)!, filter: .includingCandidates))
        XCTAssertEqual(loose.hopCount, 1)
    }

    func testBidirectionalMatchesBFS() throws {
        let store = try makeStore()
        var rng = SplitMix64(seed: 3)
        let people = try (0..<120).map { try person(store, "P\($0)") }
        let src = try source(store)
        for _ in 0..<260 {
            let i = Int.random(in: 0..<120, using: &rng), j = Int.random(in: 0..<120, using: &rng)
            if i != j { try link(store, people[i], people[j], .publicFriendship, src: src) }
        }
        let g = try store.loadGraphIndex()
        let f = PathFinder(graph: g)
        for _ in 0..<40 {
            let a = Int32.random(in: 0..<Int32(g.nodeCount), using: &rng), b = Int32.random(in: 0..<Int32(g.nodeCount), using: &rng)
            let dist = f.bfsDistances(from: a)[Int(b)]
            let path = f.shortestPath(from: a, to: b)
            if dist == .max { XCTAssertNil(path) } else {
                XCTAssertEqual(path?.hopCount, dist)
                // Every hop is a real stored edge between consecutive nodes.
                for (k, e) in path!.edges.enumerated() {
                    let edge = g.edges[Int(e)]
                    XCTAssertEqual(Set([edge.from, edge.to]), Set([path!.nodes[k], path!.nodes[k + 1]]))
                }
            }
        }
    }

    func testStrongestPrefersReliableEvidence() throws {
        let (store, p) = try makeGraph()
        let g = try store.loadGraphIndex()
        let strongest = try XCTUnwrap(PathFinder(graph: g).dijkstra(from: g.index(of: p["a"]!.id)!, to: g.index(of: p["d"]!.id)!)).path
        XCTAssertEqual(strongest.personIDs(in: g), ["a", "b", "c", "d"].map { p[$0]!.id }, "three strong family hops beat two weak ones")
    }

    func testConnectionReportClasses() throws {
        let (store, p) = try makeGraph()
        let g = try store.loadGraphIndex()
        let r = try XCTUnwrap(PathFinder(graph: g).connectionReport(from: p["a"]!.id, to: p["d"]!.id))
        XCTAssertEqual(r.familyOnly?.hopCount, 3)
        XCTAssertEqual(r.collaborationOnly?.hopCount, 2)
        XCTAssertTrue(r.familyOnly!.categories(in: g) == [.family])
        XCTAssertNil(r.possibleViaCandidates)
    }

    func testNoFictionalEdgesWhenDisconnected() throws {
        let (store, p) = try makeGraph()
        let g = try store.loadGraphIndex()
        let r = try XCTUnwrap(PathFinder(graph: g).connectionReport(from: p["a"]!.id, to: p["x"]!.id))
        XCTAssertFalse(r.isConnected)
        XCTAssertNil(r.strongest)
        XCTAssertNil(r.possibleViaCandidates)
    }

    func testPossibleConnectionOnlyThroughCandidates() throws {
        let store = try makeStore()
        let a = try person(store, "A"), b = try person(store, "B")
        try link(store, a, b, .channelMention, status: .candidate, confidence: 0.2)
        let g = try store.loadGraphIndex()
        let r = try XCTUnwrap(PathFinder(graph: g).connectionReport(from: a.id, to: b.id))
        XCTAssertFalse(r.isConnected)
        XCTAssertEqual(r.possibleViaCandidates?.hopCount, 1)
    }

    func testKShortestDistinctAndOrdered() throws {
        let (store, p) = try makeGraph()
        let g = try store.loadGraphIndex()
        let paths = PathFinder(graph: g).kShortestPaths(from: g.index(of: p["a"]!.id)!, to: g.index(of: p["d"]!.id)!, k: 5)
        XCTAssertEqual(paths.count, 2)
        XCTAssertEqual(paths.map(\.hopCount), [2, 3])
        XCTAssertEqual(Set(paths).count, paths.count)
    }

    func testTemporalFilter() throws {
        let store = try makeStore()
        let a = try person(store, "A"), b = try person(store, "B")
        let s = try source(store)
        try store.addRelationship(Relationship(fromID: a.id, toID: b.id, type: .sameFilm, verification: .sourced, confidence: 0.9,
                                               startDate: HistoricalDate(year: 2010), provenance: "t"),
                                  evidence: [EvidenceInput(sourceID: s.id, description: "d", extractedBy: "t")])
        let g = try store.loadGraphIndex()
        let f = PathFinder(graph: g)
        XCTAssertNotNil(f.shortestPath(from: 0, to: 1, filter: EdgeFilter(yearRange: 2005...2012)))
        XCTAssertNil(f.shortestPath(from: 0, to: 1, filter: EdgeFilter(yearRange: 1990...2000)))
    }

    func testComponentsAndCommunities() throws {
        let (store, _) = try makeGraph()
        let g = try store.loadGraphIndex()
        let f = PathFinder(graph: g)
        XCTAssertEqual(Set(f.connectedComponents()).count, 2)
        XCTAssertEqual(f.communities().count, g.nodeCount)
    }

    func testMultiConnection() throws {
        let (store, p) = try makeGraph()
        let g = try store.loadGraphIndex()
        let r = PathFinder(graph: g).multiConnection([p["a"]!.id, p["c"]!.id, p["x"]!.id])
        XCTAssertEqual(r.pairs.count, 3)
        XCTAssertEqual(r.disconnectedPairs.count, 2)
        XCTAssertTrue(r.networkNodes.contains(g.index(of: p["b"]!.id)!))
    }
}
