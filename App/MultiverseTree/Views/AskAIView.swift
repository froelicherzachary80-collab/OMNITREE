import SwiftUI
import MultiverseCore

/// "Ask Multiverse AI": every answer shows the tool calls that produced it, the sources inspected,
/// discoveries, rejected/uncertain claims and graph changes.
struct AskAIView: View {
    @Environment(AppModel.self) private var model
    var openUniverse: () -> Void
    @State private var input = ""
    @State private var messages: [Message] = []
    @State private var busy = false

    struct Message: Identifiable {
        let id = UUID()
        let isUser: Bool
        let text: String
        var response: AssistantResponse?
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if messages.isEmpty { intro }
                        ForEach(messages) { m in bubble(m).id(m.id) }
                        if busy { ProgressView("Researching…").padding() }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _, _ in withAnimation { proxy.scrollTo(messages.last?.id) } }
            }
            if !model.activity.isEmpty && busy {
                Text(model.activity.first ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1).padding(.horizontal)
            }
            HStack {
                TextField("Ask about connections…", text: $input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
            .padding()
        }
        .navigationTitle("Ask Multiverse AI")
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Multiverse Intelligence Engine").font(.headline)
            Text("Answers come from real graph and research functions, with evidence for every claim. \(model.intelligence.model.map { "Language backend: \($0.name) (phrasing only, never facts)." } ?? "No language model configured — rule-based understanding only.")")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(["How am I connected to McKenna Grace?", "Find my shortest connection to a Minecraft YouTuber",
                     "How are all my friends connected?", "Research the members of Hermitcraft",
                     "Filmography of McKenna Grace"], id: \.self) { s in
                Button(s) { input = s; send() }.font(.caption).buttonStyle(.bordered)
            }
        }
    }

    private func bubble(_ m: Message) -> some View {
        VStack(alignment: m.isUser ? .trailing : .leading, spacing: 6) {
            Text(m.text)
                .padding(10)
                .background(m.isUser ? Color.cyan.opacity(0.25) : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, alignment: m.isUser ? .trailing : .leading)
            if let r = m.response {
                if !r.disambiguation.isEmpty {
                    ForEach(r.disambiguation) { p in
                        NavigationLink { PersonProfileView(personID: p.id) } label: { PersonRow(person: p) }
                    }
                }
                if !r.paths.isEmpty {
                    Button("Reveal \(r.paths.count) path\(r.paths.count == 1 ? "" : "s") in the universe ✦") {
                        model.startReveal(r.paths); openUniverse()
                    }
                    .buttonStyle(.borderedProminent)
                }
                DisclosureGroup("Research trace (\(r.steps.count) tool calls)") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(r.steps, id: \.self) { s in
                            Text("[\(s.tool)] \(s.input) → \(s.output)").font(.caption2.monospaced())
                        }
                        if let rep = r.report {
                            Text("Sources inspected (\(rep.sourcesInspected.count))").font(.caption.bold()).padding(.top, 4)
                            ForEach(rep.sourcesInspected.prefix(20), id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
                            if !rep.rejectedClaims.isEmpty || !rep.uncertainClaims.isEmpty {
                                Text("Rejected / uncertain").font(.caption.bold()).padding(.top, 4)
                                ForEach(rep.rejectedClaims + rep.uncertainClaims, id: \.self) { Text($0).font(.caption2).foregroundStyle(.orange) }
                            }
                            Text("Graph changes: +\(rep.peopleAdded.count) people, \(rep.discoveries.count) relationships").font(.caption2).padding(.top, 4)
                            ForEach(rep.unansweredQuestions, id: \.self) { Text("Unanswered: \($0)").font(.caption2).foregroundStyle(.secondary) }
                        }
                        if let used = r.modelUsed { Text("Language backend used: \(used)").font(.caption2).foregroundStyle(.tertiary) }
                    }
                }
                .font(.caption)
            }
        }
    }

    private func send() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        input = ""
        messages.append(Message(isUser: true, text: q))
        busy = true
        Task {
            let r = await model.ask(q)
            messages.append(Message(isUser: false, text: r.text, response: r))
            busy = false
        }
    }
}
