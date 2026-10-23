// mvt — Multiverse Tree command-line companion.
// Runs the same core engine as the iOS app on a Mac or Linux computer you own, so long research
// jobs can run uninterrupted. Copy the resulting database to the phone via Settings → Data → Restore.
import Foundation
import MultiverseCore

func usage() -> Never {
    print("""
    usage: mvt <database.sqlite> <command> [args]

    commands:
      stats                         graph statistics
      sample                        load the fictional sample universe
      import-gedcom <file.ged>      import a GEDCOM family tree
      export-gedcom [file.ged]      export established family data as GEDCOM
      import-list <file.csv|json>   import a creator / friend list (queues research for QIDs & channels)
      search <name>                 search people
      path <name A> <name B>        documented connection report
      ask <question>                Ask Multiverse AI (runs real tools; research uses the network)
      research <name>               Wikidata research for a person
      jobs                          list research jobs
      run-jobs [max]                run queued research jobs
      duplicates                    scan for duplicate people (creates merge proposals)
      backup <file>                 online backup of the database
    environment:
      MVT_OLLAMA_URL / MVT_OLLAMA_MODEL   optional local LLM for unusual phrasings
      MVT_YOUTUBE_KEY                      YouTube Data API key (free quota)
      MVT_OFFLINE=1                        disable network access
    """)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { usage() }
let dbPath = args.removeFirst()
let command = args.removeFirst()
let env = ProcessInfo.processInfo.environment

do {
    let store = try GraphStore(path: dbPath)
    let http = ResearchHTTP(store: store, offline: env["MVT_OFFLINE"] == "1")
    let scheduler = ResearchScheduler(store: store, http: http, youtubeAPIKey: env["MVT_YOUTUBE_KEY"])
    scheduler.onEvent = { _, event in
        switch event {
        case .progress(_, let msg): print("  … \(msg)")
        case .inspectedSource(let s): print("  ⌕ \(s)")
        case .discovered(let d): print("  + \(d.summary) [\(d.status.displayName)]")
        case .rejected(let r): print("  ✗ \(r)")
        case .newPerson: break
        }
    }
    let mie = MultiverseIntelligence(store: store, scheduler: scheduler)
    if let url = env["MVT_OLLAMA_URL"].flatMap(URL.init(string:)) {
        mie.model = OllamaLanguageModel(baseURL: url, model: env["MVT_OLLAMA_MODEL"] ?? "qwen2.5:7b-instruct")
    }

    switch command {
    case "stats":
        let g = try store.loadGraphIndex()
        let comps = Set(PathFinder(graph: g).connectedComponents()).count
        print("people: \(try store.personCount())  relationships: \(try store.relationshipCount())  components: \(comps)  storage: \(try store.storageBytes() / 1024) KB")
    case "sample":
        let me = try SampleData.load(into: store)
        try store.setPreference(MultiverseIntelligence.selfPersonPreference, me)
        print("Loaded fictional sample universe. 'me' = Sample Explorer.")
    case "import-gedcom":
        guard let file = args.first else { usage() }
        let text = try String(contentsOfFile: file, encoding: .utf8)
        let r = try GEDCOMImporter(store: store).importGEDCOM(text: text, fileName: (file as NSString).lastPathComponent)
        print("Imported \(r.peopleCreated) people, \(r.relationshipsCreated) relationships, \(r.eventsCreated) events (import \(r.importID)).")
        r.warnings.forEach { print("warning: \($0)") }
        let proposals = try MergeEngine(store: store).scanForDuplicates()
        if !proposals.isEmpty { print("\(proposals.count) possible duplicates need review (nothing was merged automatically).") }
    case "export-gedcom":
        let out = try GEDCOMExporter(store: store).export(includePrivate: true)
        if let file = args.first { try out.write(toFile: file, atomically: true, encoding: .utf8) } else { print(out) }
    case "import-list":
        guard let file = args.first else { usage() }
        let data = try Data(contentsOf: URL(fileURLWithPath: file))
        let rows = file.hasSuffix(".json") ? try ListImporter.parseJSON(data) : ListImporter.parseCSV(String(decoding: data, as: UTF8.self))
        let r = try ListImporter(store: store).importRows(rows, defaultCategory: .userImported, scheduler: scheduler, fileName: file)
        print("Created \(r.created.count) people; queued \(r.jobs.count) research jobs. Run `mvt \(dbPath) run-jobs`.")
    case "search":
        for p in try store.searchPeople(args.joined(separator: " ")) {
            print("\(p.id.prefix(8))  \(p.displayName)  [\(p.categories.map(\.displayName).sorted().joined(separator: ", "))]\(p.isSample ? "  SAMPLE" : "")")
        }
    case "path":
        guard args.count >= 2 else { usage() }
        print(await mie.ask("connection between \(args[0]) and \(args[1])", runResearchNow: false).text)
    case "ask":
        let r = await mie.ask(args.joined(separator: " "))
        for s in r.steps { print("[\(s.tool)] \(s.input) → \(s.output)") }
        print(r.text)
        for p in r.paths {
            print("\n\(p.title)  (strength \(String(format: "%.2f", p.strength)))")
            for h in p.hops { print("  \(h.fromName) —\(h.label)→ \(h.toName)  [\(h.verification.displayName)] \(h.sourceURLs.first ?? "")") }
        }
    case "research":
        let r = await mie.ask("research \(args.joined(separator: " "))")
        print(r.text)
    case "jobs":
        for j in try scheduler.jobs() { print("\(j.id.prefix(8))  \(j.status.rawValue.padding(toLength: 18, withPad: " ", startingAt: 0)) \(j.kind.rawValue) \(j.target) \(j.lastError ?? "")") }
    case "run-jobs":
        _ = try scheduler.recoverInterruptedJobs()
        let n = await scheduler.runPending(maxJobs: Int(args.first ?? "") ?? .max)
        print("Ran \(n) jobs.")
    case "duplicates":
        for p in try MergeEngine(store: store).scanForDuplicates() {
            let names = try store.people([p.personA, p.personB]).map(\.displayName)
            print("\(Int(p.score * 100))%  \(names.joined(separator: "  ⟷  "))\n   reasons: \(p.reasons.joined(separator: "; "))\n   conflicts: \(p.conflicts.joined(separator: "; "))")
        }
    case "backup":
        guard let file = args.first else { usage() }
        try store.backup(to: file)
        print("Backed up to \(file)")
    default:
        usage()
    }
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
