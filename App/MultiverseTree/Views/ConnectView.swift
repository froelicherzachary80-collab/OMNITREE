import SwiftUI
import MultiverseCore

/// Infinite Connection Pathfinder UI: pairwise report with the five path classes, kinship,
/// and multi-person shared networks.
struct ConnectView: View {
    @Environment(AppModel.self) private var model
    var initialA: EntityID? = nil
    var openUniverse: () -> Void

    @State private var a: Person?
    @State private var b: Person?
    @State private var extra: [Person] = []
    @State private var includeCandidates = false
    @State private var minConfidence = 0.0
    @State private var result: [ExplainedPath] = []
    @State private var summary: String?
    @State private var kinship: String?
    @State private var picking: Slot?

    enum Slot: Identifiable { case a, b, extra; var id: Int { hashValue } }

    var body: some View {
        List {
            Section("People") {
                pickerRow("From", a, .a)
                pickerRow("To", b, .b)
                ForEach(extra) { p in Text("+ \(p.displayName)") }
                Button("Add another person (multi-person network)") { picking = .extra }
            }
            Section("Evidence filters") {
                Toggle("Include unverified candidates", isOn: $includeCandidates)
                VStack(alignment: .leading) {
                    Text("Minimum edge confidence \(Int(minConfidence * 100))%").font(.caption)
                    Slider(value: $minConfidence, in: 0...0.95, step: 0.05)
                }
            }
            Section {
                Button("Find documented connections", action: run).disabled(a == nil || (b == nil && extra.isEmpty))
                if !result.isEmpty {
                    Button("Reveal in universe ✦") { model.startReveal(result); openUniverse() }
                }
            }
            if let summary { Section { Text(summary) } }
            if let kinship { Section("Genealogy") { Text(kinship) } }
            ForEach(result, id: \.self) { path in
                Section(path.title) { PathHopsView(path: path) }
            }
        }
        .navigationTitle("Connect")
        .sheet(item: $picking) { slot in
            PersonPicker { p in
                switch slot {
                case .a: a = p
                case .b: b = p
                case .extra: extra.append(p)
                }
                picking = nil
            }
        }
        .onAppear {
            if a == nil {
                if let id = initialA ?? model.selfPersonID { a = try? model.store.person(id) }
            }
        }
    }

    private func pickerRow(_ label: String, _ p: Person?, _ slot: Slot) -> some View {
        Button { picking = slot } label: {
            LabeledContent(label, value: p?.displayName ?? "Choose…")
        }
    }

    private func run() {
        guard let a, let graph = model.graph else { return }
        var filter = EdgeFilter.established
        if includeCandidates { filter.statuses.insert(.candidate) }
        filter.minConfidence = minConfidence
        let finder = PathFinder(graph: graph)
        let narrator = PathNarrator(store: model.store, graph: graph)
        result = []; kinship = nil
        let people = [a] + [b].compactMap { $0 } + extra
        if people.count > 2 {
            let r = finder.multiConnection(people.map(\.id), filter: filter)
            for pair in r.pairs {
                let names = (try? model.store.people([pair.a, pair.b]).map(\.displayName)) ?? []
                if let p = pair.path, let ex = try? narrator.explain(p, title: names.joined(separator: " ↔ ")) { result.append(ex) }
            }
            summary = "\(r.pairs.count - r.disconnectedPairs.count) of \(r.pairs.count) pairs are connected. Shared network: \(r.networkNodes.count) people, \(r.networkEdges.count) relationships."
            return
        }
        guard let b, let report = finder.connectionReport(from: a.id, to: b.id, baseFilter: filter, alternatives: 4) else { return }
        func add(_ p: GraphPath?, _ title: String) { if let p, let ex = try? narrator.explain(p, title: title) { result.append(ex) } }
        add(report.shortest, "1 · Shortest number of edges")
        add(report.strongest, "2 · Strongest documented path")
        add(report.familyOnly, "3 · Family-only path")
        add(report.collaborationOnly, "4 · Collaboration-only path")
        for (i, m) in report.mixed.enumerated() { add(m, "5 · Mixed relationship path \(i + 1)") }
        if report.isConnected {
            summary = "Documented connection found. \(report.familyOnly == nil ? "No family-only path." : "") \(report.collaborationOnly == nil ? "No collaboration-only path." : "")"
        } else if let possible = report.possibleViaCandidates {
            add(possible, "Possible connection — research required")
            summary = "No documented connection exists. A possible path relies on unverified candidates — review them in Research → Approvals."
        } else {
            summary = "No documented connection exists between \(a.displayName) and \(b.displayName). Nothing has been invented to fill the gap."
        }
        if let ia = graph.index(of: a.id), let ib = graph.index(of: b.id), let rel = KinshipCalculator.relation(ia, ib, in: graph, filter: filter) {
            let anc = (try? model.store.person(graph.id(of: rel.via.ancestor))?.displayName) ?? "?"
            kinship = "Established genealogical path: \(a.displayName) is \(b.displayName)'s \(rel.term) (common ancestor: \(anc))."
        } else {
            kinship = "No documented shared ancestor. Kinship is not claimed."
        }
    }
}

struct PathHopsView: View {
    let path: ExplainedPath
    var body: some View {
        ForEach(Array(path.hops.enumerated()), id: \.offset) { _, hop in
            NavigationLink { RelationshipDetailView(relationshipID: hop.relationshipID) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(hop.fromName) → \(hop.toName)").font(.callout.weight(.medium))
                    Text(hop.label + (hop.context.map { " · \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary)
                    HStack { VerificationBadge(status: hop.verification); Text("\(hop.sourceURLs.count) source(s)").font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
        Text("Path strength \(String(format: "%.3f", path.strength))").font(.caption2).foregroundStyle(.tertiary)
    }
}

struct PersonPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onPick: (Person) -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List((try? model.store.searchPeople(query, limit: 100)) ?? []) { p in
                Button { onPick(p) } label: { PersonRow(person: p) }
            }
            .searchable(text: $query)
            .navigationTitle("Choose person")
            .toolbar { Button("Cancel") { dismiss() } }
        }
    }
}

struct EvidencePanel: View {
    let paths: [ExplainedPath]
    var body: some View {
        NavigationStack {
            List {
                if paths.isEmpty { Text("No path selected.") }
                ForEach(paths, id: \.self) { p in
                    Section(p.title) {
                        ForEach(Array(p.hops.enumerated()), id: \.offset) { _, h in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text("\(h.fromName) → \(h.toName)").bold(); Spacer(); VerificationBadge(status: h.verification) }
                                Text(h.label + (h.context.map { " · \($0)" } ?? "")).font(.caption)
                                ForEach(h.evidence, id: \.self) { Text("• \($0)").font(.caption2).foregroundStyle(.secondary) }
                                ForEach(h.sourceURLs, id: \.self) { s in
                                    if let u = URL(string: s), u.scheme?.hasPrefix("http") == true { Link(s, destination: u).font(.caption2) }
                                    else { Text(s).font(.caption2.monospaced()).foregroundStyle(.tertiary) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Evidence")
        }
    }
}

/// Ancestors by generation and descendants, from documented descent edges only.
struct FamilyTreeView: View {
    @Environment(AppModel.self) private var model
    let personID: EntityID
    @State private var exported: URL?

    var body: some View {
        List {
            if let g = model.graph, let i = g.index(of: personID) {
                let anc = KinshipCalculator.ancestors(of: i, in: g).filter { $0.value.generation > 0 }
                let byGen = Dictionary(grouping: anc, by: { $0.value.generation }).sorted { $0.key < $1.key }
                ForEach(byGen, id: \.key) { gen, entries in
                    Section(gen == 1 ? "Parents" : gen == 2 ? "Grandparents" : "Generation −\(gen)") {
                        ForEach(entries, id: \.key) { e in
                            let adoptive = e.value.path.edges.contains { g.edges[Int($0)].type == .adoptiveParent }
                            NavigationLink { PersonProfileView(personID: g.id(of: e.key)) } label: {
                                HStack { Text(name(g.id(of: e.key))); if adoptive { Text("adoptive branch").font(.caption2).foregroundStyle(.orange) } }
                            }
                        }
                    }
                }
                let kids = g.children(of: i)
                if !kids.isEmpty {
                    Section("Children") {
                        ForEach(kids, id: \.self) { k in NavigationLink(name(g.id(of: k))) { PersonProfileView(personID: g.id(of: k)) } }
                    }
                }
                Section {
                    Button("Export this branch as GEDCOM") { export(g, i) }
                    if let exported { ShareLink(item: exported) }
                }
            } else {
                Text("Loading graph…")
            }
        }
        .navigationTitle("Family tree")
    }

    private func name(_ id: EntityID) -> String { (try? model.store.person(id)?.displayName) ?? "?" }

    private func export(_ g: GraphIndex, _ i: Int32) {
        var ids = KinshipCalculator.ancestors(of: i, in: g).keys.map(g.id(of:))
        ids += g.children(of: i).map(g.id(of:))
        guard let text = try? GEDCOMExporter(store: model.store).export(personIDs: ids, includePrivate: true) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("family-branch.ged")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        exported = url
    }
}
