import Foundation

/// Import of user-provided creator lists, friend lists and channel IDs (CSV or JSON).
///
/// CSV header (any order, case-insensitive): `name,category,wikidata,youtube,notes,private`.
/// JSON: an array of objects with the same keys. Rows with a Wikidata QID or YouTube channel
/// become research jobs; names alone never get matched to existing people.
public struct ListImporter {
    public let store: GraphStore
    public init(store: GraphStore) { self.store = store }

    public struct Row: Sendable, Equatable {
        public var name: String
        public var category: PersonCategory?
        public var wikidata: String?
        public var youtube: String?
        public var notes: String?
        public var isPrivate: Bool?
    }

    public struct Result: Sendable {
        public var created: [EntityID] = []
        public var jobs: [ResearchJob] = []
        public var skipped: [String] = []
    }

    public static func parseCSV(_ text: String) -> [Row] {
        var lines = csvRecords(text)
        guard !lines.isEmpty else { return [] }
        let header = lines.removeFirst().map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        func col(_ names: [String]) -> Int? { header.firstIndex { names.contains($0) } }
        let iName = col(["name", "display_name"]), iCat = col(["category", "type"]), iWD = col(["wikidata", "qid", "wikidata_qid"])
        let iYT = col(["youtube", "channel", "channel_id", "youtube_channel"]), iNotes = col(["notes", "note"]), iPriv = col(["private"])
        return lines.compactMap { f in
            func v(_ i: Int?) -> String? { i.flatMap { $0 < f.count ? f[$0].trimmingCharacters(in: .whitespaces) : nil }.flatMap { $0.isEmpty ? nil : $0 } }
            let name = v(iName) ?? v(iYT) ?? v(iWD)
            guard let name else { return nil }
            return Row(name: name, category: v(iCat).flatMap(Self.category), wikidata: v(iWD), youtube: v(iYT), notes: v(iNotes),
                       isPrivate: v(iPriv).map { ["1", "true", "yes", "y"].contains($0.lowercased()) })
        }
    }

    public static func parseJSON(_ data: Data) throws -> [Row] {
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { o in
            guard let name = (o["name"] as? String) ?? (o["youtube"] as? String) ?? (o["wikidata"] as? String) else { return nil }
            return Row(name: name, category: (o["category"] as? String).flatMap(category), wikidata: o["wikidata"] as? String,
                       youtube: o["youtube"] as? String, notes: o["notes"] as? String, isPrivate: o["private"] as? Bool)
        }
    }

    static func category(_ s: String) -> PersonCategory? {
        PersonCategory(rawValue: s) ?? PersonCategory.allCases.first { $0.displayName.lowercased() == s.lowercased() } ?? IntentParser.category(in: s)
    }

    /// RFC-4180-ish CSV splitter (quoted fields, escaped quotes, CRLF).
    static func csvRecords(_ text: String) -> [[String]] {
        var records: [[String]] = [], field = "", record: [String] = [], inQuotes = false
        var it = Array(text).makeIterator()
        var pending: Character? = nil
        while let c = pending ?? it.next() {
            pending = nil
            if inQuotes {
                if c == "\"" {
                    if let n = it.next() { if n == "\"" { field.append("\"") } else { inQuotes = false; pending = n } } else { inQuotes = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": record.append(field); field = ""
                case "\n", "\r\n":
                    record.append(field); field = ""
                    if !(record.count == 1 && record[0].isEmpty) { records.append(record) }
                    record = []
                case "\r": break
                default: field.append(c)
                }
            }
        }
        if !field.isEmpty || !record.isEmpty { record.append(field); records.append(record) }
        return records
    }

    public func importRows(_ rows: [Row], defaultCategory: PersonCategory, scheduler: ResearchScheduler?, fileName: String) throws -> Result {
        var result = Result()
        let source = try store.addSource(Source(kind: .csvFile, title: "List import: \(fileName)", documentRef: "list:\(IDGen.make().prefix(8)):\(fileName)",
                                                reliability: Source.defaultReliability(.csvFile)))
        _ = source
        for row in rows {
            let qid = row.wikidata?.uppercased().trimmingCharacters(in: .whitespaces)
            if let qid, (try? WikidataConnector.validateQID(qid)) != nil, let scheduler {
                result.jobs.append(try scheduler.enqueue(ResearchJob(kind: .wikidataEntity, target: qid)))
                continue
            }
            if let yt = row.youtube, let scheduler {
                result.jobs.append(try scheduler.enqueue(ResearchJob(kind: .youtubeChannel, target: yt)))
                continue
            }
            let cat = row.category ?? defaultCategory
            let isPrivate = row.isPrivate ?? cat.isPrivateByDefault
            let p = Person(displayName: row.name, categories: [cat, .userImported], isPrivate: isPrivate,
                           excludeFromResearch: isPrivate, origin: .csv)
            try store.upsert(p, privateData: row.notes.map { PrivatePersonData(notes: $0) })
            result.created.append(p.id)
        }
        return result
    }
}

/// "Export my data" — a complete, human-readable JSON archive of everything stored.
public struct DataExporter {
    public let store: GraphStore
    public init(store: GraphStore) { self.store = store }

    public struct Archive: Codable {
        public var exportedAt: Date
        public var schemaVersion: Int
        public var people: [Person]
        public var identities: [Identity]
        public var relationships: [Relationship]
        public var evidence: [RelationshipEvidence]
        public var sources: [Source]
        public var events: [FamilyEvent]
        public var privateData: [String: PrivatePersonData]
    }

    public func archive(includePrivateData: Bool) throws -> Archive {
        let people = try store.allPeople(limit: .max)
        var identities: [Identity] = [], events: [FamilyEvent] = [], privateData: [String: PrivatePersonData] = [:]
        var rels: [EntityID: Relationship] = [:]
        for p in people {
            identities += try store.identities(of: p.id)
            events += try store.events(of: p.id)
            for r in try store.relationships(of: p.id) { rels[r.id] = r }
            if includePrivateData, let d = try? store.privateData(for: p.id) { privateData[p.id] = d }
        }
        var evidence: [RelationshipEvidence] = [], sources: [EntityID: Source] = [:]
        for r in rels.values {
            for (e, s) in try store.evidence(for: r.id) { evidence.append(e); sources[s.id] = s }
        }
        return Archive(exportedAt: Date(), schemaVersion: Schema.currentVersion, people: people, identities: identities,
                       relationships: Array(rels.values), evidence: evidence, sources: Array(sources.values), events: events,
                       privateData: privateData)
    }

    public func exportJSON(includePrivateData: Bool) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(archive(includePrivateData: includePrivateData))
    }
}
