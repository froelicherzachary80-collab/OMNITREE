import Foundation

/// Identity Resolution Agent: maps external identifiers to persistent person IDs.
/// It resolves strictly by external identifier, never by name — two people with the same
/// name always remain separate records until the merge engine and the user say otherwise.
public struct IdentityResolver: Sendable {
    public let store: GraphStore
    public init(store: GraphStore) { self.store = store }

    /// Returns the existing person for (scheme, value), or creates a stub with the given template.
    public func resolveOrCreate(scheme: IdentityScheme, value: String, url: String?, template: () -> Person) throws -> (Person, created: Bool) {
        if let id = try store.personID(scheme: scheme, value: value), let p = try store.person(id) { return (p, false) }
        let p = try store.upsert(template())
        try store.addIdentity(Identity(personID: p.id, scheme: scheme, value: value, url: url))
        return (p, true)
    }
}

/// Celebrity / Historical / Genealogy research against Wikidata + Wikipedia.
/// Every edge it writes cites the exact Wikidata statement it came from.
public struct WikidataResearchAgent: Sendable {
    public let store: GraphStore
    public let wikidata: WikidataConnector
    public let wikipedia: WikipediaConnector
    private var resolver: IdentityResolver { IdentityResolver(store: store) }

    public init(store: GraphStore, http: ResearchHTTP) {
        self.store = store
        self.wikidata = WikidataConnector(http: http)
        self.wikipedia = WikipediaConnector(http: http)
    }

    private func stub(qid: String, label: String, description: String?) -> Person {
        Person(displayName: label, aliases: [], categories: WikidataConnector.categories(occupations: [], description: description, birthYear: nil, deathYear: nil),
               biography: description, origin: .wikidata)
    }

    /// Imports (or refreshes) a person by QID, including their documented relationships.
    @discardableResult
    public func importPerson(qid: String, includeRelations: Bool = true, onEvent: ResearchEventHandler? = nil) async throws -> (EntityID?, ResearchReport) {
        var report = ResearchReport(title: "Wikidata \(qid)")
        onEvent?(.progress(0.05, "Fetching Wikidata entity \(qid)"))
        guard let rec = try await wikidata.fetchPerson(qid) else {
            report.unansweredQuestions.append("Wikidata returned no entity for \(qid).")
            return (nil, report)
        }
        report.sourcesInspected.append(WikidataConnector.entityURL(qid))
        onEvent?(.inspectedSource(WikidataConnector.entityURL(qid)))
        guard rec.isHuman else {
            report.rejectedClaims.append("\(rec.label) (\(qid)) is not an individual human on Wikidata; not added as a person.")
            onEvent?(.rejected(report.rejectedClaims.last!))
            return (nil, report)
        }

        var (person, created) = try resolver.resolveOrCreate(scheme: .wikidata, value: qid, url: WikidataConnector.entityURL(qid)) {
            stub(qid: qid, label: rec.label, description: rec.description)
        }
        if person.excludeFromResearch {
            report.rejectedClaims.append("\(person.displayName) is excluded from research by your privacy settings.")
            return (person.id, report)
        }
        person.displayName = rec.label
        person.birth = rec.birth ?? person.birth
        person.death = rec.death ?? person.death
        person.birthPlace = rec.birthPlace ?? person.birthPlace
        person.deathPlace = rec.deathPlace ?? person.deathPlace
        person.sex = rec.sex == .unknown ? person.sex : rec.sex
        person.occupation = rec.occupations.prefix(4).joined(separator: ", ").nilIfEmpty ?? person.occupation
        person.country = rec.countries.first ?? person.country
        person.isLiving = rec.death == nil ? person.isLiving : false
        person.categories.formUnion(WikidataConnector.categories(occupations: rec.occupations, description: rec.description,
                                                                 birthYear: rec.birth?.year, deathYear: rec.death?.year))
        if person.categories.count > 1 { person.categories.remove(.publicFigure) }
        if let img = rec.imageURL {
            // Wikimedia Commons images carry free licences; the Commons file page has the exact licence.
            person.imageURL = img.replacingOccurrences(of: "http://", with: "https://") + "?width=512"
            person.imageLicense = "Wikimedia Commons (see file page for licence)"
        }
        if let title = rec.wikipediaTitle, let summary = try? await wikipedia.summary(title: title) {
            person.biography = summary.extract
            report.sourcesInspected.append(summary.url)
            onEvent?(.inspectedSource(summary.url))
        } else if person.biography == nil {
            person.biography = rec.description
        }
        try store.upsert(person)
        if created { report.peopleAdded.append(person.id); onEvent?(.newPerson(person.id)) } else { report.peopleUpdated.append(person.id) }

        for channel in rec.youtubeChannelIDs {
            try store.addIdentity(Identity(personID: person.id, scheme: .youtubeChannel, value: channel,
                                           url: "https://www.youtube.com/channel/\(channel)"))
            try store.addPlatformAccount(PlatformAccount(personID: person.id, platform: "youtube", externalID: channel,
                                                         url: "https://www.youtube.com/channel/\(channel)"))
            person.categories.insert(.youtuber)
        }
        if !rec.youtubeChannelIDs.isEmpty { try store.upsert(person) }

        if includeRelations {
            onEvent?(.progress(0.4, "Reading documented relationships of \(rec.label)"))
            report.merge(try await importRelations(of: person, qid: qid, onEvent: onEvent))
        }
        onEvent?(.progress(1, "Finished \(rec.label)"))
        return (person.id, report)
    }

    /// Imports family / teacher relationships stated on the person's Wikidata item.
    public func importRelations(of person: Person, qid: String, onEvent: ResearchEventHandler? = nil) async throws -> ResearchReport {
        var report = ResearchReport(title: "Relations of \(person.displayName)")
        let statements = try await wikidata.fetchRelations(qid)
        for st in statements {
            guard let mapping = WikidataConnector.relationProperties[st.property] else { continue }
            let (other, created) = try resolver.resolveOrCreate(scheme: .wikidata, value: st.relatedQID,
                                                                url: WikidataConnector.entityURL(st.relatedQID)) {
                stub(qid: st.relatedQID, label: st.relatedLabel, description: st.relatedDescription)
            }
            if created { report.peopleAdded.append(other.id); onEvent?(.newPerson(other.id)) }
            var type = mapping.type
            if type == .spouse && st.end != nil { type = .formerSpouse }
            let (from, to) = mapping.subjectIsFrom ? (person.id, other.id) : (other.id, person.id)
            let sourceURL = "\(WikidataConnector.entityURL(qid))#\(st.property)"
            let source = try store.addSource(Source(kind: .wikidata, title: "Wikidata: \(person.displayName) (\(qid)) — \(mapping.label)",
                                                    url: sourceURL, publisher: "Wikidata", license: "CC0",
                                                    reliability: Source.defaultReliability(.wikidata)))
            let rel = try store.addRelationship(
                Relationship(fromID: from, toID: to, type: type, verification: .sourced, confidence: mapping.confidence,
                             startDate: st.start, endDate: st.end, provenance: "WikidataResearchAgent \(qid) \(st.property)"),
                evidence: [EvidenceInput(sourceID: source.id,
                                         description: "Wikidata item \(qid) states \(mapping.label) (\(st.property)): \(st.relatedLabel) (\(st.relatedQID)).",
                                         extractedBy: "WikidataResearchAgent")])
            let d = ResearchReport.Discovery(relationshipID: rel.id, summary: "\(person.displayName) — \(mapping.label) — \(st.relatedLabel)",
                                             status: rel.verification, sourceURL: sourceURL)
            report.discoveries.append(d)
            onEvent?(.discovered(d))
        }
        report.sourcesInspected.append("\(WikidataConnector.entityURL(qid)) (relationship statements)")
        if statements.isEmpty { report.unansweredQuestions.append("No documented family or teacher relationships on Wikidata for \(person.displayName).") }
        return report
    }

    /// Imports a film/TV co-credit network: one `sameFilm`/`sameTelevisionSeries`/`directorActor`/`producerActor`
    /// edge per shared work, each citing that work's Wikidata item.
    public func importFilmography(of personID: EntityID, maxWorks: Int = 25, maxCoStarsPerWork: Int = 12,
                                  onEvent: ResearchEventHandler? = nil) async throws -> ResearchReport {
        guard let person = try store.person(personID) else { throw GraphStoreError.personNotFound(personID) }
        var report = ResearchReport(title: "Filmography of \(person.displayName)")
        guard let qid = try store.identities(of: personID).first(where: { $0.scheme == .wikidata })?.value else {
            report.unansweredQuestions.append("\(person.displayName) has no Wikidata identifier; link one before researching credits.")
            return report
        }
        guard !person.excludeFromResearch else {
            report.rejectedClaims.append("\(person.displayName) is excluded from research.")
            return report
        }
        onEvent?(.progress(0.1, "Querying film and television credits for \(person.displayName)"))
        let credits = try await wikidata.fetchCoCredits(qid, maxWorks: maxWorks)
        let byWork = Dictionary(grouping: credits, by: \.workQID)
        var done = 0
        for (workQID, rows) in byWork.sorted(by: { ($0.value.first?.year ?? 0) > ($1.value.first?.year ?? 0) }) {
            done += 1
            onEvent?(.progress(0.1 + 0.9 * Double(done) / Double(max(1, byWork.count)), rows.first?.workTitle ?? workQID))
            guard let first = rows.first else { continue }
            let project = try store.upsertProject(MediaProject(title: first.workTitle, kind: first.isSeries ? "tvSeries" : "film",
                                                               year: first.year, wikidataQID: workQID, url: WikidataConnector.entityURL(workQID)))
            try store.addCredit(MediaCredit(projectID: project.id, personID: personID, role: "cast"))
            let source = try store.addSource(Source(kind: .wikidata, title: "Wikidata: \(first.workTitle) (\(workQID)) — credits",
                                                    url: WikidataConnector.entityURL(workQID), publisher: "Wikidata", license: "CC0",
                                                    reliability: Source.defaultReliability(.wikidata)))
            report.sourcesInspected.append(WikidataConnector.entityURL(workQID))
            // Directors and producers first, then cast up to the cap.
            let ordered = rows.filter { $0.personQID != qid }.sorted { ($0.role == "cast" ? 1 : 0) < ($1.role == "cast" ? 1 : 0) }
            var castCount = 0
            for credit in ordered {
                if credit.role == "cast" { castCount += 1; if castCount > maxCoStarsPerWork { continue } }
                let (other, created) = try resolver.resolveOrCreate(scheme: .wikidata, value: credit.personQID,
                                                                    url: WikidataConnector.entityURL(credit.personQID)) {
                    var p = stub(qid: credit.personQID, label: credit.personLabel, description: nil)
                    p.categories = [credit.role == "director" ? .director : credit.role == "producer" ? .filmProducer : .actor]
                    return p
                }
                if created { report.peopleAdded.append(other.id); onEvent?(.newPerson(other.id)) }
                try store.addCredit(MediaCredit(projectID: project.id, personID: other.id, role: credit.role))
                let type: RelationshipType
                let from: EntityID, to: EntityID
                switch credit.role {
                case "director": type = .directorActor; from = other.id; to = personID
                case "producer": type = .producerActor; from = other.id; to = personID
                default: type = first.isSeries ? .sameTelevisionSeries : .sameFilm; from = personID; to = other.id
                }
                let roleText = credit.role == "cast" ? "are both credited as cast members of" : "is credited as \(credit.role) of"
                let rel = try store.addRelationship(
                    Relationship(fromID: from, toID: to, type: type, verification: .sourced, confidence: 0.9,
                                 startDate: first.year.map { HistoricalDate(year: $0) }, provenance: "WikidataResearchAgent filmography \(qid)",
                                 contextProjectID: project.id, contextLabel: first.workTitle),
                    evidence: [EvidenceInput(sourceID: source.id,
                                             description: credit.role == "cast"
                                                ? "\(person.displayName) and \(credit.personLabel) \(roleText) \(first.workTitle) (\(workQID))."
                                                : "\(credit.personLabel) \(roleText) \(first.workTitle) (\(workQID)), in which \(person.displayName) is credited as cast.",
                                             extractedBy: "WikidataResearchAgent")])
                let d = ResearchReport.Discovery(relationshipID: rel.id,
                                                 summary: "\(person.displayName) ↔ \(credit.personLabel) via \(first.workTitle)",
                                                 status: rel.verification, sourceURL: WikidataConnector.entityURL(workQID))
                report.discoveries.append(d)
                onEvent?(.discovered(d))
            }
        }
        if credits.isEmpty { report.unansweredQuestions.append("Wikidata lists no film or TV cast credits for \(person.displayName).") }
        return report
    }

    /// Imports the documented members of a group item (e.g. a creator collective or institution) as a community.
    public func importGroup(qid: String, kind: String, onEvent: ResearchEventHandler? = nil) async throws -> ResearchReport {
        var report = ResearchReport(title: "Group \(qid)")
        let members = try await wikidata.fetchMembers(ofGroup: qid)
        let groupName = try await wikidata.search(qid, limit: 1).first?.label ?? qid
        let community = try store.upsertCommunity(Community(name: groupName, kind: kind, wikidataQID: qid))
        let source = try store.addSource(Source(kind: .wikidata, title: "Wikidata: \(groupName) (\(qid)) — members",
                                                url: WikidataConnector.entityURL(qid), publisher: "Wikidata", license: "CC0",
                                                reliability: Source.defaultReliability(.wikidata)))
        report.sourcesInspected.append(WikidataConnector.entityURL(qid))
        var ids: [EntityID] = []
        for m in members {
            let (p, created) = try resolver.resolveOrCreate(scheme: .wikidata, value: m.qid, url: WikidataConnector.entityURL(m.qid)) {
                stub(qid: m.qid, label: m.label, description: m.description)
            }
            if created { report.peopleAdded.append(p.id); onEvent?(.newPerson(p.id)) }
            try store.addMember(communityID: community.id, personID: p.id, sourceID: source.id)
            ids.append(p.id)
        }
        let type: RelationshipType = kind == "minecraftSMP" ? .sameMinecraftSMP : kind == "creatorGroup" ? .sameCreatorOrganization
            : kind == "institution" ? .sameInstitution : .sharedCommunity
        // Pairwise membership edges are only created for small groups to avoid quadratic blow-up;
        // large groups are represented by the community record itself.
        if ids.count <= 40 {
            for i in 0..<ids.count {
                for j in (i + 1)..<ids.count {
                    let rel = try store.addRelationship(
                        Relationship(fromID: ids[i], toID: ids[j], type: type, verification: .sourced, confidence: 0.8,
                                     provenance: "WikidataResearchAgent group \(qid)", contextLabel: groupName),
                        evidence: [EvidenceInput(sourceID: source.id, description: "Both are listed as members of \(groupName) (\(qid)) on Wikidata.",
                                                 extractedBy: "WikidataResearchAgent")])
                    report.discoveries.append(.init(relationshipID: rel.id, summary: "Members of \(groupName)", status: rel.verification,
                                                    sourceURL: WikidataConnector.entityURL(qid)))
                }
            }
        }
        return report
    }
}

/// Source Verification Agent: promotes edges with corroborating evidence and flags conflicts.
public struct SourceVerificationAgent: Sendable {
    public let store: GraphStore
    public init(store: GraphStore) { self.store = store }

    /// An edge becomes `verified` when backed by independent sources of at least two different kinds,
    /// each with reliability ≥ 0.7. User-asserted or candidate edges are never auto-promoted from a single source.
    @discardableResult
    public func reverify(_ relationshipID: EntityID) throws -> VerificationStatus? {
        guard let rel = try store.relationship(relationshipID) else { return nil }
        guard rel.verification != .rejected else { return .rejected }
        let ev = try store.evidence(for: relationshipID)
        let strongKinds = Set(ev.filter { $0.1.reliability >= 0.7 }.map { $0.1.kind })
        if strongKinds.count >= 2 && rel.verification != .verified {
            try store.setVerification(relationshipID, .verified)
            return .verified
        }
        try store.db.run("UPDATE relationship SET last_checked = ? WHERE id = ?", Date(), relationshipID)
        return rel.verification
    }

    /// User approves a candidate from the manual approval queue.
    public func approve(_ relationshipID: EntityID, note: String = "Approved by user after review") throws {
        let source = try store.addSource(Source(kind: .userEntry, title: "User review", documentRef: "review:\(relationshipID)",
                                                reliability: Source.defaultReliability(.userEntry)))
        if let rel = try store.relationship(relationshipID) {
            try store.addRelationship(rel, evidence: [EvidenceInput(sourceID: source.id, description: note, extractedBy: "user")])
        }
        try store.setVerification(relationshipID, .verified)
    }

    public func reject(_ relationshipID: EntityID) throws { try store.setVerification(relationshipID, .rejected) }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
