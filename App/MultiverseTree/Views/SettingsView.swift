import SwiftUI
import UniformTypeIdentifiers
import MultiverseCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var exportURL: URL?
    @State private var backupURL: URL?
    @State private var restoring = false
    @State private var message: String?
    @State private var modelStatus = "Checking…"
    @State private var includePrivateInExport = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Rendering") {
                Picker("Quality", selection: $model.quality) {
                    ForEach(RenderQuality.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Adjust automatically (frame rate, graph size, thermal state)", isOn: $model.autoQuality)
                LabeledContent("Current", value: model.effectiveQuality.displayName)
                LabeledContent("Graph", value: "\(model.personCount) people · \(model.relationshipCount) relationships")
            }
            Section("Research") {
                Toggle("Offline mode (use cached sources only)", isOn: $model.offlineMode)
                SecureField("YouTube Data API key (free)", text: $model.youtubeAPIKey)
                Text("Create a free key at console.cloud.google.com → YouTube Data API v3. Stored in the Keychain on this device only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Multiverse Intelligence") {
                Toggle("Use Apple on-device model when available", isOn: $model.useOnDeviceModel)
                TextField("Companion Ollama URL (e.g. http://192.168.1.20:11434)", text: $model.ollamaURL)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                TextField("Ollama model", text: $model.ollamaModel).textInputAutocapitalization(.never)
                LabeledContent("Backend", value: modelStatus)
                Text("Language models only map unusual phrasings to graph tools and rephrase grounded results. Facts always come from stored evidence.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Your data") {
                Toggle("Include private notes in export", isOn: $includePrivateInExport)
                Button("Export my data (JSON)") { exportJSON() }
                if let exportURL { ShareLink("Share export", item: exportURL) }
                Button("Export family tree (GEDCOM)") { exportGEDCOM() }
                Button("Back up database") { backup() }
                if let backupURL { ShareLink("Share backup", item: backupURL) }
                Button("Restore from backup…") { restoring = true }
                Button("Clear research cache") { try? model.store.clearCache(); message = "Cache cleared." }
                LabeledContent("Storage used", value: ByteCountFormatter.string(fromByteCount: Int64((try? model.store.storageBytes()) ?? 0), countStyle: .file))
            }
            Section("Sample data") {
                Button("Load fictional sample universe") { model.loadSampleData() }
                Button("Remove sample data", role: .destructive) { model.removeSampleData() }
            }
            if let message { Section { Text(message) } }
            Section("About") {
                Text("Multiverse Tree 0.1 · No subscriptions, no paid APIs. Private family and friends data stays encrypted on this device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .task(id: model.ollamaURL + String(model.useOnDeviceModel)) {
            if let m = model.intelligence.model {
                modelStatus = await m.isAvailable() ? "\(m.name) · ready" : "\(m.name) · unavailable (rule-based only)"
            } else { modelStatus = "Rule-based only" }
        }
        .fileImporter(isPresented: $restoring, allowedContentTypes: [.data]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                try model.store.db.restore(from: url.path)
                message = "Restored. Note: private notes encrypted on another device cannot be decrypted here."
                model.rebuildGraph()
            } catch { message = "Restore failed: \(error)" }
        }
    }

    private func tempURL(_ name: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(name) }

    private func exportJSON() {
        do {
            let data = try DataExporter(store: model.store).exportJSON(includePrivateData: includePrivateInExport)
            let url = tempURL("multiverse-export.json")
            try data.write(to: url, options: .completeFileProtection)
            exportURL = url
        } catch { message = "Export failed: \(error)" }
    }

    private func exportGEDCOM() {
        do {
            let text = try GEDCOMExporter(store: model.store).export(includePrivate: includePrivateInExport)
            let url = tempURL("multiverse-family.ged")
            try text.write(to: url, atomically: true, encoding: .utf8)
            exportURL = url
        } catch { message = "Export failed: \(error)" }
    }

    private func backup() {
        do {
            let url = tempURL("multiverse-backup-\(Int(Date().timeIntervalSince1970)).sqlite")
            try model.store.backup(to: url.path)
            backupURL = url
        } catch { message = "Backup failed: \(error)" }
    }
}
