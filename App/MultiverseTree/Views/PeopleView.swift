import SwiftUI
import MultiverseCore

struct PeopleView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var category: PersonCategory?
    @State private var showAdd = false

    var results: [Person] {
        var r = (try? model.store.searchPeople(query, limit: 300)) ?? []
        if let category { r = r.filter { $0.categories.contains(category) } }
        return r
    }

    var body: some View {
        List {
            Picker("Category", selection: $category) {
                Text("All people").tag(PersonCategory?.none)
                ForEach(PersonCategory.allCases, id: \.self) { Text($0.displayName).tag(PersonCategory?.some($0)) }
            }
            ForEach(results) { p in
                NavigationLink { PersonProfileView(personID: p.id) } label: { PersonRow(person: p) }
            }
        }
        .searchable(text: $query, prompt: "Search people & aliases")
        .navigationTitle("People")
        .toolbar { Button { showAdd = true } label: { Image(systemName: "person.badge.plus") } }
        .sheet(isPresented: $showAdd) { AddPersonView() }
        .id(model.personCount)
    }
}

struct PersonRow: View {
    let person: Person
    var body: some View {
        HStack {
            Circle().fill(Color(red: Double(CosmicPalette.nodeColor(for: person.categories).x),
                                green: Double(CosmicPalette.nodeColor(for: person.categories).y),
                                blue: Double(CosmicPalette.nodeColor(for: person.categories).z)))
                .frame(width: 10, height: 10).shadow(color: .cyan, radius: 4)
            VStack(alignment: .leading) {
                HStack(spacing: 4) {
                    Text(person.displayName)
                    if person.isPrivate { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(person.categories.map(\.displayName).sorted().joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if person.isSample { SampleBadge() }
        }
    }
}

/// Manually add a family member or friend. Private and excluded from research by default.
struct AddPersonView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var category: PersonCategory = .familyMember
    @State private var birthYear = ""
    @State private var notes = ""
    @State private var isPrivate = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Full name", text: $name)
                Picker("Category", selection: $category) {
                    ForEach(PersonCategory.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .onChange(of: category) { _, c in isPrivate = c.isPrivateByDefault }
                TextField("Birth year (optional)", text: $birthYear).keyboardType(.numberPad)
                Section("Private notes (encrypted on device)") { TextEditor(text: $notes).frame(minHeight: 80) }
                Toggle("Private profile", isOn: $isPrivate)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Add person")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let p = Person(displayName: name, categories: [category], birth: Int(birthYear).map { HistoricalDate(year: $0) },
                                       isPrivate: isPrivate, excludeFromResearch: isPrivate, origin: .user)
                        do {
                            try model.store.upsert(p, privateData: notes.isEmpty ? nil : PrivatePersonData(notes: notes))
                            model.rebuildGraph()
                            dismiss()
                        } catch { self.error = "\(error)" }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
