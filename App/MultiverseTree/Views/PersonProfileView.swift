import SwiftUI
import MultiverseCore

/// Detailed, record-backed profile. Every value shown comes from stored rows.
struct PersonProfileView: View {
    @Environment(AppModel.self) private var model
    let personID: EntityID
    @State private var refresh = 0
    @State private var showAddRelationship = false
    @State private var compareWith: Person?
    @State private var researchNote: String?

    var body: some View {
        let store = model.store
        if let p = try? store.person(personID) {
            let rels = (try? store.relationships(of: p.id)) ?? []
            let others = Dictionary(uniqueKeysWithValues: ((try? store.people(Array(Set(rels.map { $0.other(than: p.id) })))) ?? []).map { ($0.id, $0) })
            List {
                header(p)
                actions(p)
                if let bio = p.biography { Section("Biography") { Text(bio).font(.callout) } }
                Section("Facts") {
                    if !p.aliases.isEmpty { LabeledContent("Also known as", value: p.aliases.joined(separator: ", ")) }
                    if let b = p.birth { LabeledContent("Born", value: [b.description, p.birthPlace].compactMap { $0 }.joined(separator: " · ")) }
                    if let d = p.death { LabeledContent("Died", value: [d.description, p.deathPlace].compactMap { $0 }.joined(separator: " · ")) }
                    if let o = p.occupation { LabeledContent("Occupation", value: o) }
                    if let c = p.country { LabeledContent("Country", value: c) }
                    LabeledContent("Record origin", value: p.origin.rawValue)
                    if p.isLiving != false && !p.isSample && p.origin != .wikidata && p.origin != .youtube {
                        Text("User-provided information about a possibly living person — kept private on this device.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                let ids = (try? store.identities(of: p.id)) ?? []
                if !ids.isEmpty {
                    Section("Identities") {
                        ForEach(ids, id: \.id) { i in
                            if let u = i.url.flatMap(URL.init(string:)) { Link("\(i.scheme.rawValue): \(i.value)", destination: u) }
                            else { LabeledContent(i.scheme.rawValue, value: i.value) }
                        }
                    }
                }
                let accounts = (try? store.platformAccounts(of: p.id)) ?? []
                if !accounts.isEmpty {
                    Section("Platforms") {
                        ForEach(accounts, id: \.id) { a in
                            LabeledContent(a.platform.capitalized, value: [a.handle ?? a.title, a.subscriberCount.map { "\($0.formatted()) subscribers" }].compactMap { $0 }.joined(separator: " · "))
                        }
                    }
                }
                let comms = (try? store.communities(of: p.id)) ?? []
                if !comms.isEmpty { Section("Communities") { ForEach(comms, id: \.id) { Text($0.name) } } }
                let projects = (try? store.projects(of: p.id)) ?? []
                if !projects.isEmpty {
                    Section("Filmography & projects") {
                        ForEach(projects, id: \.0.id) { proj, role in
                            HStack { Text(proj.title); Spacer(); Text([proj.year.map(String.init), role].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary).font(.caption) }
                        }
                    }
                }
                ForEach(RelationshipCategory.allCases, id: \.self) { cat in
                    let group = rels.filter { $0.category == cat }
                    if !group.isEmpty {
                        Section(cat == .family ? "Known relatives" : "\(cat.displayName) connections") {
                            ForEach(group) { r in
                                NavigationLink { RelationshipDetailView(relationshipID: r.id) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack { Text(others[r.other(than: p.id)]?.displayName ?? "?"); Spacer(); VerificationBadge(status: r.verification) }
                                        Text(r.label(from: p.id) + (r.contextLabel.map { " · \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                let events = (try? store.events(of: p.id)) ?? []
                if !events.isEmpty {
                    Section("Timeline") {
                        ForEach(events, id: \.id) { e in
                            LabeledContent(e.type.rawValue.capitalized, value: [e.date?.description, e.place].compactMap { $0 }.joined(separator: " · "))
                        }
                    }
                }
                Section("Verified sources") {
                    ForEach((try? store.sources(forPerson: p.id)) ?? [], id: \.id) { s in SourceRow(source: s) }
                }
                privacy(p)
            }
            .navigationTitle(p.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .id(refresh)
            .sheet(isPresented: $showAddRelationship) { AddRelationshipView(fromID: p.id) { refresh += 1 } }
        } else {
            ContentUnavailableView("Person not found", systemImage: "person.slash")
        }
    }

    private func header(_ p: Person) -> some View {
        Section {
            HStack(spacing: 14) {
                if let s = p.imageURL, let url = URL(string: s) {
                    AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.05) }
                        .frame(width: 72, height: 72).clipShape(Circle())
                        .overlay(Circle().stroke(Color.cyan.opacity(0.6), lineWidth: 1)).shadow(color: .cyan.opacity(0.6), radius: 8)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.displayName).font(.title3.bold())
                    Text(p.categories.map(\.displayName).sorted().joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if p.isSample { SampleBadge() }
                        if p.id == model.selfPersonID { Text("YOU").font(.caption2.bold()).foregroundStyle(.cyan) }
                    }
                    if let lic = p.imageLicense { Text("Image: \(lic)").font(.caption2).foregroundStyle(.tertiary) }
                }
            }
        }
    }

    private func actions(_ p: Person) -> some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    Button("Explore Branches") { model.selectedPersonID = p.id }
                    NavigationLink("Find Connection") { ConnectView(initialA: p.id, openUniverse: {}) }
                    Button("Research Person") { research(p) }.disabled(p.excludeFromResearch)
                    NavigationLink("Open Family Tree") { FamilyTreeView(personID: p.id) }
                    NavigationLink("Compare People") { ConnectView(initialA: p.id, openUniverse: {}) }
                    Button("Follow Branch") { showAddRelationship = true }
                    if p.id != model.selfPersonID { Button("This is me") { model.setSelf(p.id) } }
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }
            if let researchNote { Text(researchNote).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func research(_ p: Person) {
        let ids = (try? model.store.identities(of: p.id)) ?? []
        if let qid = ids.first(where: { $0.scheme == .wikidata })?.value {
            model.enqueue(ResearchJob(kind: .wikidataEntity, target: qid, personID: p.id, priority: 5))
            if p.categories.contains(.actor) || p.categories.contains(.director) {
                model.enqueue(ResearchJob(kind: .wikidataFilmography, target: p.id, personID: p.id, priority: 4))
            }
            researchNote = "Queued Wikidata research. Discovered branches will grow into the universe."
        } else if let yt = ids.first(where: { $0.scheme == .youtubeChannel })?.value {
            model.enqueue(ResearchJob(kind: .youtubeChannel, target: yt, personID: p.id, priority: 5))
            researchNote = "Queued YouTube research."
        } else {
            model.enqueue(ResearchJob(kind: .wikidataSearch, target: p.displayName, priority: 5))
            researchNote = "No external ID yet — searching Wikidata by name. A match is imported as a separate record and proposed for merge review; nothing is merged automatically."
        }
    }

    private func privacy(_ p: Person) -> some View {
        Section("Privacy") {
            Toggle("Private profile", isOn: Binding(get: { p.isPrivate }, set: { try? model.store.setPrivacy(p.id, isPrivate: $0); refresh += 1 }))
            Toggle("Exclude from AI research", isOn: Binding(get: { p.excludeFromResearch }, set: { try? model.store.setPrivacy(p.id, excludeFromResearch: $0); refresh += 1 }))
            if let notes = try? model.store.privateData(for: p.id)?.notes { LabeledContent("Private notes", value: notes) }
            Button("Delete profile", role: .destructive) { model.deletePerson(p.id) }
        }
    }
}

struct SourceRow: View {
    let source: Source
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let u = source.url.flatMap(URL.init(string:)) { Link(source.title, destination: u).font(.callout) }
            else { Text(source.title).font(.callout) }
            Text([source.publisher, source.license, "reliability \(Int(source.reliability * 100))%",
                  "retrieved \(source.retrievedAt.formatted(date: .abbreviated, time: .omitted))"].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary)
            if let ref = source.documentRef, source.url == nil { Text(ref).font(.caption2.monospaced()).foregroundStyle(.tertiary) }
        }
    }
}

struct RelationshipDetailView: View {
    @Environment(AppModel.self) private var model
    let relationshipID: EntityID
    @State private var refresh = 0

    var body: some View {
        if let r = try? model.store.relationship(relationshipID) {
            let names = Dictionary(uniqueKeysWithValues: ((try? model.store.people([r.fromID, r.toID])) ?? []).map { ($0.id, $0.displayName) })
            List {
                Section {
                    Text("\(names[r.fromID] ?? "?") — \(r.type.forwardLabel) — \(names[r.toID] ?? "?")").font(.headline)
                    HStack { VerificationBadge(status: r.verification); Text("confidence \(Int(r.confidence * 100))%").font(.caption) }
                    LabeledContent("Category", value: r.category.displayName)
                    LabeledContent("Kind", value: r.isInferred ? "Inferred connection" : "Direct relationship")
                    if let c = r.contextLabel { LabeledContent("Context", value: c) }
                    if let s = r.startDate { LabeledContent("From", value: s.description) }
                    if let e = r.endDate { LabeledContent("Until", value: e.description) }
                    LabeledContent("Last checked", value: r.lastChecked.formatted())
                    LabeledContent("Provenance", value: r.provenance)
                }
                Section("Evidence") {
                    ForEach((try? model.store.evidence(for: r.id)) ?? [], id: \.0.id) { e, s in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(e.description)
                            if let q = e.quote { Text("“\(q)”").italic().font(.caption) }
                            SourceRow(source: s)
                            Text("Extracted by \(e.extractedBy)").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                Section("Review") {
                    if r.verification != .verified {
                        Button("Approve as verified") { try? SourceVerificationAgent(store: model.store).approve(r.id); refresh += 1; model.rebuildGraph() }
                    }
                    if r.verification != .rejected {
                        Button("Reject", role: .destructive) { try? SourceVerificationAgent(store: model.store).reject(r.id); refresh += 1; model.rebuildGraph() }
                    }
                }
            }
            .id(refresh)
            .navigationTitle(r.type.displayName)
        }
    }
}

/// User-asserted relationship between two existing people, with a required evidence note.
struct AddRelationshipView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let fromID: EntityID
    var onSave: () -> Void
    @State private var query = ""
    @State private var other: Person?
    @State private var type: RelationshipType = .publicFriendship
    @State private var evidence = ""
    @State private var url = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Connect to") {
                    TextField("Search", text: $query)
                    ForEach(((try? model.store.searchPeople(query, limit: 8)) ?? []).filter { $0.id != fromID }) { p in
                        Button { other = p } label: { HStack { Text(p.displayName); if other?.id == p.id { Image(systemName: "checkmark") } } }
                    }
                }
                Picker("Relationship", selection: $type) {
                    ForEach(RelationshipType.allCases, id: \.self) { Text("\($0.category.displayName): \($0.displayName)").tag($0) }
                }
                Section("Evidence (required)") {
                    TextField("What documents this?", text: $evidence, axis: .vertical)
                    TextField("Source URL (optional)", text: $url).keyboardType(.URL).textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("Follow a branch")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let other else { return }
                        let src = try? model.store.addSource(Source(kind: url.isEmpty ? .userEntry : .webPage, title: url.isEmpty ? "Entered by you" : url,
                                                                    url: url.isEmpty ? nil : url, documentRef: url.isEmpty ? "user:\(IDGen.make())" : nil,
                                                                    reliability: Source.defaultReliability(.userEntry)))
                        if let src {
                            _ = try? model.store.addRelationship(Relationship(fromID: fromID, toID: other.id, type: type, verification: .userAsserted,
                                                                              confidence: 0.7, provenance: "Manual entry"),
                                                                 evidence: [EvidenceInput(sourceID: src.id, description: evidence, extractedBy: "user")])
                        }
                        model.rebuildGraph()
                        onSave()
                        dismiss()
                    }
                    .disabled(other == nil || evidence.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
