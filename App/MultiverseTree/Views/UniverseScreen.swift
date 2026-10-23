import SwiftUI
import MultiverseCore

struct UniverseScreen: View {
    @Environment(AppModel.self) private var model
    var openTab: (Int) -> Void
    @State private var showFilters = false
    @State private var profileID: EntityID?

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .top) {
            UniverseMetalView(model: model) { id in
                model.selectedPersonID = id
            }
            .ignoresSafeArea()

            VStack(spacing: 8) {
                modeChips
                if model.isRebuilding { ProgressView("Growing branches…").font(.caption).cosmicCard() }
                if model.personCount == 0 && !model.isRebuilding { emptyState }
                Spacer()
                if model.isRevealing { revealControls }
                if let id = model.selectedPersonID, let person = try? model.store.person(id) {
                    selectionCard(person)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showFilters) { FilterSheet().presentationDetents([.medium, .large]) }
        .sheet(isPresented: $model.showEvidencePanel) {
            EvidencePanel(paths: model.revealPaths).presentationDetents([.medium, .large])
        }
        .sheet(item: Binding(get: { profileID.map(IdentifiedID.init) }, set: { profileID = $0?.id })) { item in
            NavigationStack { PersonProfileView(personID: item.id) }
        }
    }

    private var modeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(UniverseMode.allCases, id: \.self) { mode in
                    let on = model.filter.modes.contains(mode)
                    Button {
                        var f = model.filter
                        if mode == .entireMultiverse { f.modes = [.entireMultiverse] }
                        else {
                            f.modes.remove(.entireMultiverse)
                            if on { f.modes.remove(mode) } else { f.modes.insert(mode) }
                            if f.modes.isEmpty { f.modes = [.entireMultiverse] }
                        }
                        model.filter = f
                    } label: {
                        Text(mode.displayName.replacingOccurrences(of: " Universe", with: ""))
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(on ? Color.cyan.opacity(0.35) : Color.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button { showFilters = true } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle").padding(6)
                }
            }
            .padding(.top, 4)
        }
        .foregroundStyle(.white)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your multiverse is empty").font(.headline)
            Text("Import a GEDCOM family tree, research a public figure, or explore the clearly-labelled fictional sample universe.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button("Load sample universe") { model.loadSampleData() }.buttonStyle(.borderedProminent)
                Button("Import / Research") { openTab(4) }.buttonStyle(.bordered)
            }
        }
        .cosmicCard()
    }

    private var revealControls: some View {
        VStack(spacing: 8) {
            Text(model.revealPhase).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 20) {
                Button { model.replayReveal() } label: { Image(systemName: "backward.end.fill") }
                Button { model.toggleRevealPause() } label: { Image(systemName: model.revealPlaying ? "pause.fill" : "play.fill") }
                Button { model.showEvidencePanel = true } label: { Image(systemName: "doc.text.magnifyingglass") }
                Button { model.endReveal() } label: { Image(systemName: "xmark") }
            }
            .font(.title3)
        }
        .cosmicCard()
    }

    private func selectionCard(_ person: Person) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(person.displayName).font(.headline)
                if person.isSample { SampleBadge() }
                if person.isPrivate { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button { model.selectedPersonID = nil } label: { Image(systemName: "xmark.circle.fill") }.foregroundStyle(.secondary)
            }
            Text(person.categories.map(\.displayName).sorted().joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            let rels = (try? model.store.relationships(of: person.id, includeUnestablished: false).count) ?? 0
            Text("\(rels) documented connections").font(.caption2).foregroundStyle(.cyan)
            HStack {
                Button("Profile") { profileID = person.id }.buttonStyle(.borderedProminent)
                Button("Find connection") { openTab(2) }.buttonStyle(.bordered)
            }
            .font(.caption)
        }
        .cosmicCard()
    }
}

struct IdentifiedID: Identifiable { let id: EntityID }

struct FilterSheet: View {
    @Environment(AppModel.self) private var model
    @State private var minYear = 1500.0
    @State private var maxYear = 2030.0
    @State private var useYears = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("Relationship types") {
                    ForEach(RelationshipCategory.allCases, id: \.self) { cat in
                        Toggle(cat.displayName, isOn: Binding(
                            get: { model.filter.relationshipCategories?.contains(cat) ?? true },
                            set: { on in
                                var set = model.filter.relationshipCategories ?? Set(RelationshipCategory.allCases)
                                if on { set.insert(cat) } else { set.remove(cat) }
                                model.filter.relationshipCategories = set.count == RelationshipCategory.allCases.count ? nil : set
                            }))
                    }
                }
                Section("Verification") {
                    ForEach([VerificationStatus.verified, .sourced, .userAsserted, .candidate], id: \.self) { s in
                        Toggle(s.displayName, isOn: Binding(
                            get: { model.filter.statuses.contains(s) },
                            set: { on in if on { model.filter.statuses.insert(s) } else { model.filter.statuses.remove(s) } }))
                    }
                    VStack(alignment: .leading) {
                        Text("Minimum source quality: \(Int(model.filter.minSourceReliability * 100))%")
                        Slider(value: $model.filter.minSourceReliability, in: 0...0.9, step: 0.05)
                    }
                }
                Section("Person category") {
                    Picker("Show", selection: Binding(
                        get: { model.filter.personCategories?.first },
                        set: { model.filter.personCategories = $0.map { [$0] } })) {
                        Text("All").tag(PersonCategory?.none)
                        ForEach(PersonCategory.allCases, id: \.self) { Text($0.displayName).tag(PersonCategory?.some($0)) }
                    }
                }
                Section("Date") {
                    Toggle("Limit to years", isOn: $useYears)
                    if useYears {
                        Stepper("From \(Int(minYear))", value: $minYear, in: -3000...2030, step: 10)
                        Stepper("To \(Int(maxYear))", value: $maxYear, in: -3000...2030, step: 10)
                    }
                }
                Section("Place & community") {
                    TextField("Country contains…", text: Binding(get: { model.filter.country ?? "" },
                                                                 set: { model.filter.country = $0.isEmpty ? nil : $0 }))
                    Picker("Community", selection: $model.filter.community) {
                        Text("Any").tag(EntityID?.none)
                        ForEach((try? model.store.allCommunities()) ?? [], id: \.id) { Text($0.name).tag(EntityID?.some($0.id)) }
                    }
                }
                Section("Graph distance") {
                    Picker("Within", selection: $model.filter.maxDistance) {
                        Text("Unlimited").tag(Int?.none)
                        ForEach(1...6, id: \.self) { Text("\($0) hops of selection").tag(Int?.some($0)) }
                    }
                    .onChange(of: model.filter.maxDistance) { _, _ in model.filter.focus = model.selectedPersonID ?? model.selfPersonID }
                }
                Section { Toggle("Show sample data", isOn: $model.filter.showSampleData) }
            }
            .navigationTitle("Filters")
            .onChange(of: useYears) { _, _ in applyYears() }
            .onChange(of: minYear) { _, _ in applyYears() }
            .onChange(of: maxYear) { _, _ in applyYears() }
        }
    }

    private func applyYears() {
        model.filter.yearRange = useYears && minYear <= maxYear ? Int(minYear)...Int(maxYear) : nil
    }
}
