import SwiftUI
import UniformTypeIdentifiers
import MultiverseCore

struct ResearchView: View {
    @Environment(AppModel.self) private var model
    @State private var section = 0

    var body: some View {
        VStack {
            Picker("", selection: $section) {
                Text("Jobs").tag(0); Text("Approvals").tag(1); Text("Merges").tag(2); Text("Import").tag(3); Text("Sources").tag(4)
            }
            .pickerStyle(.segmented).padding(.horizontal)
            switch section {
            case 0: JobsList()
            case 1: ApprovalQueue()
            case 2: MergeReview()
            case 3: ImportView()
            default: SourcesDashboard()
            }
        }
        .navigationTitle("Research")
        .onAppear { model.refreshJobs() }
    }
}

struct JobsList: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var channel = ""
    @State private var refreshDaily = false

    var body: some View {
        List {
            Section("New research") {
                HStack {
                    TextField("Person name or Wikidata QID", text: $name)
                    Button("Research") {
                        let t = name.trimmingCharacters(in: .whitespaces)
                        let isQID = t.range(of: "^Q[0-9]+$", options: .regularExpression) != nil
                        model.enqueue(ResearchJob(kind: isQID ? .wikidataEntity : .wikidataSearch, target: t, priority: 5,
                                                  refreshInterval: refreshDaily ? 86_400 : nil))
                        name = ""
                    }.disabled(name.isEmpty)
                }
                HStack {
                    TextField("YouTube channel URL, @handle or ID", text: $channel).textInputAutocapitalization(.never)
                    Button("Add") { model.enqueue(ResearchJob(kind: .youtubeChannel, target: channel, priority: 5)); channel = "" }
                        .disabled(channel.isEmpty)
                }
                Toggle("Schedule daily refresh", isOn: $refreshDaily)
                Button("Scan for duplicate people") { model.enqueue(ResearchJob(kind: .duplicateScan, target: "all")) }
            }
            Section("Queue & history") {
                if model.jobs.isEmpty { Text("No research jobs yet.").foregroundStyle(.secondary) }
                ForEach(model.jobs) { j in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(j.target).lineLimit(1)
                            Spacer()
                            Text(j.status.rawValue).font(.caption).foregroundStyle(color(j.status))
                        }
                        Text(j.kind.rawValue).font(.caption2).foregroundStyle(.secondary)
                        if j.status == .running { ProgressView(value: j.progress) }
                        if let e = j.lastError { Text(e).font(.caption2).foregroundStyle(.orange) }
                    }
                    .swipeActions {
                        if j.status == .paused { Button("Resume") { try? model.scheduler.resume(j.id); model.refreshJobs(); model.runQueue() } }
                        if j.status == .queued { Button("Pause") { try? model.scheduler.pause(j.id); model.refreshJobs() } }
                        if !j.status.isTerminal { Button("Cancel", role: .destructive) { try? model.scheduler.cancel(j.id); model.refreshJobs() } }
                    }
                }
            }
            Section("Live activity") {
                ForEach(Array(model.activity.prefix(30).enumerated()), id: \.offset) { _, a in Text(a).font(.caption2) }
            }
            Section {
                Text("Research runs while the app is open and in brief windows iOS grants in the background. For large uninterrupted jobs, run the free `mvt` companion on your own computer and restore its database here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .refreshable { model.refreshJobs() }
    }

    private func color(_ s: ResearchJobStatus) -> Color {
        switch s { case .completed: .green; case .failed: .red; case .running: .cyan; case .paused, .waitingForApproval: .orange; default: .secondary }
    }
}

/// Manual approval queue for candidate relationships.
struct ApprovalQueue: View {
    @Environment(AppModel.self) private var model
    @State private var refresh = 0

    var body: some View {
        let candidates = (try? model.store.relationships(withStatus: .candidate)) ?? []
        let ids = Array(Set(candidates.flatMap { [$0.fromID, $0.toID] }))
        let names = Dictionary(uniqueKeysWithValues: ((try? model.store.people(ids)) ?? []).map { ($0.id, $0.displayName) })
        List {
            if candidates.isEmpty { Text("Nothing awaiting review.").foregroundStyle(.secondary) }
            ForEach(candidates) { r in
                NavigationLink { RelationshipDetailView(relationshipID: r.id) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(names[r.fromID] ?? "?") — \(r.type.displayName) — \(names[r.toID] ?? "?")")
                        Text(r.provenance).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button("Approve") { try? SourceVerificationAgent(store: model.store).approve(r.id); refresh += 1; model.rebuildGraph(animateNewRelationships: [r.id]) }.tint(.green)
                    Button("Reject", role: .destructive) { try? SourceVerificationAgent(store: model.store).reject(r.id); refresh += 1; model.rebuildGraph() }
                }
            }
        }
        .id(refresh)
    }
}

/// Identity-merge review: nothing is merged without explicit approval; originals are preserved.
struct MergeReview: View {
    @Environment(AppModel.self) private var model
    @State private var refresh = 0

    var body: some View {
        let engine = MergeEngine(store: model.store)
        let proposals = (try? engine.proposals()) ?? []
        List {
            if proposals.isEmpty { Text("No possible duplicates. Run a duplicate scan from Jobs.").foregroundStyle(.secondary) }
            ForEach(proposals) { p in
                let people = (try? model.store.people([p.personA, p.personB])) ?? []
                if people.count == 2 {
                    Section("Possible duplicate · \(Int(p.score * 100))% match") {
                        ForEach(people) { person in
                            NavigationLink { PersonProfileView(personID: person.id) } label: {
                                VStack(alignment: .leading) {
                                    Text(person.displayName)
                                    Text([person.birth?.description, person.birthPlace, person.origin.rawValue].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        ForEach(p.reasons, id: \.self) { Label($0, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green) }
                        ForEach(p.conflicts, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                        HStack {
                            Button("Merge (keep first)") { try? engine.approve(p.id, survivor: people[0].id); refresh += 1; model.rebuildGraph() }
                                .buttonStyle(.borderedProminent)
                            Button("Not the same person") { try? engine.reject(p.id); refresh += 1 }.buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .id(refresh)
    }
}

struct ImportView: View {
    @Environment(AppModel.self) private var model
    @State private var importing: Kind?
    @State private var message: String?

    enum Kind: Identifiable { case gedcom, list; var id: Int { hashValue } }

    var body: some View {
        List {
            Section("Family tree") {
                Button("Import GEDCOM file (.ged)") { importing = .gedcom }
                Text("Exported from any genealogy program, FamilySearch or WikiTree. Possibly-living relatives are private and excluded from research by default. Duplicates are proposed for review, never merged automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Creators, friends & lists") {
                Button("Import CSV or JSON list") { importing = .list }
                Text("Columns: name, category, wikidata, youtube, notes, private. Rows with a Wikidata QID or YouTube channel become research jobs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message { Section { Text(message) } }
        }
        .fileImporter(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
                      allowedContentTypes: importing == .gedcom ? [UTType(filenameExtension: "ged") ?? .plainText, .plainText, .data]
                                                                : [.commaSeparatedText, .json, .plainText]) { result in
            let kind = importing
            importing = nil
            guard case .success(let url) = result else { return }
            handle(url, kind: kind)
        }
    }

    private func handle(_ url: URL, kind: Kind?) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            if kind == .gedcom {
                let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                let r = try GEDCOMImporter(store: model.store).importGEDCOM(text: text, fileName: url.lastPathComponent)
                let proposals = try MergeEngine(store: model.store).scanForDuplicates()
                message = "Imported \(r.peopleCreated) people, \(r.relationshipsCreated) relationships and \(r.eventsCreated) events. \(proposals.count) possible duplicates await review." +
                    (r.warnings.isEmpty ? "" : "\n\(r.warnings.count) warnings: \(r.warnings.prefix(3).joined(separator: "; "))")
            } else {
                let rows = url.pathExtension.lowercased() == "json" ? try ListImporter.parseJSON(data) : ListImporter.parseCSV(String(decoding: data, as: UTF8.self))
                let r = try ListImporter(store: model.store).importRows(rows, defaultCategory: .userImported, scheduler: model.scheduler, fileName: url.lastPathComponent)
                message = "Added \(r.created.count) people and queued \(r.jobs.count) research jobs."
                model.runQueue()
            }
            model.rebuildGraph()
        } catch {
            message = "Import failed: \(error)"
        }
    }
}

struct SourcesDashboard: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            Section {
                LabeledContent("Network requests this session", value: "\(model.http.requestCount)")
                LabeledContent("Mode", value: model.offlineMode ? "Offline (cache only)" : "Online")
            }
            ForEach(SourceRegistry.connectors(youtubeKeyConfigured: !model.youtubeAPIKey.isEmpty)) { c in
                Section(c.name) {
                    LabeledContent("Status", value: c.availability.rawValue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Can access: \(c.canAccess)").font(.caption)
                        Text("Cannot access: \(c.cannotAccess)").font(.caption).foregroundStyle(.secondary)
                        Text("Limits: \(c.rateLimit) · Licence: \(c.license)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}
