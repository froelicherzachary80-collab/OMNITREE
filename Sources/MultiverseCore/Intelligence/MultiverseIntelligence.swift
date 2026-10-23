import Foundation

/// One tool invocation in the visible research trace.
public struct ToolStep: Sendable, Hashable {
    public let tool: String
    public let input: String
    public let output: String
}

public struct AssistantResponse: Sendable {
    public var text: String
    public var intent: ResearchIntent
    public var steps: [ToolStep] = []
    public var paths: [ExplainedPath] = []
    public var report: ResearchReport?
    /// People the UI should highlight in the universe (e.g. the merged path network).
    public var highlightPersonIDs: [EntityID] = []
    public var highlightRelationshipIDs: [EntityID] = []
    /// When a name matched several people, the candidates for the user to choose from.
    public var disambiguation: [Person] = []
    public var queuedJobIDs: [EntityID] = []
    /// Whether the text was rephrased by a language model (always from the tool results above).
    public var modelUsed: String?
}

/// MULTIVERSE INTELLIGENCE ENGINE — the orchestrator behind "Ask Multiverse AI".
///
/// Every answer is produced by executing real functions (graph search, pathfinding, kinship,
/// research jobs) and reporting their results. The optional language model is used only to map
/// unusual phrasings to a tool call and to rephrase grounded results; it never adds facts.
public final class MultiverseIntelligence: @unchecked Sendable {
    public let store: GraphStore
    public let scheduler: ResearchScheduler
    public var model: LanguageModel?
    /// Whether to let the model rephrase answers (results are always shown verbatim in the trace).
    public var allowModelRephrasing = false

    public init(store: GraphStore, scheduler: ResearchScheduler, model: LanguageModel? = nil) {
        self.store = store; self.scheduler = scheduler; self.model = model
    }

    public static let selfPersonPreference = "self_person_id"

    // MARK: Entry point

    public func ask(_ question: String, runResearchNow: Bool = true) async -> AssistantResponse {
        var intent = IntentParser.parse(question)
        var steps: [ToolStep] = [ToolStep(tool: "nlu.ruleParser", input: question, output: describe(intent))]
        var modelName: String? = nil
        if case .unknown = intent, let model, await model.isAvailable() {
            if let reply = try? await model.complete(system: IntentParser.modelSchemaPrompt, prompt: question, maxTokens: 200) {
                intent = IntentParser.intent(fromModelJSON: reply, original: question)
                steps.append(ToolStep(tool: "nlu.\(model.name)", input: question, output: describe(intent)))
                modelName = model.name
            }
        }
        var response: AssistantResponse
        do {
            response = try await execute(intent, runResearchNow: runResearchNow)
        } catch {
            response = AssistantResponse(text: "I couldn't complete that: \(error)", intent: intent)
        }
        response.steps = steps + response.steps
        if allowModelRephrasing, let model, !response.paths.isEmpty, await model.isAvailable() {
            let facts = response.paths.map(\.sentence).joined(separator: "\n")
            if let text = try? await model.complete(
                system: "Rewrite the FACTS as a short friendly explanation. Use only the facts given. Do not add people, relationships or dates.",
                prompt: "FACTS:\n\(facts)", maxTokens: 300) {
                response.text = text + "\n\n" + response.text
                modelName = model.name
            }
        }
        response.modelUsed = modelName
        return response
    }

    private func describe(_ intent: ResearchIntent) -> String {
        switch intent {
        case .unknown: return "unrecognised"
        default: return "\(intent.toolName) \(String(describing: intent))"
        }
    }

    // MARK: Name resolution

    enum Resolution { case one(Person), many([Person]), none(String) }

    func resolve(_ name: String) throws -> Resolution {
        if name == "me" {
            if let id = try store.preference(Self.selfPersonPreference), let p = try store.person(id) { return .one(p) }
            return .none("You haven't chosen your own profile yet. Open your profile and tap “This is me”.")
        }
        let hits = try store.searchPeople(name, includePrivate: true, limit: 8)
        let exact = hits.filter { $0.displayName.caseInsensitiveCompare(name) == .orderedSame || $0.aliases.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
        if exact.count == 1 { return .one(exact[0]) }
        if exact.count > 1 { return .many(exact) }   // same name ≠ same person: ask
        if hits.count == 1 { return .one(hits[0]) }
        if hits.count > 1 { return .many(hits) }
        return .none(name)
    }

    // MARK: Execution

    func execute(_ intent: ResearchIntent, runResearchNow: Bool) async throws -> AssistantResponse {
        switch intent {
        case .help:
            return AssistantResponse(text: Self.helpText, intent: intent)
        case .unknown(let text):
            return AssistantResponse(text: "I can only answer by running graph and research tools, and I couldn't map “\(text)” to one.\n\n" + Self.helpText, intent: intent)
        case .find(let name):
            let hits = try store.searchPeople(name, limit: 20)
            var r = AssistantResponse(text: hits.isEmpty ? "No one named “\(name)” is in your universe yet. Ask me to “research \(name)” to look them up on Wikidata."
                                                         : "Found \(hits.count) matching profile\(hits.count == 1 ? "" : "s").", intent: intent)
            r.steps.append(ToolStep(tool: "graph.search", input: name, output: "\(hits.count) results"))
            r.disambiguation = hits
            r.highlightPersonIDs = hits.map(\.id)
            return r
        case .connect(let a, let b, let exhaustive):
            return try await connect(a, b, exhaustive: exhaustive, intent: intent, runResearchNow: runResearchNow)
        case .connectGroup(let category):
            let ids = try store.people(inCategory: category).map(\.id)
            return try connectMany(ids, label: category.displayName + "s", intent: intent)
        case .connectMany(let names):
            var ids: [EntityID] = []
            var missing: [String] = []
            for n in names { if case .one(let p) = try resolve(n) { ids.append(p.id) } else { missing.append(n) } }
            var r = try connectMany(ids, label: "these people", intent: intent)
            if !missing.isEmpty { r.text += "\nNot found or ambiguous: \(missing.joined(separator: ", "))." }
            return r
        case .nearest(let from, let category):
            return try nearest(from, category: category, intent: intent)
        case .commonAncestors(let a, let b):
            return try commonAncestors(a, b, intent: intent)
        case .researchPerson(let name):
            return await research(.wikidataSearch, target: name, intent: intent, runNow: runResearchNow)
        case .researchFilmography(let name):
            guard case .one(let p) = try resolve(name) else {
                return await research(.wikidataSearch, target: name, intent: intent, runNow: runResearchNow,
                                      note: "I didn't have \(name) yet, so I'm researching them first. Ask for the filmography again afterwards.")
            }
            return await research(.wikidataFilmography, target: p.id, personID: p.id, intent: intent, runNow: runResearchNow)
        case .researchGroup(let name):
            return try await researchGroup(name, intent: intent, runNow: runResearchNow)
        case .researchChannel(let ref):
            return await research(.youtubeChannel, target: ref, intent: intent, runNow: runResearchNow)
        case .collaborationsBetween(let ca, let cb):
            return try crossCategory(ca, cb, intent: intent)
        }
    }

    private func connect(_ a: String, _ b: String, exhaustive: Bool, intent: ResearchIntent, runResearchNow: Bool) async throws -> AssistantResponse {
        var resp = AssistantResponse(text: "", intent: intent)
        var people: [Person] = []
        for name in [a, b] {
            switch try resolve(name) {
            case .one(let p): people.append(p)
            case .many(let ps):
                resp.text = "Several people match “\(name)”. Pick the right one — I never assume two people with the same name are the same person."
                resp.disambiguation = ps
                return resp
            case .none(let msg):
                if name == "me" { resp.text = msg; return resp }
                resp.text = "“\(name)” isn't in your universe yet."
                if runResearchNow {
                    let sub = await research(.wikidataSearch, target: name, intent: intent, runNow: true)
                    resp.steps += sub.steps
                    resp.report = sub.report
                    resp.queuedJobIDs = sub.queuedJobIDs
                    if case .one(let p) = try resolve(name) { people.append(p); resp.text = "" } else { resp.text += " " + sub.text; return resp }
                } else { return resp }
            }
        }
        let graph = try store.loadGraphIndex()
        let finder = PathFinder(graph: graph)
        let narrator = PathNarrator(store: store, graph: graph)
        guard let report = finder.connectionReport(from: people[0].id, to: people[1].id, alternatives: exhaustive ? 8 : 3) else {
            resp.text = "One of these people isn't loaded in the graph index."
            return resp
        }
        resp.steps.append(ToolStep(tool: "pathfinder.connectionReport", input: "\(people[0].displayName) → \(people[1].displayName)",
                                   output: report.isConnected ? "shortest \(report.shortest!.hopCount) hops" : "no documented path"))
        guard report.isConnected else {
            if let possible = report.possibleViaCandidates {
                let ex = try narrator.explain(possible, title: "Possible connection — research required")
                resp.paths = [ex]
                resp.text = "No documented connection exists between \(people[0].displayName) and \(people[1].displayName) using established relationships.\n" +
                    "Possible connection — research required: \(ex.sentence)\nIt relies on \(ex.hops.filter { !$0.verification.isEstablished }.count) unverified candidate edge(s) in your review queue."
            } else {
                resp.text = "No documented connection exists between \(people[0].displayName) and \(people[1].displayName) in your universe. I won't invent one. Research either person to expand the graph."
            }
            return resp
        }
        var explained: [ExplainedPath] = []
        var seen = Set<GraphPath>()
        func add(_ p: GraphPath?, _ title: String) throws {
            guard let p, seen.insert(p).inserted || title.contains("only") else { return }
            explained.append(try narrator.explain(p, title: title))
        }
        try add(report.shortest, "Shortest path (\(report.shortest!.hopCount) hop\(report.shortest!.hopCount == 1 ? "" : "s"))")
        try add(report.strongest, "Strongest documented path")
        try add(report.familyOnly, "Family-only path")
        try add(report.collaborationOnly, "Collaboration-only path")
        for (i, m) in report.mixed.enumerated() { try add(m, "Mixed relationship path \(i + 1)") }
        resp.paths = explained
        var lines = ["\(people[0].displayName) and \(people[1].displayName) are connected by documented relationships."]
        for e in explained { lines.append("• \(e.title): \(e.sentence)") }
        if report.familyOnly == nil { lines.append("• No family-only path exists — they are not shown as related by kinship.") }
        if report.collaborationOnly == nil { lines.append("• No collaboration-only path exists.") }
        resp.text = lines.joined(separator: "\n")
        resp.highlightPersonIDs = Array(Set(explained.flatMap(\.personIDs)))
        resp.highlightRelationshipIDs = Array(Set(explained.flatMap(\.relationshipIDs)))
        return resp
    }

    private func connectMany(_ ids: [EntityID], label: String, intent: ResearchIntent) throws -> AssistantResponse {
        var resp = AssistantResponse(text: "", intent: intent)
        guard ids.count >= 2 else {
            resp.text = "I need at least two \(label) in your universe to compare. You have \(ids.count)."
            return resp
        }
        let graph = try store.loadGraphIndex()
        let report = PathFinder(graph: graph).multiConnection(Array(ids.prefix(40)))
        let narrator = PathNarrator(store: store, graph: graph)
        resp.steps.append(ToolStep(tool: "pathfinder.multiConnection", input: "\(min(40, ids.count)) people",
                                   output: "\(report.pairs.count - report.disconnectedPairs.count)/\(report.pairs.count) pairs connected"))
        let names = Dictionary(uniqueKeysWithValues: try store.people(ids).map { ($0.id, $0.displayName) })
        var lines = ["Pairwise documented connections among \(label): \(report.pairs.count - report.disconnectedPairs.count) of \(report.pairs.count) pairs are connected."]
        for pair in report.pairs.prefix(30) {
            if let p = pair.path {
                let ex = try narrator.explain(p, title: "\(names[pair.a] ?? "?") ↔ \(names[pair.b] ?? "?")")
                resp.paths.append(ex)
                lines.append("• \(ex.sentence)")
            } else {
                lines.append("• \(names[pair.a] ?? "?") ↔ \(names[pair.b] ?? "?"): no documented connection")
            }
        }
        lines.append("Shared network: \(report.networkNodes.count) people, \(report.networkEdges.count) relationships.")
        resp.text = lines.joined(separator: "\n")
        resp.highlightPersonIDs = report.networkNodes.map(graph.id(of:))
        resp.highlightRelationshipIDs = report.networkEdges.map { graph.edges[Int($0)].id }
        return resp
    }

    private func nearest(_ from: String, category: PersonCategory, intent: ResearchIntent) throws -> AssistantResponse {
        var resp = AssistantResponse(text: "", intent: intent)
        guard case .one(let person) = try resolve(from) else {
            resp.text = from == "me" ? "Set your own profile first (“This is me” on your profile)." : "I couldn't identify “\(from)”."
            return resp
        }
        let graph = try store.loadGraphIndex()
        guard let start = graph.index(of: person.id) else { return resp }
        let path = PathFinder(graph: graph).nearest(from: start) { graph.categories[Int($0)].contains(category) }
        resp.steps.append(ToolStep(tool: "pathfinder.nearest", input: "\(person.displayName) → any \(category.displayName)",
                                   output: path.map { "\($0.hopCount) hops" } ?? "none"))
        guard let path else {
            resp.text = "There is no documented path from \(person.displayName) to any \(category.displayName) in your universe."
            return resp
        }
        let ex = try PathNarrator(store: store, graph: graph).explain(path, title: "Closest \(category.displayName)")
        resp.paths = [ex]
        resp.text = "Closest documented \(category.displayName): \(ex.hops.last?.toName ?? "?") — \(path.hopCount) hop\(path.hopCount == 1 ? "" : "s").\n\(ex.sentence)"
        resp.highlightPersonIDs = ex.personIDs
        resp.highlightRelationshipIDs = ex.relationshipIDs
        return resp
    }

    private func commonAncestors(_ a: String, _ b: String, intent: ResearchIntent) throws -> AssistantResponse {
        var resp = AssistantResponse(text: "", intent: intent)
        guard case .one(let pa) = try resolve(a), case .one(let pb) = try resolve(b) else {
            resp.text = "I need both people to be uniquely identified in your universe first."
            return resp
        }
        let graph = try store.loadGraphIndex()
        guard let ia = graph.index(of: pa.id), let ib = graph.index(of: pb.id) else { return resp }
        let ancestors = KinshipCalculator.commonAncestors(ia, ib, in: graph)
        resp.steps.append(ToolStep(tool: "genealogy.commonAncestors", input: "\(pa.displayName), \(pb.displayName)", output: "\(ancestors.count) lowest common ancestors"))
        guard let best = ancestors.first, let relation = KinshipCalculator.relation(ia, ib, in: graph) else {
            resp.text = "No shared ancestor is documented between \(pa.displayName) and \(pb.displayName). Possible connection — research required: import more generations or link ancestors to Wikidata/WikiTree records."
            return resp
        }
        let narrator = PathNarrator(store: store, graph: graph)
        for anc in ancestors.prefix(4) {
            let ancName = try store.person(graph.id(of: anc.ancestor))?.displayName ?? "?"
            resp.paths.append(try narrator.explain(anc.chainA, title: "\(pa.displayName) → \(ancName) (\(anc.generationsFromA) generations)"))
            resp.paths.append(try narrator.explain(anc.chainB, title: "\(pb.displayName) → \(ancName) (\(anc.generationsFromB) generations)"))
        }
        let ancName = try store.person(graph.id(of: best.ancestor))?.displayName ?? "?"
        resp.text = "Yes — documented common ancestor: \(ancName) (\(best.generationsFromA) generations from \(pa.displayName), \(best.generationsFromB) from \(pb.displayName)).\nRelationship: \(pa.displayName) is \(pb.displayName)'s \(relation.term)."
        resp.highlightPersonIDs = Array(Set(resp.paths.flatMap(\.personIDs)))
        resp.highlightRelationshipIDs = Array(Set(resp.paths.flatMap(\.relationshipIDs)))
        return resp
    }

    private func crossCategory(_ a: PersonCategory, _ b: PersonCategory, intent: ResearchIntent) throws -> AssistantResponse {
        var resp = AssistantResponse(text: "", intent: intent)
        let setA = Set(try store.people(inCategory: a).map(\.id)), setB = Set(try store.people(inCategory: b).map(\.id))
        var found: [Relationship] = []
        for id in setA {
            for r in try store.relationships(of: id, includeUnestablished: false) where r.type.isCollaboration && setB.contains(r.other(than: id)) {
                found.append(r)
            }
        }
        let unique = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x }).values
        resp.steps.append(ToolStep(tool: "graph.crossCategoryCollaborations", input: "\(a.rawValue) × \(b.rawValue)", output: "\(unique.count) relationships"))
        let names = Dictionary(uniqueKeysWithValues: try store.people(Array(setA.union(setB))).map { ($0.id, $0.displayName) })
        resp.text = unique.isEmpty
            ? "No documented collaborations between \(a.displayName)s and \(b.displayName)s are in your universe yet."
            : "Documented collaborations between \(a.displayName)s and \(b.displayName)s:\n" +
              unique.prefix(40).map { "• \(names[$0.fromID] ?? "?") — \($0.type.displayName)\($0.contextLabel.map { " (\($0))" } ?? "") — \(names[$0.toID] ?? "?")" }.joined(separator: "\n")
        resp.highlightRelationshipIDs = unique.map(\.id)
        resp.highlightPersonIDs = Array(Set(unique.flatMap { [$0.fromID, $0.toID] }))
        return resp
    }

    private func researchGroup(_ name: String, intent: ResearchIntent, runNow: Bool) async throws -> AssistantResponse {
        // Local communities first (e.g. imported SMP rosters), then Wikidata.
        if let community = try store.allCommunities().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            let members = try store.members(ofCommunity: community.id)
            var r = try connectMany(members, label: "members of \(community.name)", intent: intent)
            r.steps.insert(ToolStep(tool: "graph.community", input: name, output: "\(members.count) members"), at: 0)
            return r
        }
        let hits = try await WikidataConnector(http: scheduler.http).search(name, limit: 3)
        guard let top = hits.first else {
            return AssistantResponse(text: "I couldn't find a community called “\(name)” locally or on Wikidata. You can import a member list (CSV of names or channel IDs) in Research → Import.", intent: intent)
        }
        var resp = AssistantResponse(text: "", intent: intent)
        resp.steps.append(ToolStep(tool: "research.wikidataSearch", input: name, output: "\(top.label) (\(top.qid))"))
        let kind = IntentParser.category(in: name + " " + (top.description ?? "")) == .minecraftCreator ? "minecraftSMP" : "creatorGroup"
        let agent = WikidataResearchAgent(store: store, http: scheduler.http)
        let report = try await agent.importGroup(qid: top.qid, kind: kind)
        resp.report = report
        resp.steps.append(ToolStep(tool: "research.wikidataGroup", input: top.qid, output: "\(report.peopleAdded.count) new people, \(report.discoveries.count) membership edges"))
        if report.discoveries.isEmpty && report.peopleAdded.isEmpty {
            resp.text = "Wikidata lists no individual members for \(top.label). Many creator communities (e.g. Minecraft SMPs) aren't modelled there; import a roster you trust instead."
        } else {
            resp.text = "Imported \(top.label) from Wikidata: \(report.peopleAdded.count) new people, \(report.discoveries.count) documented membership connections."
        }
        return resp
    }

    private func research(_ kind: ResearchJobKind, target: String, personID: EntityID? = nil, intent: ResearchIntent,
                          runNow: Bool, note: String? = nil) async -> AssistantResponse {
        var resp = AssistantResponse(text: "", intent: intent)
        do {
            let job = try scheduler.enqueue(ResearchJob(kind: kind, target: target, personID: personID, priority: 10))
            resp.queuedJobIDs = [job.id]
            resp.steps.append(ToolStep(tool: "research.enqueue", input: "\(kind.rawValue): \(target)", output: "job \(job.id.prefix(8))"))
            guard runNow else {
                resp.text = "Queued research job for \(target). Results appear in Research."
                return resp
            }
            await scheduler.run(job)
            let finished = try scheduler.job(job.id)
            let report = scheduler.report(for: job.id)
            resp.report = report
            resp.steps.append(ToolStep(tool: "research.\(kind.rawValue)", input: target,
                                       output: "\(finished?.status.rawValue ?? "?")\(finished?.lastError.map { ": \($0)" } ?? "")"))
            var lines: [String] = []
            if let note { lines.append(note) }
            if let err = finished?.lastError { lines.append("Research did not finish: \(err)") }
            if let report {
                lines.append("Sources inspected: \(report.sourcesInspected.count). New people: \(report.peopleAdded.count). Relationships recorded: \(report.discoveries.count).")
                for d in report.discoveries.prefix(12) { lines.append("• \(d.summary) [\(d.status.displayName)]") }
                if report.discoveries.count > 12 { lines.append("• …and \(report.discoveries.count - 12) more") }
                for u in report.uncertainClaims.prefix(5) { lines.append("Uncertain: \(u)") }
                for r in report.rejectedClaims.prefix(5) { lines.append("Rejected: \(r)") }
                for q in report.unansweredQuestions { lines.append("Unanswered: \(q)") }
                resp.highlightPersonIDs = report.peopleAdded + report.peopleUpdated
                resp.highlightRelationshipIDs = report.discoveries.map(\.relationshipID)
            }
            resp.text = lines.joined(separator: "\n")
        } catch {
            resp.text = "Couldn't start research: \(error)"
        }
        return resp
    }

    public static let helpText = """
    Try:
    • “How am I connected to McKenna Grace?”
    • “How is Ada Lovelace connected to Charles Babbage?”
    • “Show every documented connection between A and B”
    • “Find my shortest connection to a Minecraft YouTuber”
    • “How are all my friends connected?”
    • “Do I share any documented ancestors with <name>?”
    • “Research McKenna Grace” / “Filmography of McKenna Grace”
    • “Research the members of Hermitcraft”
    • “Research channel https://youtube.com/@handle”
    """
}
