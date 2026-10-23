import Foundation

/// Categories a person can belong to. A person may hold several at once.
public enum PersonCategory: String, CaseIterable, Codable, Sendable, Hashable {
    case youtuber
    case twitchStreamer
    case tiktokCreator
    case instagramCreator
    case actor
    case musician
    case director
    case filmProducer
    case televisionPersonality
    case athlete
    case historicalFigure
    case scientist
    case author
    case politicalOrRoyal
    case minecraftCreator
    case familyMember
    case friend
    case userImported
    case publicFigure

    public var displayName: String {
        switch self {
        case .youtuber: return "YouTuber"
        case .twitchStreamer: return "Twitch Streamer"
        case .tiktokCreator: return "TikTok Creator"
        case .instagramCreator: return "Instagram Creator"
        case .actor: return "Actor"
        case .musician: return "Musician"
        case .director: return "Director"
        case .filmProducer: return "Film Producer"
        case .televisionPersonality: return "TV Personality"
        case .athlete: return "Athlete"
        case .historicalFigure: return "Historical Figure"
        case .scientist: return "Scientist"
        case .author: return "Author"
        case .politicalOrRoyal: return "Political / Royal"
        case .minecraftCreator: return "Minecraft Creator"
        case .familyMember: return "Family Member"
        case .friend: return "Friend"
        case .userImported: return "Imported"
        case .publicFigure: return "Public Figure"
        }
    }

    /// Whether people in this category are, by default, private individuals
    /// whose data must never become publicly searchable.
    public var isPrivateByDefault: Bool {
        switch self {
        case .familyMember, .friend, .userImported: return true
        default: return false
        }
    }
}

/// The eight exploration universes. Several can be enabled simultaneously; the
/// renderer shows the union of their member sets as one network.
public enum UniverseMode: String, CaseIterable, Codable, Sendable, Hashable {
    case entireMultiverse
    case youtube
    case minecraft
    case celebrity
    case historical
    case familyTree
    case friends
    case customResearch

    public var displayName: String {
        switch self {
        case .entireMultiverse: return "Entire Multiverse"
        case .youtube: return "YouTube Universe"
        case .minecraft: return "Minecraft Creator Universe"
        case .celebrity: return "Celebrity Universe"
        case .historical: return "Historical Universe"
        case .familyTree: return "Family Tree Universe"
        case .friends: return "Friends Universe"
        case .customResearch: return "Custom Research Universe"
        }
    }

    /// Person categories included by this mode. `nil` means "everything".
    public var categories: Set<PersonCategory>? {
        switch self {
        case .entireMultiverse, .customResearch: return nil
        case .youtube: return [.youtuber, .twitchStreamer, .tiktokCreator, .instagramCreator, .minecraftCreator]
        case .minecraft: return [.minecraftCreator]
        case .celebrity: return [.actor, .musician, .director, .filmProducer, .televisionPersonality, .athlete, .publicFigure]
        case .historical: return [.historicalFigure, .scientist, .author, .politicalOrRoyal]
        case .familyTree: return [.familyMember, .userImported]
        case .friends: return [.friend]
        }
    }
}
