import Foundation

/// One node of a GEDCOM record tree: `level [@xref@] TAG [value]`.
public final class GEDCOMNode: @unchecked Sendable {
    public let level: Int
    public let xref: String?
    public let tag: String
    public var value: String
    public var children: [GEDCOMNode] = []

    init(level: Int, xref: String?, tag: String, value: String) {
        self.level = level; self.xref = xref; self.tag = tag; self.value = value
    }

    public func first(_ tag: String) -> GEDCOMNode? { children.first { $0.tag == tag } }
    public func all(_ tag: String) -> [GEDCOMNode] { children.filter { $0.tag == tag } }
    public func value(at path: String...) -> String? {
        var node: GEDCOMNode? = self
        for t in path { node = node?.first(t) }
        return node?.value.isEmpty == false ? node?.value : nil
    }
}

public struct GEDCOMParseError: Error, CustomStringConvertible {
    public let line: Int
    public let message: String
    public var description: String { "GEDCOM line \(line): \(message)" }
}

/// Tolerant GEDCOM 5.5.1 / 7.0 parser. Handles CONC/CONT continuation, BOMs, CRLF and blank lines.
public enum GEDCOMParser {
    public static func parse(_ text: String) throws -> [GEDCOMNode] {
        var roots: [GEDCOMNode] = []
        var stack: [GEDCOMNode] = []
        var lineNo = 0
        let cleaned = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        for rawLine in cleaned.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            lineNo += 1
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
            if line.isEmpty { continue }
            var parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
            guard let level = Int(parts[0]) else { throw GEDCOMParseError(line: lineNo, message: "missing level") }
            parts.removeFirst()
            guard !parts.isEmpty else { throw GEDCOMParseError(line: lineNo, message: "missing tag") }
            var xref: String? = nil
            if parts[0].hasPrefix("@") && parts[0].hasSuffix("@") && parts[0].count > 2 {
                xref = parts.removeFirst()
                if parts.isEmpty { throw GEDCOMParseError(line: lineNo, message: "missing tag after xref") }
                // re-split remainder: tag [value]
                let rest = parts.joined(separator: " ").split(separator: " ", maxSplits: 1).map(String.init)
                parts = rest
            }
            let tag = parts[0].uppercased()
            let value = parts.count > 1 ? parts[1] : ""

            while let top = stack.last, top.level >= level { stack.removeLast() }
            if tag == "CONC" || tag == "CONT", let parent = stack.last {
                parent.value += (tag == "CONT" ? "\n" : "") + value
                continue
            }
            let node = GEDCOMNode(level: level, xref: xref, tag: tag, value: value)
            if level == 0 { roots.append(node) }
            else if let parent = stack.last { parent.children.append(node) }
            else { throw GEDCOMParseError(line: lineNo, message: "orphan line at level \(level)") }
            stack.append(node)
        }
        return roots
    }

    /// Splits a GEDCOM NAME value "John /Smith/ Jr." into given, surname and display name.
    public static func splitName(_ value: String) -> (given: String?, surname: String?, display: String) {
        let pieces = value.components(separatedBy: "/")
        let given = pieces.first?.trimmingCharacters(in: .whitespaces)
        let surname = pieces.count > 1 ? pieces[1].trimmingCharacters(in: .whitespaces) : nil
        let suffix = pieces.count > 2 ? pieces[2].trimmingCharacters(in: .whitespaces) : ""
        let display = [given, surname, suffix].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return (given?.isEmpty == true ? nil : given, surname?.isEmpty == true ? nil : surname, display.isEmpty ? "Unknown" : display)
    }
}

/// Summary of a GEDCOM import.
public struct GEDCOMImportResult: Sendable {
    public let importID: String
    public let sourceID: EntityID
    public let peopleCreated: Int
    public let relationshipsCreated: Int
    public let eventsCreated: Int
    public let warnings: [String]
    /// Map of GEDCOM xref → person ID.
    public let personIDs: [String: EntityID]
}

/// Imports a GEDCOM file into the graph. Each import gets its own scoped identity namespace so
/// "@I1@" in two different files never collide, and nothing is merged automatically —
/// cross-file duplicates go to the merge engine as proposals.
public struct GEDCOMImporter {
    public let store: GraphStore
    public init(store: GraphStore) { self.store = store }

    public func importGEDCOM(text: String, fileName: String, markLivingPrivate: Bool = true) throws -> GEDCOMImportResult {
        let roots = try GEDCOMParser.parse(text)
        let importID = "ged-\(IDGen.make().prefix(8))"
        var warnings: [String] = []
        let source = try store.addSource(Source(kind: .gedcomFile, title: "GEDCOM import: \(fileName)",
                                                documentRef: "\(importID):\(fileName)", reliability: Source.defaultReliability(.gedcomFile)))
        let provenance = "GEDCOMImporter \(importID) (\(fileName))"
        var xrefToPerson: [String: EntityID] = [:]
        var people = 0, rels = 0, events = 0

        try store.db.transaction {
            for indi in roots where indi.tag == "INDI" {
                guard let xref = indi.xref else { warnings.append("INDI without xref skipped"); continue }
                let nameNode = indi.first("NAME")
                let (given, surname, display) = GEDCOMParser.splitName(nameNode?.value ?? "")
                let aliases = indi.all("NAME").dropFirst().map { GEDCOMParser.splitName($0.value).display }
                let birth = indi.first("BIRT"), death = indi.first("DEAT")
                var person = Person(displayName: display,
                                    givenName: nameNode?.value(at: "GIVN") ?? given,
                                    surname: nameNode?.value(at: "SURN") ?? surname,
                                    aliases: Array(aliases),
                                    categories: [.familyMember, .userImported],
                                    sex: Sex(rawValue: indi.value(at: "SEX") ?? "U") ?? .unknown,
                                    birth: HistoricalDate.parse(birth?.value(at: "DATE")), birthPlace: birth?.value(at: "PLAC"),
                                    death: HistoricalDate.parse(death?.value(at: "DATE")), deathPlace: death?.value(at: "PLAC"),
                                    occupation: indi.value(at: "OCCU"), origin: .gedcom)
                if death != nil { person.isLiving = false }
                if markLivingPrivate && person.mayBeLiving { person.isPrivate = true }
                // Private (possibly living) people are always excluded from external research by default.
                person.excludeFromResearch = person.isPrivate
                try store.upsert(person)
                try store.addIdentity(Identity(personID: person.id, scheme: .gedcomXref, value: "\(importID):\(xref)"))
                if let wt = indi.value(at: "_WIKITREE") ?? indi.value(at: "WWW").flatMap(Self.wikiTreeID) {
                    try store.addIdentity(Identity(personID: person.id, scheme: .wikitree, value: wt, url: "https://www.wikitree.com/wiki/\(wt)"))
                }
                if let fs = indi.value(at: "_FSFTID") ?? indi.value(at: "_FID") {
                    try store.addIdentity(Identity(personID: person.id, scheme: .familySearch, value: fs,
                                                   url: "https://www.familysearch.org/tree/person/details/\(fs)"))
                }
                xrefToPerson[xref] = person.id
                people += 1

                for (tag, type) in [("BIRT", FamilyEventType.birth), ("DEAT", .death), ("BAPM", .baptism), ("CHR", .baptism),
                                    ("BURI", .burial), ("RESI", .residence), ("IMMI", .immigration), ("CENS", .census), ("ADOP", .adoption)] {
                    for node in indi.all(tag) {
                        try store.addEvent(FamilyEvent(personID: person.id, type: type, date: HistoricalDate.parse(node.value(at: "DATE")),
                                                       place: node.value(at: "PLAC"), sourceID: source.id, details: node.value.isEmpty ? nil : node.value))
                        events += 1
                    }
                }
            }

            func evidence(_ text: String) -> [EvidenceInput] {
                [EvidenceInput(sourceID: source.id, description: text, extractedBy: "GEDCOMImporter")]
            }

            for fam in roots where fam.tag == "FAM" {
                let famRef = fam.xref ?? "?"
                let husb = fam.value(at: "HUSB").flatMap { xrefToPerson[$0] }
                let wife = fam.value(at: "WIFE").flatMap { xrefToPerson[$0] }
                let partners = [husb, wife].compactMap { $0 }
                let marr = fam.first("MARR"), div = fam.first("DIV")
                if partners.count == 2 {
                    let type: RelationshipType = div != nil ? .formerSpouse : .spouse
                    try store.addRelationship(Relationship(fromID: partners[0], toID: partners[1], type: type, verification: .userAsserted,
                                                           confidence: 0.7, startDate: HistoricalDate.parse(marr?.value(at: "DATE")),
                                                           endDate: HistoricalDate.parse(div?.value(at: "DATE")), provenance: provenance),
                                              evidence: evidence("Family record \(famRef) lists them as partners\(marr != nil ? " (marriage recorded)" : "")."))
                    rels += 1
                    if let marr {
                        for (p, other) in [(partners[0], partners[1]), (partners[1], partners[0])] {
                            try store.addEvent(FamilyEvent(personID: p, type: .marriage, date: HistoricalDate.parse(marr.value(at: "DATE")),
                                                           place: marr.value(at: "PLAC"), sourceID: source.id, relatedPersonID: other))
                            events += 1
                        }
                    }
                }
                for chilNode in fam.all("CHIL") {
                    guard let child = xrefToPerson[chilNode.value] else { warnings.append("FAM \(famRef): unknown child \(chilNode.value)"); continue }
                    // Pedigree: check the child's FAMC link for PEDI (adopted / foster / birth).
                    let indi = roots.first { $0.xref == chilNode.value }
                    let famc = indi?.all("FAMC").first { $0.value == famRef }
                    let pedi = (famc?.value(at: "PEDI") ?? chilNode.value(at: "_FREL") ?? "birth").lowercased()
                    let type: RelationshipType = pedi.contains("adopt") ? .adoptiveParent : .parent
                    for parent in partners {
                        try store.addRelationship(Relationship(fromID: parent, toID: child, type: type, verification: .userAsserted,
                                                               confidence: pedi.contains("foster") ? 0.5 : 0.7, provenance: provenance),
                                                  evidence: evidence("Family record \(famRef) lists the child with pedigree '\(pedi)'."))
                        rels += 1
                    }
                }
            }
        }
        return GEDCOMImportResult(importID: importID, sourceID: source.id, peopleCreated: people, relationshipsCreated: rels,
                                  eventsCreated: events, warnings: warnings, personIDs: xrefToPerson)
    }

    static func wikiTreeID(_ url: String) -> String? {
        guard url.contains("wikitree.com/wiki/") else { return nil }
        return url.components(separatedBy: "/wiki/").last
    }

    /// Removes everything created by one import. People who gained other identities
    /// (e.g. were linked to Wikidata afterwards) are kept.
    public func removeImport(_ importID: String) throws -> Int {
        let rows = try store.db.query("SELECT person_id FROM identity WHERE scheme = 'gedcomXref' AND value LIKE ?", "\(importID):%")
        var removed = 0
        try store.db.transaction {
            for r in rows {
                let pid = r.string("person_id")!
                let others = try store.db.scalarInt("SELECT COUNT(*) FROM identity WHERE person_id = ? AND NOT (scheme = 'gedcomXref' AND value LIKE ?)",
                                                    pid, "\(importID):%")
                if others == 0 { try store.deletePerson(pid); removed += 1 }
            }
            try store.db.run("DELETE FROM source WHERE kind = 'gedcomFile' AND document_ref LIKE ?", "\(importID):%")
        }
        return removed
    }
}

/// Writes GEDCOM 5.5.1 from the graph. Private people are exported only when `includePrivate` is set.
public struct GEDCOMExporter {
    public let store: GraphStore
    public init(store: GraphStore) { self.store = store }

    public func export(personIDs: [EntityID]? = nil, includePrivate: Bool = false) throws -> String {
        let people = try (personIDs.map { try store.people($0) } ?? store.allPeople(limit: .max))
            .filter { includePrivate || !$0.isPrivate }
        var xref: [EntityID: String] = [:]
        for (i, p) in people.enumerated() { xref[p.id] = "@I\(i + 1)@" }

        var out = ["0 HEAD", "1 SOUR MULTIVERSE_TREE", "2 NAME Multiverse Tree", "2 VERS 0.1", "1 GEDC", "2 VERS 5.5.1",
                   "2 FORM LINEAGE-LINKED", "1 CHAR UTF-8"]

        // Families: group parent edges by child to form couples.
        var familyKey: [String: (parents: [EntityID], children: [(EntityID, Bool)], marriage: Relationship?)] = [:]
        var parentsByChild: [EntityID: [(EntityID, Bool)]] = [:]
        var couples: [String: Relationship] = [:]
        for p in people {
            for r in try store.relationships(of: p.id, includeUnestablished: false) {
                guard xref[r.fromID] != nil, xref[r.toID] != nil else { continue }
                if r.type.isDescent && r.toID == p.id { parentsByChild[p.id, default: []].append((r.fromID, r.type == .adoptiveParent)) }
                if (r.type == .spouse || r.type == .formerSpouse) && r.fromID == p.id {
                    couples[[r.fromID, r.toID].sorted().joined(separator: "+")] = r
                }
            }
        }
        for (child, parents) in parentsByChild {
            let key = parents.map(\.0).sorted().joined(separator: "+")
            var entry = familyKey[key] ?? (parents.map(\.0).sorted(), [], couples[key])
            entry.children.append((child, parents.contains { $0.1 }))
            familyKey[key] = entry
        }
        for (key, rel) in couples where familyKey[key] == nil { familyKey[key] = ([rel.fromID, rel.toID].sorted(), [], rel) }

        let families = familyKey.sorted { $0.key < $1.key }
        var famRefs: [String: String] = [:]
        for (i, f) in families.enumerated() { famRefs[f.key] = "@F\(i + 1)@" }

        let personByID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
        for p in people {
            out.append("0 \(xref[p.id]!) INDI")
            out.append("1 NAME \(p.givenName ?? p.displayName) /\(p.surname ?? "")/")
            if let g = p.givenName { out.append("2 GIVN \(g)") }
            if let s = p.surname { out.append("2 SURN \(s)") }
            for a in p.aliases { out.append("1 NAME \(a)") }
            out.append("1 SEX \(p.sex == .other ? "U" : p.sex.rawValue)")
            if p.birth != nil || p.birthPlace != nil {
                out.append("1 BIRT")
                if let d = p.birth { out.append("2 DATE \(Self.gedcomDate(d))") }
                if let pl = p.birthPlace { out.append("2 PLAC \(pl)") }
            }
            if p.death != nil || p.deathPlace != nil {
                out.append("1 DEAT")
                if let d = p.death { out.append("2 DATE \(Self.gedcomDate(d))") }
                if let pl = p.deathPlace { out.append("2 PLAC \(pl)") }
            }
            if let o = p.occupation { out.append("1 OCCU \(o)") }
            for f in families {
                if f.value.parents.contains(p.id) { out.append("1 FAMS \(famRefs[f.key]!)") }
                if let c = f.value.children.first(where: { $0.0 == p.id }) {
                    out.append("1 FAMC \(famRefs[f.key]!)")
                    if c.1 { out.append("2 PEDI adopted") }
                }
            }
        }
        for f in families {
            out.append("0 \(famRefs[f.key]!) FAM")
            let sorted = f.value.parents.sorted { (personByID[$0]?.sex == .male ? 0 : 1) < (personByID[$1]?.sex == .male ? 0 : 1) }
            if sorted.count > 0 { out.append("1 HUSB \(xref[sorted[0]]!)") }
            if sorted.count > 1 { out.append("1 WIFE \(xref[sorted[1]]!)") }
            for (c, _) in f.value.children { out.append("1 CHIL \(xref[c]!)") }
            if let m = f.value.marriage {
                out.append("1 MARR")
                if let d = m.startDate { out.append("2 DATE \(Self.gedcomDate(d))") }
                if m.type == .formerSpouse { out.append("1 DIV Y") }
            }
        }
        out.append("0 TRLR")
        return out.joined(separator: "\n") + "\n"
    }

    static func gedcomDate(_ d: HistoricalDate) -> String {
        if let raw = d.raw, d.year == nil { return raw }
        let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
        var parts: [String] = []
        if let day = d.day, d.month != nil { parts.append(String(day)) }
        if let m = d.month, (1...12).contains(m) { parts.append(months[m - 1]) }
        if let y = d.year { parts.append(String(y)) }
        let prefix: String
        switch d.qualifier {
        case .about: prefix = "ABT "
        case .before: prefix = "BEF "
        case .after: prefix = "AFT "
        case .estimated: prefix = "EST "
        case .calculated: prefix = "CAL "
        case .exact: prefix = ""
        }
        return prefix + parts.joined(separator: " ")
    }
}
