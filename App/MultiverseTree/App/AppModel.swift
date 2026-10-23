import Foundation
import SwiftUI
import Observation
import simd
import MultiverseCore

/// Central app state: owns the graph database, research scheduler, MIE, layout and render state.
@MainActor
@Observable
final class AppModel {
    // MARK: Engine
    let store: GraphStore
    let http: ResearchHTTP
    let scheduler: ResearchScheduler
    let intelligence: MultiverseIntelligence

    // MARK: Graph & layout (rebuilt off the main thread)
    private(set) var graph: GraphIndex?
    private(set) var positions: [SIMD3<Float>] = []
    private(set) var communities: [Int32] = []
    private(set) var attributes: [NodeAttributes] = []
    private(set) var scene: UniverseSceneData?
    private(set) var isRebuilding = false
    private(set) var personCount = 0
    private(set) var relationshipCount = 0
    var sceneVersion = 0

    // MARK: Exploration state
    var filter = UniverseFilter() { didSet { if filter != oldValue { rebuildScene() } } }
    var selectedPersonID: EntityID? { didSet { applySelection() } }
    var selfPersonID: EntityID?
    @ObservationIgnored private var reveal: PathRevealAnimator?
    private(set) var isRevealing = false
    private(set) var revealPlaying = false
    private(set) var revealPaths: [ExplainedPath] = []
    var showEvidencePanel = false
    var revealPhase = ""
    @ObservationIgnored private var growth = BranchGrowthAnimator()

    // MARK: Settings
    var quality: RenderQuality = .balanced { didSet { save("quality", quality.rawValue); rebuildScene() } }
    var autoQuality = true { didSet { save("autoQuality", autoQuality ? "1" : "0") } }
    var offlineMode = false { didSet { http.offline = offlineMode; save("offline", offlineMode ? "1" : "0") } }
    var useOnDeviceModel = true { didSet { save("onDeviceModel", useOnDeviceModel ? "1" : "0"); configureModel() } }
    var ollamaURL = "" { didSet { save("ollamaURL", ollamaURL); configureModel() } }
    var ollamaModel = "qwen2.5:7b-instruct" { didSet { save("ollamaModel", ollamaModel); configureModel() } }
    var youtubeAPIKey: String = "" {
        didSet { KeychainStore.setString(youtubeAPIKey, for: "youtube-api-key"); scheduler.youtubeAPIKey = youtubeAPIKey }
    }
    var effectiveQuality: RenderQuality = .balanced

    // MARK: Research activity feed
    var activity: [String] = []
    var jobs: [ResearchJob] = []
    private let governor = PerformanceGovernor()
    @ObservationIgnored weak var renderer: CosmicRenderer?

    static func databaseURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MultiverseTree", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return dir.appendingPathComponent("multiverse.sqlite")
    }

    init() {
        let url = Self.databaseURL()
        let cipher = (try? AESGCMFieldCipher(keyData: KeychainStore.databaseKey())).map { $0 as FieldCipher } ?? UnavailableCipher()
        let store: GraphStore
        do { store = try GraphStore(path: url.path, cipher: cipher) }
        catch { fatalError("Unable to open the Multiverse database: \(error)") }
        self.store = store
        http = ResearchHTTP(store: store)
        scheduler = ResearchScheduler(store: store, http: http, youtubeAPIKey: KeychainStore.string("youtube-api-key"))
        intelligence = MultiverseIntelligence(store: store, scheduler: scheduler)
        youtubeAPIKey = KeychainStore.string("youtube-api-key") ?? ""

        quality = RenderQuality(rawValue: ((try? store.preference("quality")) ?? nil) ?? "") ?? .balanced
        autoQuality = ((try? store.preference("autoQuality")) ?? nil) != "0"
        offlineMode = ((try? store.preference("offline")) ?? nil) == "1"
        useOnDeviceModel = ((try? store.preference("onDeviceModel")) ?? nil) != "0"
        ollamaURL = ((try? store.preference("ollamaURL")) ?? nil) ?? ""
        ollamaModel = ((try? store.preference("ollamaModel")) ?? nil) ?? "qwen2.5:7b-instruct"
        selfPersonID = (try? store.preference(MultiverseIntelligence.selfPersonPreference)) ?? nil

        _ = try? scheduler.recoverInterruptedJobs()
        scheduler.onEvent = { [weak self] _, event in
            Task { @MainActor in self?.handle(event) }
        }
        governor.onChange = { [weak self] q in self?.effectiveQuality = q; self?.renderer?.quality = q }
        configureModel()
        refreshJobs()
        rebuildGraph()
    }

    private func save(_ key: String, _ value: String) { try? store.setPreference(key, value) }

    private func configureModel() {
        if let url = URL(string: ollamaURL), !ollamaURL.isEmpty {
            intelligence.model = OllamaLanguageModel(baseURL: url, model: ollamaModel)
        } else if useOnDeviceModel {
            intelligence.model = OnDeviceLanguageModel()
        } else {
            intelligence.model = nil
        }
    }

    // MARK: Graph rebuild

    /// Reloads the traversal index and layout in the background, then rebuilds the render scene.
    func rebuildGraph(animateNewRelationships newRelationshipIDs: [EntityID] = []) {
        guard !isRebuilding else { return }
        isRebuilding = true
        let store = self.store
        let previous = Dictionary(uniqueKeysWithValues: (graph?.nodeIDs ?? []).enumerated().compactMap { i, id in
            i < positions.count ? (id, positions[i]) : nil
        })
        Task.detached(priority: .userInitiated) {
            do {
                let g = try store.loadGraphIndex()
                let attrs = try store.nodeAttributes(for: g)
                let comm = PathFinder(graph: g).communities(filter: .includingCandidates)
                var persisted = try store.loadLayout()
                for (id, p) in previous { persisted[id] = p }
                var existing: [Int: SIMD3<Float>] = [:]
                var pinned = Set<Int32>()
                for (i, id) in g.nodeIDs.enumerated() {
                    if let p = persisted[id] { existing[i] = p; pinned.insert(Int32(i)) }
                }
                let layout = ForceLayout3D()
                var pos = layout.seedPositions(count: g.nodeCount, communities: comm, existing: existing)
                // New nodes settle around pinned ones; a full relayout only when nothing is persisted.
                let iterations = pinned.isEmpty ? (g.nodeCount > 20_000 ? 60 : 300) : (pinned.count == g.nodeCount ? 0 : 120)
                if iterations > 0 { pos = layout.run(graph: g, positions: pos, iterations: iterations, pinned: pinned) }
                let toSave = Dictionary(uniqueKeysWithValues: g.nodeIDs.enumerated().map { ($1, pos[$0]) })
                try? store.saveLayout(toSave)
                let people = try store.personCount(), rels = try store.relationshipCount()
                await MainActor.run {
                    self.graph = g
                    self.positions = pos
                    self.communities = comm
                    self.attributes = attrs
                    self.personCount = people
                    self.relationshipCount = rels
                    self.isRebuilding = false
                    self.rebuildScene()
                    self.growNewBranches(newRelationshipIDs)
                }
            } catch {
                await MainActor.run {
                    self.isRebuilding = false
                    self.activity.insert("Graph load failed: \(error)", at: 0)
                }
            }
        }
    }

    func rebuildScene() {
        guard let graph else { return }
        effectiveQuality = autoQuality ? governor.recommended(base: quality, nodeCount: graph.nodeCount) : quality
        var mustInclude = Set<Int32>()
        if let id = selectedPersonID, let i = graph.index(of: id) { mustInclude.insert(i) }
        for p in revealPaths { for id in p.personIDs { if let i = graph.index(of: id) { mustInclude.insert(i) } } }
        let cam = renderer?.camera.position ?? SIMD3(0, 0, 90)
        let s = UniverseSceneBuilder.build(graph: graph, positions: positions, attributes: attributes, filter: filter,
                                           communities: communities, cameraPosition: cam, highlighted: mustInclude, quality: effectiveQuality)
        scene = s
        sceneVersion += 1
        renderer?.quality = effectiveQuality
        renderer?.upload(s)
        applySelection()
    }

    func edgeSlot(forRelationship id: EntityID) -> Int? {
        guard let graph, let scene else { return nil }
        // Linear scan over visible slots only; bounded by the quality's edge budget.
        return scene.edgeSlots.firstIndex { graph.edges[Int($0)].id == id }
    }

    private func applySelection() {
        guard let renderer, let graph, let scene else { return }
        renderer.resetBaseEdgeStates()
        var nodes = Set<Int32>()
        if let id = selectedPersonID, let i = graph.index(of: id) {
            nodes.insert(i)
            for (slot, e) in scene.edgeSlots.enumerated() {
                let edge = graph.edges[Int(e)]
                if edge.from == i || edge.to == i {
                    renderer.setBaseEdgeState(slot: slot, SIMD4(1, 1, renderer.shaderTime, 0))
                    nodes.insert(edge.other(i))
                }
            }
            if let p = renderer.position(ofNode: i) {
                renderer.camera.frame([p] + nodes.compactMap { renderer.position(ofNode: $0) }, padding: 1.8)
            }
        }
        renderer.setBaseNodeHighlight(nodes)
    }

    private func growNewBranches(_ ids: [EntityID]) {
        let slots = ids.compactMap(edgeSlot(forRelationship:))
        if !slots.isEmpty { growth.grow(slots: slots, now: CACurrentMediaTime()) }
    }

    // MARK: Per-frame overrides (called from the render loop on the main thread)

    func frameOverrides(now: Double, shaderTime: Float) -> FrameOverrides {
        var o = FrameOverrides()
        if var r = reveal {
            r.tick(now: now)
            let f = r.frame(shaderTime: shaderTime)
            reveal = r
            o.edgeStates = f.edgeStates
            o.dim = f.dim
            o.nodeHighlight = f.nodeHighlight
            if r.isPlaying, let renderer, !f.focusPoints.isEmpty {
                let pts = f.focusPoints.compactMap { renderer.position(ofNode: $0) }
                if !pts.isEmpty { renderer.camera.frame(pts, padding: f.focusPoints.count > 2 ? 1.3 : 2.4) }
            }
            if revealPhase != f.phaseDescription { revealPhase = f.phaseDescription }
            if f.finished && r.isPlaying {
                reveal?.togglePause()
                revealPlaying = false
                showEvidencePanel = true
            }
        }
        for (slot, s) in growth.states(now: now, shaderTime: shaderTime) { o.edgeStates[slot] = s }
        return o
    }

    func reportFrameTime(_ dt: Double) {
        if autoQuality { governor.sample(frameTime: dt, current: effectiveQuality) }
    }

    // MARK: Path reveal

    func startReveal(_ paths: [ExplainedPath]) {
        revealPaths = paths
        showEvidencePanel = false
        rebuildScene()   // ensure every path node is inside the render budget
        guard let graph else { return }
        let hopPaths = paths.map { p in
            p.hops.compactMap { h -> PathRevealAnimator.Hop? in
                guard let a = graph.index(of: h.fromID), let b = graph.index(of: h.toID) else { return nil }
                return PathRevealAnimator.Hop(edgeSlot: edgeSlot(forRelationship: h.relationshipID), from: a, to: b)
            }
        }
        reveal = PathRevealAnimator(paths: hopPaths)
        isRevealing = true
        revealPlaying = true
    }

    func toggleRevealPause() { reveal?.togglePause(); revealPlaying = reveal?.isPlaying ?? false }
    func replayReveal() { showEvidencePanel = false; reveal?.replay(); revealPlaying = true }
    func scrubReveal(_ fraction: Double) { reveal?.scrub(to: fraction) }
    func endReveal() {
        reveal = nil; isRevealing = false; revealPlaying = false
        revealPaths = []; showEvidencePanel = false; revealPhase = ""
        rebuildScene()
    }

    // MARK: Research

    private func handle(_ event: ResearchEvent) {
        switch event {
        case .progress(_, let msg): activity.insert(msg, at: 0)
        case .inspectedSource(let s): activity.insert("Inspected \(s)", at: 0)
        case .discovered(let d): activity.insert("Discovered: \(d.summary)", at: 0)
        case .rejected(let r): activity.insert("Rejected: \(r)", at: 0)
        case .newPerson: break
        }
        if activity.count > 200 { activity.removeLast(activity.count - 200) }
    }

    func refreshJobs() { jobs = (try? scheduler.jobs()) ?? [] }

    func enqueue(_ job: ResearchJob) {
        _ = try? scheduler.enqueue(job)
        refreshJobs()
        runQueue()
    }

    private var queueRunning = false
    func runQueue() {
        guard !queueRunning else { return }
        queueRunning = true
        let scheduler = self.scheduler
        Task {
            while let next = try? scheduler.nextRunnable() {
                await scheduler.run(next)
                refreshJobs()
                let newIDs = scheduler.report(for: next.id)?.discoveries.map(\.relationshipID) ?? []
                rebuildGraph(animateNewRelationships: newIDs)
            }
            queueRunning = false
            refreshJobs()
            BackgroundResearch.schedule()
        }
    }

    func ask(_ text: String) async -> AssistantResponse {
        let response = await intelligence.ask(text)
        refreshJobs()
        if response.report != nil {
            rebuildGraph(animateNewRelationships: response.highlightRelationshipIDs)
        }
        return response
    }

    // MARK: Profile helpers

    func setSelf(_ id: EntityID) {
        try? store.setPreference(MultiverseIntelligence.selfPersonPreference, id)
        selfPersonID = id
    }

    func loadSampleData() {
        if let me = try? SampleData.load(into: store), selfPersonID == nil { setSelf(me) }
        rebuildGraph()
    }

    func removeSampleData() {
        _ = try? SampleData.remove(from: store)
        if let s = selfPersonID, (try? store.person(s)) == nil { selfPersonID = nil; try? store.setPreference(MultiverseIntelligence.selfPersonPreference, nil) }
        rebuildGraph()
    }

    func deletePerson(_ id: EntityID) {
        try? store.deletePerson(id)
        if selectedPersonID == id { selectedPersonID = nil }
        rebuildGraph()
    }
}
