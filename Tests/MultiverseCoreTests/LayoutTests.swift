import XCTest
@testable import MultiverseCore

final class LayoutTests: XCTestCase {
    func testCenterlineMeetsEndpoints() {
        let a = SIMD3<Float>(0, 0, 0), b = SIMD3<Float>(10, 5, -3)
        let line = BranchGeometry.centerline(from: a, to: b, seed: 42, segments: 20)
        XCTAssertEqual(line.count, 21)
        XCTAssertLessThan(vlen(line.first! - a), 1e-4)
        XCTAssertLessThan(vlen(line.last! - b), 1e-4)
        XCTAssertEqual(BranchGeometry.centerline(from: a, to: b, seed: 42, segments: 20), line, "deterministic per seed")
        XCTAssertEqual(BranchGeometry.tendrils(along: line, count: 3, seed: 1).count, 3)
    }

    func testRibbonIndexing() {
        var v: [BranchVertex] = [], i: [UInt32] = []
        BranchGeometry.appendRibbon([.zero, SIMD3(1, 0, 0), SIMD3(2, 0, 0)], width: 1, color: SIMD4(1, 1, 1, 1), edgeIndex: 3, kind: 0,
                                    established: true, vertices: &v, indices: &i)
        XCTAssertEqual(v.count, 6)
        XCTAssertEqual(i.count, 12)
        XCTAssertTrue(i.allSatisfy { $0 < 6 })
        XCTAssertEqual(MemoryLayout<BranchVertex>.stride, 64, "matches the MSL struct layout")
        XCTAssertEqual(MemoryLayout<NodeInstance>.stride, 48)
    }

    func testLayoutAndScene() throws {
        let store = try makeStore()
        try SampleData.load(into: store)
        let g = try store.loadGraphIndex()
        let comm = PathFinder(graph: g).communities(filter: .includingCandidates)
        let layout = ForceLayout3D()
        let pos = layout.run(graph: g, positions: layout.seedPositions(count: g.nodeCount, communities: comm), iterations: 80)
        XCTAssertEqual(pos.count, g.nodeCount)
        XCTAssertTrue(pos.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        let attrs = g.nodeIDs.map { NodeAttributes(name: $0, categories: g.categories[g.nodeIDs.firstIndex(of: $0)!], country: nil, birthYear: nil,
                                                   communities: [], isPrivate: false, isSample: true) }
        var filter = UniverseFilter()
        let scene = UniverseSceneBuilder.build(graph: g, positions: pos, attributes: attrs, filter: filter, communities: comm,
                                               cameraPosition: SIMD3(0, 0, 80), highlighted: [], quality: .balanced)
        XCTAssertEqual(scene.nodes.count, g.nodeCount)
        XCTAssertEqual(scene.edgeSlots.count, g.edgeCount)
        XCTAssertTrue(scene.branchIndices.allSatisfy { Int($0) < scene.branchVertices.count })

        filter.modes = [.minecraft]
        let mc = filter.visibleNodes(graph: g, attributes: attrs).filter { $0 }.count
        XCTAssertEqual(mc, 4)
        filter.modes = [.minecraft, .historical]
        XCTAssertEqual(filter.visibleNodes(graph: g, attributes: attrs).filter { $0 }.count, 7, "modes union: 4 Minecraft + 3 historical")
        filter.showSampleData = false
        XCTAssertEqual(filter.visibleNodes(graph: g, attributes: attrs).filter { $0 }.count, 0)
    }

    func testViewportBudgetClustersTheRest() throws {
        let b = GraphIndex.Builder()
        for i in 0..<500 { b.addNode("n\(i)") }
        for i in 1..<500 { b.addEdge(id: "e\(i)", from: "n\(i)", to: "n\(i / 2)", type: .publicFriendship, verification: .sourced, confidence: 1) }
        let g = b.build()
        let pos = (0..<500).map { SIMD3<Float>(Float($0), 0, 0) }
        let (nodes, clusters) = ViewportSelector.select(graph: g, positions: pos, visible: Array(repeating: true, count: 500),
                                                        communities: (0..<500).map { Int32($0 % 5) }, cameraPosition: .zero,
                                                        mustInclude: [499], budget: 100)
        XCTAssertEqual(nodes.count, 100)
        XCTAssertTrue(nodes.contains(499))
        XCTAssertEqual(clusters.reduce(0) { $0 + $1.memberCount }, 400)
    }
}
