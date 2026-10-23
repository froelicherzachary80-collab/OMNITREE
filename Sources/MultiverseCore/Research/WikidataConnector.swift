import Foundation

public struct WikidataSearchHit: Sendable, Hashable {
    public let qid: String
    public let label: String
    public let description: String?
}

public struct WikidataPersonRecord: Sendable {
    public var qid: String
    public var label: String
    public var description: String?
    public var birth: HistoricalDate?
    public var death: HistoricalDate?
    public var birthPlace: String?
    public var deathPlace: String?
    public var sex: Sex = .unknown
    public var occupations: [String] = []
    public var countries: [String] = []
    public var imageURL: String?
    public var youtubeChannelIDs: [String] = []
    public var wikipediaTitle: String?
    public var isHuman: Bool = false
}

public struct WikidataRelationStatement: Sendable, Hashable {
    public let property: String
    public let relatedQID: String
    public let relatedLabel: String
    public let relatedDescription: String?
    public let start: HistoricalDate?
    public let end: HistoricalDate?
}

public struct WikidataCredit: Sendable, Hashable {
    public let workQID: String
    public let workTitle: String
    public let year: Int?
    public let isSeries: Bool
    public let personQID: String
    public let personLabel: String
    /// "cast", "director" or "producer".
    public let role: String
}

/// Free Wikidata access: the `wbsearchentities` API and the public SPARQL endpoint.
public struct WikidataConnector: Sendable {
    public let http: ResearchHTTP
    public static let sparqlEndpoint = "https://query.wikidata.org/sparql"
    public static let apiEndpoint = "https://www.wikidata.org/w/api.php"

    public init(http: ResearchHTTP) { self.http = http }

    public static func entityURL(_ qid: String) -> String { "https://www.wikidata.org/wiki/\(qid)" }

    /// Supported relationship properties and how they map to graph edges.
    /// `subjectIsFrom`: whether the subject is the `from` side of the stored directed edge.
    public static let relationProperties: [String: (type: RelationshipType, subjectIsFrom: Bool, label: String, confidence: Double)] = [
        "P22": (.parent, false, "father", 0.9),
        "P25": (.parent, false, "mother", 0.9),
        "P40": (.parent, true, "child", 0.9),
        "P26": (.spouse, true, "spouse", 0.9),
        "P3373": (.sibling, true, "sibling", 0.85),
        "P1038": (.otherKinship, true, "relative", 0.7),
        "P1066": (.teacherStudent, false, "student of", 0.8),
        "P802": (.teacherStudent, true, "student", 0.8),
    ]

    // MARK: Requests

    public func search(_ name: String, limit: Int = 10) async throws -> [WikidataSearchHit] {
        let url = try URL.build(Self.apiEndpoint, ["action": "wbsearchentities", "search": name, "language": "en",
                                                   "uselang": "en", "type": "item", "format": "json", "limit": String(limit)])
        return Self.parseSearch(try await http.getJSON(url))
    }

    func sparql(_ query: String) async throws -> [[String: String]] {
        let url = try URL.build(Self.sparqlEndpoint, ["query": query, "format": "json"])
        return Self.parseBindings(try await http.getJSON(url, headers: ["Accept": "application/sparql-results+json"]))
    }

    public func fetchPerson(_ qid: String) async throws -> WikidataPersonRecord? {
        try Self.validateQID(qid)
        let q = """
        SELECT ?label ?description ?birth ?death ?birthPlaceLabel ?deathPlaceLabel ?sex ?occupationLabel ?countryLabel ?image ?yt ?article ?human WHERE {
          BIND(wd:\(qid) AS ?p)
          ?p rdfs:label ?label FILTER(LANG(?label) = "en")
          OPTIONAL { ?p schema:description ?description FILTER(LANG(?description) = "en") }
          OPTIONAL { ?p wdt:P569 ?birth }
          OPTIONAL { ?p wdt:P570 ?death }
          OPTIONAL { ?p wdt:P19 ?birthPlace }
          OPTIONAL { ?p wdt:P20 ?deathPlace }
          OPTIONAL { ?p wdt:P21 ?sex }
          OPTIONAL { ?p wdt:P106 ?occupation }
          OPTIONAL { ?p wdt:P27 ?country }
          OPTIONAL { ?p wdt:P18 ?image }
          OPTIONAL { ?p wdt:P2397 ?yt }
          OPTIONAL { ?article schema:about ?p ; schema:isPartOf <https://en.wikipedia.org/> }
          BIND(EXISTS { ?p wdt:P31 wd:Q5 } AS ?human)
          SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
        } LIMIT 200
        """
        return Self.parsePerson(qid: qid, rows: try await sparql(q))
    }

    public func fetchRelations(_ qid: String) async throws -> [WikidataRelationStatement] {
        try Self.validateQID(qid)
        let props = ["P22", "P25", "P40", "P26", "P3373", "P1038", "P1066", "P802"]
        let values = props.map { "(p:\($0) ps:\($0) \"\($0)\")" }.joined(separator: " ")
        let q = """
        SELECT ?prop ?rel ?relLabel ?relDescription ?start ?end WHERE {
          VALUES (?p ?ps ?prop) { \(values) }
          wd:\(qid) ?p ?st . ?st ?ps ?rel .
          ?rel wdt:P31 wd:Q5 .
          OPTIONAL { ?st pq:P580 ?start }
          OPTIONAL { ?st pq:P582 ?end }
          SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
        } LIMIT 500
        """
        return Self.parseRelations(try await sparql(q))
    }

    /// Film/TV credits of a person with the other cast, directors and producers of each work.
    public func fetchCoCredits(_ qid: String, maxWorks: Int = 25) async throws -> [WikidataCredit] {
        try Self.validateQID(qid)
        let q = """
        SELECT ?work ?workLabel ?year ?isSeries ?person ?personLabel ?role WHERE {
          { SELECT DISTINCT ?work WHERE { ?work wdt:P161 wd:\(qid) . } LIMIT \(maxWorks) }
          OPTIONAL { ?work wdt:P577 ?date . BIND(YEAR(?date) AS ?year) }
          BIND(EXISTS { ?work wdt:P31 wd:Q5398426 } AS ?isSeries)
          { ?work wdt:P161 ?person . BIND("cast" AS ?role) }
          UNION { ?work wdt:P57 ?person . BIND("director" AS ?role) }
          UNION { ?work wdt:P162 ?person . BIND("producer" AS ?role) }
          ?person wdt:P31 wd:Q5 .
          SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
        } LIMIT 3000
        """
        return Self.parseCredits(try await sparql(q))
    }

    /// Members of a community/organisation item (P463 member of, P102 party, P54 team, inverse P527 has part).
    public func fetchMembers(ofGroup qid: String, limit: Int = 300) async throws -> [WikidataSearchHit] {
        try Self.validateQID(qid)
        let q = """
        SELECT DISTINCT ?m ?mLabel ?mDescription WHERE {
          { ?m wdt:P463 wd:\(qid) } UNION { wd:\(qid) wdt:P527 ?m } UNION { ?m wdt:P54 wd:\(qid) }
          ?m wdt:P31 wd:Q5 .
          SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
        } LIMIT \(limit)
        """
        return try await sparql(q).compactMap { row in
            guard let qid = row["m"].flatMap(Self.qid(fromURI:)) else { return nil }
            return WikidataSearchHit(qid: qid, label: row["mLabel"] ?? qid, description: row["mDescription"])
        }
    }

    // MARK: Parsing (pure functions — unit tested with fixtures)

    public static func validateQID(_ qid: String) throws {
        guard qid.range(of: "^Q[0-9]+$", options: .regularExpression) != nil else { throw HTTPError.invalidURL(qid) }
    }

    public static func qid(fromURI uri: String) -> String? {
        guard let last = uri.split(separator: "/").last, last.hasPrefix("Q") else { return nil }
        return String(last)
    }

    public static func parseSearch(_ json: Any) -> [WikidataSearchHit] {
        guard let dict = json as? [String: Any], let items = dict["search"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return WikidataSearchHit(qid: id, label: item["label"] as? String ?? id, description: item["description"] as? String)
        }
    }

    public static func parseBindings(_ json: Any) -> [[String: String]] {
        guard let dict = json as? [String: Any], let results = dict["results"] as? [String: Any],
              let bindings = results["bindings"] as? [[String: Any]] else { return [] }
        return bindings.map { b in
            var row: [String: String] = [:]
            for (k, v) in b { if let v = v as? [String: Any], let value = v["value"] as? String { row[k] = value } }
            return row
        }
    }

    public static func parsePerson(qid: String, rows: [[String: String]]) -> WikidataPersonRecord? {
        guard let first = rows.first, let label = first["label"] else { return nil }
        var rec = WikidataPersonRecord(qid: qid, label: label)
        rec.description = first["description"]
        rec.isHuman = first["human"] == "true" || first["human"] == "1"
        func unique(_ key: String) -> [String] {
            var seen = Set<String>(); return rows.compactMap { $0[key] }.filter { seen.insert($0).inserted }
        }
        rec.birth = unique("birth").first.flatMap(HistoricalDate.parse)
        rec.death = unique("death").first.flatMap(HistoricalDate.parse)
        rec.birthPlace = unique("birthPlaceLabel").first
        rec.deathPlace = unique("deathPlaceLabel").first
        switch unique("sex").first.flatMap(qid(fromURI:)) {
        case "Q6581097"?, "Q2449503"?: rec.sex = .male
        case "Q6581072"?, "Q1052281"?: rec.sex = .female
        case nil: rec.sex = .unknown
        default: rec.sex = .other
        }
        rec.occupations = unique("occupationLabel")
        rec.countries = unique("countryLabel")
        rec.imageURL = unique("image").first
        rec.youtubeChannelIDs = unique("yt")
        rec.wikipediaTitle = unique("article").first.flatMap { $0.components(separatedBy: "/wiki/").last?.removingPercentEncoding }
        return rec
    }

    public static func parseRelations(_ rows: [[String: String]]) -> [WikidataRelationStatement] {
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let prop = row["prop"], let rel = row["rel"].flatMap(qid(fromURI:)) else { return nil }
            let key = "\(prop)|\(rel)|\(row["start"] ?? "")"
            guard seen.insert(key).inserted else { return nil }
            return WikidataRelationStatement(property: prop, relatedQID: rel, relatedLabel: row["relLabel"] ?? rel,
                                             relatedDescription: row["relDescription"],
                                             start: HistoricalDate.parse(row["start"]), end: HistoricalDate.parse(row["end"]))
        }
    }

    public static func parseCredits(_ rows: [[String: String]]) -> [WikidataCredit] {
        var seen = Set<String>()
        var minYear: [String: Int] = [:]
        for r in rows { if let w = r["work"], let y = r["year"].flatMap(Int.init) { minYear[w] = min(minYear[w] ?? y, y) } }
        return rows.compactMap { r in
            guard let workURI = r["work"], let work = qid(fromURI: workURI), let person = r["person"].flatMap(qid(fromURI:)),
                  let role = r["role"] else { return nil }
            guard seen.insert("\(work)|\(person)|\(role)").inserted else { return nil }
            return WikidataCredit(workQID: work, workTitle: r["workLabel"] ?? work, year: minYear[workURI],
                                  isSeries: r["isSeries"] == "true" || r["isSeries"] == "1",
                                  personQID: person, personLabel: r["personLabel"] ?? person, role: role)
        }
    }

    /// Maps Wikidata occupation labels to person categories.
    public static func categories(occupations: [String], description: String?, birthYear: Int?, deathYear: Int?) -> Set<PersonCategory> {
        let text = (occupations + [description ?? ""]).joined(separator: " | ").lowercased()
        var out: Set<PersonCategory> = []
        let rules: [(String, PersonCategory)] = [
            ("actor", .actor), ("actress", .actor), ("singer", .musician), ("musician", .musician), ("rapper", .musician),
            ("composer", .musician), ("film director", .director), ("television director", .director),
            ("film producer", .filmProducer), ("television producer", .filmProducer), ("youtuber", .youtuber),
            ("vlogger", .youtuber), ("streamer", .twitchStreamer), ("twitch", .twitchStreamer), ("tiktok", .tiktokCreator),
            ("instagram", .instagramCreator), ("television presenter", .televisionPersonality), ("tv personality", .televisionPersonality),
            ("television personality", .televisionPersonality), ("athlete", .athlete), ("player", .athlete), ("footballer", .athlete),
            ("scientist", .scientist), ("physicist", .scientist), ("chemist", .scientist), ("mathematician", .scientist),
            ("biologist", .scientist), ("astronomer", .scientist), ("writer", .author), ("novelist", .author), ("poet", .author),
            ("author", .author), ("politician", .politicalOrRoyal), ("monarch", .politicalOrRoyal), ("king", .politicalOrRoyal),
            ("queen", .politicalOrRoyal), ("prince", .politicalOrRoyal), ("princess", .politicalOrRoyal), ("emperor", .politicalOrRoyal),
            ("minecraft", .minecraftCreator),
        ]
        for (needle, cat) in rules where text.contains(needle) { out.insert(cat) }
        if let d = deathYear, d < 1950 { out.insert(.historicalFigure) }
        else if deathYear == nil, let b = birthYear, b < 1880 { out.insert(.historicalFigure) }
        if out.isEmpty { out.insert(.publicFigure) }
        return out
    }
}

/// Fetches public article summaries from the Wikipedia REST API (CC BY-SA text).
public struct WikipediaConnector: Sendable {
    public let http: ResearchHTTP
    public init(http: ResearchHTTP) { self.http = http }

    public struct Summary: Sendable { public let title: String; public let extract: String; public let url: String }

    public func summary(title: String) async throws -> Summary? {
        let encoded = title.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
        guard let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)") else { return nil }
        guard let json = try await http.getJSON(url) as? [String: Any], let extract = json["extract"] as? String else { return nil }
        let page = ((json["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String
        return Summary(title: json["title"] as? String ?? title, extract: extract, url: page ?? "https://en.wikipedia.org/wiki/\(encoded)")
    }
}
