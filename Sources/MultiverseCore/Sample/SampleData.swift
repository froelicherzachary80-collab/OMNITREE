import Foundation

/// SAMPLE DATA — every person below is FICTIONAL and flagged `isSample = true`.
/// It exists only so the universe, pathfinder and genealogy tools can be explored before
/// importing real data. It never mixes with research results (all sample people are
/// excluded from research), and Settings → Data → "Remove sample data" deletes it.
public enum SampleData {
    public static let sourceRef = "sample://multiverse-tree/v0.1"

    struct P { let key: String; let name: String; let cats: Set<PersonCategory>; let birth: Int?; let death: Int?; let sex: Sex; let bio: String }
    struct R { let a: String; let b: String; let type: RelationshipType; let context: String?; let year: Int? }

    static let people: [P] = [
        // Fictional family tree (the "you" profile is sample too)
        .init(key: "you", name: "Sample Explorer", cats: [.familyMember], birth: 2001, death: nil, sex: .unknown, bio: "Sample profile standing in for you."),
        .init(key: "mom", name: "Lyra Vale (sample)", cats: [.familyMember], birth: 1972, death: nil, sex: .female, bio: "Fictional parent."),
        .init(key: "dad", name: "Orin Vale (sample)", cats: [.familyMember], birth: 1970, death: nil, sex: .male, bio: "Fictional parent."),
        .init(key: "gma", name: "Selene Marsh (sample)", cats: [.familyMember], birth: 1945, death: 2019, sex: .female, bio: "Fictional grandparent."),
        .init(key: "gpa", name: "Caspian Marsh (sample)", cats: [.familyMember], birth: 1941, death: 2010, sex: .male, bio: "Fictional grandparent."),
        .init(key: "aunt", name: "Mira Marsh (sample)", cats: [.familyMember], birth: 1975, death: nil, sex: .female, bio: "Fictional aunt."),
        .init(key: "cousin", name: "Juniper Marsh (sample)", cats: [.familyMember, .youtuber, .minecraftCreator], birth: 2003, death: nil, sex: .female,
              bio: "Fictional cousin who makes Minecraft videos."),
        .init(key: "ggpa", name: "Aldous Marsh (sample)", cats: [.familyMember, .historicalFigure], birth: 1902, death: 1978, sex: .male,
              bio: "Fictional great-grandparent, a lighthouse keeper."),
        .init(key: "friend1", name: "Kai Rivers (sample)", cats: [.friend], birth: 2000, death: nil, sex: .unknown, bio: "Fictional friend."),
        .init(key: "friend2", name: "Noor Haddad (sample)", cats: [.friend], birth: 2002, death: nil, sex: .unknown, bio: "Fictional friend."),
        // Fictional creator community
        .init(key: "c1", name: "PixelWarden (sample)", cats: [.youtuber, .minecraftCreator], birth: 1995, death: nil, sex: .unknown, bio: "Fictional Minecraft creator."),
        .init(key: "c2", name: "RedstoneRook (sample)", cats: [.youtuber, .minecraftCreator, .twitchStreamer], birth: 1993, death: nil, sex: .unknown, bio: "Fictional Minecraft streamer."),
        .init(key: "c3", name: "LumaBuilds (sample)", cats: [.youtuber, .minecraftCreator], birth: 1998, death: nil, sex: .unknown, bio: "Fictional builder."),
        .init(key: "c4", name: "Vlog Nova (sample)", cats: [.youtuber], birth: 1990, death: nil, sex: .unknown, bio: "Fictional lifestyle YouTuber."),
        // Fictional entertainment
        .init(key: "a1", name: "Elara Quinn (sample)", cats: [.actor], birth: 1988, death: nil, sex: .female, bio: "Fictional actor."),
        .init(key: "a2", name: "Theo Marlowe (sample)", cats: [.actor, .musician], birth: 1979, death: nil, sex: .male, bio: "Fictional actor and musician."),
        .init(key: "d1", name: "Ines Calder (sample)", cats: [.director], birth: 1965, death: nil, sex: .female, bio: "Fictional director."),
        // Fictional history
        .init(key: "h1", name: "Professor Ansel Grey (sample)", cats: [.historicalFigure, .scientist], birth: 1840, death: 1911, sex: .male, bio: "Fictional 19th-century astronomer."),
        .init(key: "h2", name: "Odile Fenwick (sample)", cats: [.historicalFigure, .scientist], birth: 1868, death: 1940, sex: .female, bio: "Fictional astronomer, student of Grey."),
    ]

    static let relationships: [R] = [
        .init(a: "mom", b: "you", type: .parent, context: nil, year: nil),
        .init(a: "dad", b: "you", type: .parent, context: nil, year: nil),
        .init(a: "mom", b: "dad", type: .spouse, context: nil, year: 1998),
        .init(a: "gma", b: "mom", type: .parent, context: nil, year: nil),
        .init(a: "gpa", b: "mom", type: .parent, context: nil, year: nil),
        .init(a: "gma", b: "aunt", type: .parent, context: nil, year: nil),
        .init(a: "gpa", b: "aunt", type: .parent, context: nil, year: nil),
        .init(a: "gma", b: "gpa", type: .spouse, context: nil, year: 1966),
        .init(a: "aunt", b: "cousin", type: .parent, context: nil, year: nil),
        .init(a: "ggpa", b: "gpa", type: .parent, context: nil, year: nil),
        .init(a: "you", b: "friend1", type: .publicFriendship, context: nil, year: 2015),
        .init(a: "friend1", b: "friend2", type: .publicFriendship, context: nil, year: 2019),
        .init(a: "cousin", b: "c1", type: .sameMinecraftSMP, context: "Starlight SMP (sample)", year: 2023),
        .init(a: "c1", b: "c2", type: .sameMinecraftSMP, context: "Starlight SMP (sample)", year: 2022),
        .init(a: "c2", b: "c3", type: .videoCollaboration, context: "Sky Island Race (sample video)", year: 2024),
        .init(a: "c1", b: "c3", type: .sameMinecraftSMP, context: "Starlight SMP (sample)", year: 2022),
        .init(a: "c3", b: "c4", type: .sharedLivestream, context: "Charity Stream (sample)", year: 2024),
        .init(a: "c4", b: "a1", type: .sharedEventAppearance, context: "Fan Expo (sample)", year: 2024),
        .init(a: "a1", b: "a2", type: .sameFilm, context: "Nebula Run (sample film)", year: 2021),
        .init(a: "d1", b: "a1", type: .directorActor, context: "Nebula Run (sample film)", year: 2021),
        .init(a: "d1", b: "a2", type: .directorActor, context: "Nebula Run (sample film)", year: 2021),
        .init(a: "h1", b: "h2", type: .teacherStudent, context: "Northgate Observatory (sample)", year: 1890),
        .init(a: "h2", b: "ggpa", type: .correspondence, context: "Letters about the 1931 eclipse (sample)", year: 1931),
    ]

    /// Loads the sample universe. Returns the sample "you" person ID.
    @discardableResult
    public static func load(into store: GraphStore) throws -> EntityID {
        if let existing = try store.personID(scheme: .custom, value: "\(sourceRef)#you") { return existing }
        let source = try store.addSource(Source(kind: .userEntry, title: "Sample dataset (fictional people — not real records)",
                                                documentRef: sourceRef, publisher: "Multiverse Tree", license: "CC0", reliability: 0.6))
        var ids: [String: EntityID] = [:]
        try store.db.transaction {
            for p in people {
                let person = Person(displayName: p.name, categories: p.cats, sex: p.sex,
                                    birth: p.birth.map { HistoricalDate(year: $0) }, death: p.death.map { HistoricalDate(year: $0) },
                                    biography: "SAMPLE DATA — fictional. " + p.bio, excludeFromResearch: true,
                                    isLiving: p.death == nil, isSample: true, origin: .sample)
                try store.upsert(person)
                try store.addIdentity(Identity(personID: person.id, scheme: .custom, value: "\(sourceRef)#\(p.key)"))
                ids[p.key] = person.id
            }
            for r in relationships {
                try store.addRelationship(
                    Relationship(fromID: ids[r.a]!, toID: ids[r.b]!, type: r.type, verification: .userAsserted, confidence: 0.8,
                                 startDate: r.year.map { HistoricalDate(year: $0) }, provenance: "SampleData", contextLabel: r.context),
                    evidence: [EvidenceInput(sourceID: source.id, description: "Fictional sample relationship for demonstration.", extractedBy: "SampleData")])
            }
            // A deliberately unverified candidate, to demonstrate "Possible connection — research required".
            try store.addRelationship(
                Relationship(fromID: ids["h2"]!, toID: ids["a2"]!, type: .channelMention, verification: .candidate, confidence: 0.2,
                             provenance: "SampleData candidate", contextLabel: "Documentary narration (sample)"),
                evidence: [EvidenceInput(sourceID: source.id, description: "Fictional unverified mention — needs review.", extractedBy: "SampleData")])
            let smp = try store.upsertCommunity(Community(name: "Starlight SMP (sample)", kind: "minecraftSMP", summary: "Fictional Minecraft server."))
            for k in ["cousin", "c1", "c2", "c3"] { try store.addMember(communityID: smp.id, personID: ids[k]!, sourceID: source.id) }
        }
        return ids["you"]!
    }

    public static func remove(from store: GraphStore) throws -> Int {
        let n = try store.db.run("DELETE FROM person WHERE is_sample = 1")
        try store.db.run("DELETE FROM community WHERE name LIKE '%(sample)'")
        try store.db.run("DELETE FROM source WHERE document_ref = ?", sourceRef)
        return n
    }
}
