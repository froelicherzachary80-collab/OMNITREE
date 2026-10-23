import Foundation

public typealias EntityID = String

public enum IDGen {
    public static func make() -> EntityID { UUID().uuidString.lowercased() }
}

/// A date that may be partial or approximate (common in genealogy and history).
public struct HistoricalDate: Codable, Sendable, Hashable, Comparable, CustomStringConvertible {
    public enum Qualifier: String, Codable, Sendable { case exact, about, before, after, estimated, calculated }

    public var year: Int?
    public var month: Int?
    public var day: Int?
    public var qualifier: Qualifier
    /// Original text as written in the source, preserved for provenance.
    public var raw: String?

    public init(year: Int?, month: Int? = nil, day: Int? = nil, qualifier: Qualifier = .exact, raw: String? = nil) {
        self.year = year
        self.month = month
        self.day = day
        self.qualifier = qualifier
        self.raw = raw
    }

    /// Parses ISO (`1901-03-12`, `1901-03`, `1901`), Wikidata (`+1901-03-12T00:00:00Z`)
    /// and GEDCOM (`12 MAR 1901`, `ABT 1850`, `BEF 1700`) style dates.
    public static func parse(_ text: String?) -> HistoricalDate? {
        guard var s = text?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        let raw = s
        var q: Qualifier = .exact
        let upper = s.uppercased()
        let qualifiers: [(String, Qualifier)] = [("ABT ", .about), ("ABOUT ", .about), ("CIRCA ", .about), ("C. ", .about),
                                                 ("BEF ", .before), ("AFT ", .after), ("EST ", .estimated), ("CAL ", .calculated)]
        for (prefix, value) in qualifiers where upper.hasPrefix(prefix) {
            q = value
            s = String(s.dropFirst(prefix.count))
            break
        }
        if s.hasPrefix("+") { s.removeFirst() }
        if let t = s.firstIndex(of: "T") { s = String(s[..<t]) }

        // ISO style
        let isoParts = s.split(separator: "-").map(String.init)
        if let y = Int(isoParts.first ?? ""), isoParts.count <= 3, isoParts.allSatisfy({ Int($0) != nil }) {
            var m = isoParts.count > 1 ? Int(isoParts[1]) : nil
            var d = isoParts.count > 2 ? Int(isoParts[2]) : nil
            if m == 0 { m = nil }   // Wikidata uses 00 for unknown precision
            if d == 0 { d = nil }
            return HistoricalDate(year: y, month: m, day: d, qualifier: q, raw: raw)
        }

        // GEDCOM style: [day] [MON] year
        let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
        let tokens = s.uppercased().split(separator: " ").map(String.init)
        var year: Int?, month: Int?, day: Int?
        let monthIndex = tokens.firstIndex { Int($0) == nil && months.contains(String($0.prefix(3))) }
        if let mi = monthIndex {
            month = months.firstIndex(of: String(tokens[mi].prefix(3)))! + 1
            if mi > 0 { day = Int(tokens[mi - 1]) }
            if mi + 1 < tokens.count { year = Int(tokens[mi + 1]) }
        } else {
            year = tokens.compactMap { Int($0) }.last
        }
        guard year != nil else { return HistoricalDate(year: nil, qualifier: q, raw: raw) }
        return HistoricalDate(year: year, month: month, day: day, qualifier: q, raw: raw)
    }

    /// Canonical ISO-like storage form.
    public var isoString: String? {
        guard let y = year else { return nil }
        var out = String(format: "%04d", y)
        if let m = month { out += String(format: "-%02d", m) }
        if let d = day, month != nil { out += String(format: "-%02d", d) }
        return out
    }

    public var description: String {
        let base = isoString ?? raw ?? "unknown"
        switch qualifier {
        case .exact: return base
        case .about: return "c. \(base)"
        case .before: return "before \(base)"
        case .after: return "after \(base)"
        case .estimated: return "est. \(base)"
        case .calculated: return "calc. \(base)"
        }
    }

    private var sortKey: Int { (year ?? Int.min / 1000) * 10_000 + (month ?? 0) * 100 + (day ?? 0) }
    public static func < (lhs: HistoricalDate, rhs: HistoricalDate) -> Bool { lhs.sortKey < rhs.sortKey }
}

public enum Sex: String, Codable, Sendable { case male = "M", female = "F", unknown = "U", other = "X" }

/// Where a record came from.
public enum RecordOrigin: String, Codable, Sendable, CaseIterable {
    case user, gedcom, wikidata, wikipedia, youtube, openLibrary, openAlex, csv, json, sample, merged
}

/// Private, user-provided data. Stored only as an encrypted blob.
public struct PrivatePersonData: Codable, Sendable, Hashable {
    public var notes: String?
    public var contact: String?
    public var exactBirthDate: String?
    public var exactBirthPlace: String?
    public var custom: [String: String]

    public init(notes: String? = nil, contact: String? = nil, exactBirthDate: String? = nil,
                exactBirthPlace: String? = nil, custom: [String: String] = [:]) {
        self.notes = notes
        self.contact = contact
        self.exactBirthDate = exactBirthDate
        self.exactBirthPlace = exactBirthPlace
        self.custom = custom
    }
}

public struct Person: Codable, Sendable, Hashable, Identifiable {
    public var id: EntityID
    public var displayName: String
    public var givenName: String?
    public var surname: String?
    public var aliases: [String]
    public var categories: Set<PersonCategory>
    public var sex: Sex
    public var birth: HistoricalDate?
    public var birthPlace: String?
    public var death: HistoricalDate?
    public var deathPlace: String?
    public var occupation: String?
    public var biography: String?
    public var country: String?
    public var imageURL: String?
    public var imageLicense: String?
    /// Private profiles are never exported to public research or shown outside the device.
    public var isPrivate: Bool
    /// When true, no research agent will query external sources about this person.
    public var excludeFromResearch: Bool
    public var isLiving: Bool?
    /// Sample data shipped with the app for demonstration — always labelled in the UI.
    public var isSample: Bool
    public var origin: RecordOrigin
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: EntityID = IDGen.make(), displayName: String, givenName: String? = nil, surname: String? = nil,
                aliases: [String] = [], categories: Set<PersonCategory> = [], sex: Sex = .unknown,
                birth: HistoricalDate? = nil, birthPlace: String? = nil, death: HistoricalDate? = nil,
                deathPlace: String? = nil, occupation: String? = nil, biography: String? = nil,
                country: String? = nil, imageURL: String? = nil, imageLicense: String? = nil,
                isPrivate: Bool = false, excludeFromResearch: Bool = false, isLiving: Bool? = nil,
                isSample: Bool = false, origin: RecordOrigin = .user, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.displayName = displayName
        self.givenName = givenName
        self.surname = surname
        self.aliases = aliases
        self.categories = categories
        self.sex = sex
        self.birth = birth
        self.birthPlace = birthPlace
        self.death = death
        self.deathPlace = deathPlace
        self.occupation = occupation
        self.biography = biography
        self.country = country
        self.imageURL = imageURL
        self.imageLicense = imageLicense
        self.isPrivate = isPrivate
        self.excludeFromResearch = excludeFromResearch
        self.isLiving = isLiving
        self.isSample = isSample
        self.origin = origin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Best guess at whether the person may be living; used to apply privacy defaults.
    public var mayBeLiving: Bool {
        if let isLiving { return isLiving }
        if death != nil { return false }
        guard let y = birth?.year else { return true }
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: Date())
        return currentYear - y < 110
    }
}

/// Identifier schemes for external identities. Stored separately from the person
/// so one person can carry many IDs, and so identity resolution never relies on names.
public enum IdentityScheme: String, Codable, Sendable, CaseIterable {
    case wikidata, youtubeChannel, gedcomXref, wikitree, familySearch, openLibraryAuthor, openAlexAuthor, imdbID, twitch, tiktok, instagram, custom
}

public struct Identity: Codable, Sendable, Hashable {
    public var id: EntityID
    public var personID: EntityID
    public var scheme: IdentityScheme
    public var value: String
    public var url: String?

    public init(id: EntityID = IDGen.make(), personID: EntityID, scheme: IdentityScheme, value: String, url: String? = nil) {
        self.id = id
        self.personID = personID
        self.scheme = scheme
        self.value = value
        self.url = url
    }
}

public struct PlatformAccount: Codable, Sendable, Hashable {
    public var id: EntityID
    public var personID: EntityID
    public var platform: String
    public var handle: String?
    public var externalID: String?
    public var url: String?
    public var title: String?
    public var subscriberCount: Int?

    public init(id: EntityID = IDGen.make(), personID: EntityID, platform: String, handle: String? = nil,
                externalID: String? = nil, url: String? = nil, title: String? = nil, subscriberCount: Int? = nil) {
        self.id = id
        self.personID = personID
        self.platform = platform
        self.handle = handle
        self.externalID = externalID
        self.url = url
        self.title = title
        self.subscriberCount = subscriberCount
    }
}

public struct Organization: Codable, Sendable, Hashable {
    public var id: EntityID
    public var name: String
    public var kind: String
    public var wikidataQID: String?
    public init(id: EntityID = IDGen.make(), name: String, kind: String, wikidataQID: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.wikidataQID = wikidataQID
    }
}

public struct Community: Codable, Sendable, Hashable {
    public var id: EntityID
    public var name: String
    /// e.g. "minecraftSMP", "creatorGroup", "institution", "family".
    public var kind: String
    public var summary: String?
    public var wikidataQID: String?
    public init(id: EntityID = IDGen.make(), name: String, kind: String, summary: String? = nil, wikidataQID: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.summary = summary; self.wikidataQID = wikidataQID
    }
}

public struct MediaProject: Codable, Sendable, Hashable {
    public var id: EntityID
    public var title: String
    /// e.g. "film", "tvSeries", "album", "video", "livestream", "book".
    public var kind: String
    public var year: Int?
    public var wikidataQID: String?
    public var url: String?
    public init(id: EntityID = IDGen.make(), title: String, kind: String, year: Int? = nil, wikidataQID: String? = nil, url: String? = nil) {
        self.id = id; self.title = title; self.kind = kind; self.year = year; self.wikidataQID = wikidataQID; self.url = url
    }
}

public struct MediaCredit: Codable, Sendable, Hashable {
    public var projectID: EntityID
    public var personID: EntityID
    public var role: String
    public init(projectID: EntityID, personID: EntityID, role: String) {
        self.projectID = projectID; self.personID = personID; self.role = role
    }
}

public enum SourceKind: String, Codable, Sendable, CaseIterable {
    case wikidata, wikipedia, youtubeAPI, openAlex, openLibrary, internetArchive, wikiTree, familySearch,
         gedcomFile, csvFile, jsonFile, userEntry, webPage, transcript, archive
}

/// A citable source. Every relationship links to at least one via `RelationshipEvidence`.
public struct Source: Codable, Sendable, Hashable {
    public var id: EntityID
    public var kind: SourceKind
    public var title: String
    public var url: String?
    /// For imported documents with no URL (GEDCOM, CSV), a reference to the document.
    public var documentRef: String?
    public var publisher: String?
    public var license: String?
    /// 0…1 — prior reliability of the source used for evidence-quality scoring.
    public var reliability: Double
    public var retrievedAt: Date

    public init(id: EntityID = IDGen.make(), kind: SourceKind, title: String, url: String? = nil, documentRef: String? = nil,
                publisher: String? = nil, license: String? = nil, reliability: Double, retrievedAt: Date = Date()) {
        self.id = id; self.kind = kind; self.title = title; self.url = url; self.documentRef = documentRef
        self.publisher = publisher; self.license = license; self.reliability = reliability; self.retrievedAt = retrievedAt
    }

    /// Default reliability priors per source kind.
    public static func defaultReliability(_ kind: SourceKind) -> Double {
        switch kind {
        case .wikidata: return 0.85
        case .wikipedia: return 0.75
        case .youtubeAPI: return 0.9      // reliable for metadata, not for relationships
        case .openAlex, .openLibrary: return 0.85
        case .internetArchive, .archive: return 0.7
        case .wikiTree, .familySearch: return 0.7
        case .gedcomFile, .csvFile, .jsonFile, .userEntry: return 0.6
        case .webPage: return 0.5
        case .transcript: return 0.55
        }
    }
}

public struct RelationshipEvidence: Codable, Sendable, Hashable {
    public var id: EntityID
    public var relationshipID: EntityID
    public var sourceID: EntityID
    public var description: String
    public var quote: String?
    /// Agent or process that produced the evidence, e.g. "WikidataConnector", "GEDCOMImporter", "user".
    public var extractedBy: String
    public var createdAt: Date

    public init(id: EntityID = IDGen.make(), relationshipID: EntityID, sourceID: EntityID, description: String,
                quote: String? = nil, extractedBy: String, createdAt: Date = Date()) {
        self.id = id; self.relationshipID = relationshipID; self.sourceID = sourceID; self.description = description
        self.quote = quote; self.extractedBy = extractedBy; self.createdAt = createdAt
    }
}

public struct Relationship: Codable, Sendable, Hashable, Identifiable {
    public var id: EntityID
    public var fromID: EntityID
    public var toID: EntityID
    public var type: RelationshipType
    public var verification: VerificationStatus
    /// 0…1 confidence that the relationship is real.
    public var confidence: Double
    /// Direct relationships come straight from evidence. Inferred ones are derived (e.g. cousin from parent chains).
    public var isInferred: Bool
    public var startDate: HistoricalDate?
    public var endDate: HistoricalDate?
    public var lastChecked: Date
    /// Free-text provenance: which import/research run created this edge.
    public var provenance: String
    /// Optional project (film, video, SMP) that gives context to the edge, e.g. the shared film.
    public var contextProjectID: EntityID?
    public var contextLabel: String?
    public var createdAt: Date

    public var category: RelationshipCategory { type.category }
    public var isDirected: Bool { type.isDirected }

    public init(id: EntityID = IDGen.make(), fromID: EntityID, toID: EntityID, type: RelationshipType,
                verification: VerificationStatus, confidence: Double, isInferred: Bool = false,
                startDate: HistoricalDate? = nil, endDate: HistoricalDate? = nil, lastChecked: Date = Date(),
                provenance: String, contextProjectID: EntityID? = nil, contextLabel: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.fromID = fromID; self.toID = toID; self.type = type; self.verification = verification
        self.confidence = max(0, min(1, confidence)); self.isInferred = isInferred; self.startDate = startDate
        self.endDate = endDate; self.lastChecked = lastChecked; self.provenance = provenance
        self.contextProjectID = contextProjectID; self.contextLabel = contextLabel; self.createdAt = createdAt
    }

    public func other(than personID: EntityID) -> EntityID { fromID == personID ? toID : fromID }

    /// Label describing the relationship as seen from `personID`.
    public func label(from personID: EntityID) -> String {
        guard isDirected else { return type.displayName.lowercased() }
        return fromID == personID ? type.forwardLabel : type.reverseLabel
    }
}

public enum FamilyEventType: String, Codable, Sendable, CaseIterable {
    case birth, death, marriage, divorce, baptism, burial, adoption, residence, immigration, census, occupation, other
}

public struct FamilyEvent: Codable, Sendable, Hashable {
    public var id: EntityID
    public var personID: EntityID
    public var type: FamilyEventType
    public var date: HistoricalDate?
    public var place: String?
    public var sourceID: EntityID?
    public var details: String?
    /// For couple events (marriage/divorce), the partner.
    public var relatedPersonID: EntityID?

    public init(id: EntityID = IDGen.make(), personID: EntityID, type: FamilyEventType, date: HistoricalDate? = nil,
                place: String? = nil, sourceID: EntityID? = nil, details: String? = nil, relatedPersonID: EntityID? = nil) {
        self.id = id; self.personID = personID; self.type = type; self.date = date; self.place = place
        self.sourceID = sourceID; self.details = details; self.relatedPersonID = relatedPersonID
    }
}

public enum MergeStatus: String, Codable, Sendable { case pending, approved, rejected }

public struct MergeProposal: Codable, Sendable, Hashable, Identifiable {
    public var id: EntityID
    public var personA: EntityID
    public var personB: EntityID
    public var score: Double
    public var reasons: [String]
    public var conflicts: [String]
    public var status: MergeStatus
    public var createdAt: Date
    public var decidedAt: Date?

    public init(id: EntityID = IDGen.make(), personA: EntityID, personB: EntityID, score: Double, reasons: [String],
                conflicts: [String], status: MergeStatus = .pending, createdAt: Date = Date(), decidedAt: Date? = nil) {
        self.id = id; self.personA = personA; self.personB = personB; self.score = score; self.reasons = reasons
        self.conflicts = conflicts; self.status = status; self.createdAt = createdAt; self.decidedAt = decidedAt
    }
}

public struct GraphSnapshot: Codable, Sendable, Hashable {
    public var id: EntityID
    public var label: String
    public var createdAt: Date
    public var nodeCount: Int
    public var edgeCount: Int
    public init(id: EntityID = IDGen.make(), label: String, createdAt: Date = Date(), nodeCount: Int, edgeCount: Int) {
        self.id = id; self.label = label; self.createdAt = createdAt; self.nodeCount = nodeCount; self.edgeCount = edgeCount
    }
}
