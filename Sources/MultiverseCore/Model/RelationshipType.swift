import Foundation

/// Broad relationship families. Used for filtering, path classes and glow colours.
public enum RelationshipCategory: String, CaseIterable, Codable, Sendable, Hashable {
    case family
    case creator
    case entertainment
    case historical
    case social

    public var displayName: String { rawValue.capitalized }
}

/// Every supported connection type. Raw values are persisted in SQLite, so never
/// rename an existing case's raw value — add a migration instead.
public enum RelationshipType: String, CaseIterable, Codable, Sendable, Hashable {
    // FAMILY — `parent` is stored canonically as (parent → child).
    case parent
    case sibling
    case halfSibling
    case grandparent
    case auntUncle
    case cousin
    case sharedAncestor
    case spouse
    case formerSpouse
    case inLaw
    case adoptiveParent
    case otherKinship

    // CREATOR
    case videoCollaboration
    case sharedVideo
    case sharedLivestream
    case creatorFriendship
    case sameMinecraftSMP
    case sameCreatorOrganization
    case featuredInVideo
    case channelMention
    case creatorPartnership
    case sharedEventAppearance

    // ENTERTAINMENT
    case sameFilm
    case sameTelevisionSeries
    case sameProduction
    case sameMusicProject
    case sameFranchise
    case directorActor
    case producerActor
    case sharedEntertainmentOrganization

    // HISTORICAL
    case historicalFamily
    case sharedHistoricalEvent
    case teacherStudent
    case politicalAlliance
    case correspondence
    case sameInstitution

    // SOCIAL
    case publicFriendship
    case confirmedCollaboration
    case sharedCommunity
    case sharedPublicEvent
    case publicAssociation

    public var category: RelationshipCategory {
        switch self {
        case .parent, .sibling, .halfSibling, .grandparent, .auntUncle, .cousin, .sharedAncestor,
             .spouse, .formerSpouse, .inLaw, .adoptiveParent, .otherKinship:
            return .family
        case .videoCollaboration, .sharedVideo, .sharedLivestream, .creatorFriendship, .sameMinecraftSMP,
             .sameCreatorOrganization, .featuredInVideo, .channelMention, .creatorPartnership, .sharedEventAppearance:
            return .creator
        case .sameFilm, .sameTelevisionSeries, .sameProduction, .sameMusicProject, .sameFranchise,
             .directorActor, .producerActor, .sharedEntertainmentOrganization:
            return .entertainment
        case .historicalFamily, .sharedHistoricalEvent, .teacherStudent, .politicalAlliance,
             .correspondence, .sameInstitution:
            return .historical
        case .publicFriendship, .confirmedCollaboration, .sharedCommunity, .sharedPublicEvent, .publicAssociation:
            return .social
        }
    }

    /// Directed types have a meaningful from → to orientation.
    public var isDirected: Bool {
        switch self {
        case .parent, .grandparent, .auntUncle, .adoptiveParent, .featuredInVideo, .channelMention,
             .directorActor, .producerActor, .teacherStudent:
            return true
        default:
            return false
        }
    }

    /// Types that describe genealogical descent (used by ancestor search and kinship maths).
    public var isDescent: Bool { self == .parent || self == .adoptiveParent }

    /// Whether this counts as a "collaboration" for the collaboration-only path class.
    public var isCollaboration: Bool {
        switch category {
        case .creator, .entertainment: return self != .channelMention
        case .social: return self == .confirmedCollaboration
        default: return false
        }
    }

    /// Weak types are mentions/associations that must never be promoted to friendship or kinship.
    public var isWeakAssociation: Bool {
        switch self {
        case .channelMention, .featuredInVideo, .publicAssociation, .sharedCommunity, .sharedPublicEvent,
             .sharedEventAppearance:
            return true
        default:
            return false
        }
    }

    /// Human label read from `from`'s perspective, e.g. "parent of".
    public var forwardLabel: String {
        switch self {
        case .parent: return "parent of"
        case .adoptiveParent: return "adoptive parent of"
        case .grandparent: return "grandparent of"
        case .auntUncle: return "aunt/uncle of"
        case .featuredInVideo: return "featured"
        case .channelMention: return "mentioned"
        case .directorActor: return "directed"
        case .producerActor: return "produced work featuring"
        case .teacherStudent: return "teacher of"
        default: return displayName.lowercased()
        }
    }

    /// Label read from `to`'s perspective, e.g. "child of".
    public var reverseLabel: String {
        switch self {
        case .parent: return "child of"
        case .adoptiveParent: return "adopted child of"
        case .grandparent: return "grandchild of"
        case .auntUncle: return "niece/nephew of"
        case .featuredInVideo: return "featured by"
        case .channelMention: return "mentioned by"
        case .directorActor: return "directed by"
        case .producerActor: return "in a production by"
        case .teacherStudent: return "student of"
        default: return displayName.lowercased()
        }
    }

    public var displayName: String {
        switch self {
        case .parent: return "Parent"
        case .sibling: return "Sibling"
        case .halfSibling: return "Half-sibling"
        case .grandparent: return "Grandparent"
        case .auntUncle: return "Aunt/Uncle"
        case .cousin: return "Cousin"
        case .sharedAncestor: return "Shared ancestor"
        case .spouse: return "Spouse"
        case .formerSpouse: return "Former spouse"
        case .inLaw: return "In-law"
        case .adoptiveParent: return "Adoptive parent"
        case .otherKinship: return "Other verified kinship"
        case .videoCollaboration: return "Video collaboration"
        case .sharedVideo: return "Shared YouTube video"
        case .sharedLivestream: return "Shared livestream"
        case .creatorFriendship: return "Documented creator friendship"
        case .sameMinecraftSMP: return "Same Minecraft SMP"
        case .sameCreatorOrganization: return "Same creator organization"
        case .featuredInVideo: return "Featured in video"
        case .channelMention: return "Channel mention"
        case .creatorPartnership: return "Creator partnership"
        case .sharedEventAppearance: return "Shared event appearance"
        case .sameFilm: return "Same film"
        case .sameTelevisionSeries: return "Same television series"
        case .sameProduction: return "Same production"
        case .sameMusicProject: return "Same music project"
        case .sameFranchise: return "Same franchise"
        case .directorActor: return "Director / actor"
        case .producerActor: return "Producer / actor"
        case .sharedEntertainmentOrganization: return "Shared entertainment organization"
        case .historicalFamily: return "Documented historical family"
        case .sharedHistoricalEvent: return "Shared historical event"
        case .teacherStudent: return "Teacher / student"
        case .politicalAlliance: return "Political alliance"
        case .correspondence: return "Documented correspondence"
        case .sameInstitution: return "Same institution"
        case .publicFriendship: return "Publicly documented friendship"
        case .confirmedCollaboration: return "Confirmed collaboration"
        case .sharedCommunity: return "Shared community"
        case .sharedPublicEvent: return "Shared public event"
        case .publicAssociation: return "Publicly documented association"
        }
    }
}

/// Verification lifecycle of a relationship.
public enum VerificationStatus: String, CaseIterable, Codable, Sendable, Hashable {
    /// Confirmed by the source-verification agent against at least one reliable source, or approved by the user.
    case verified
    /// Comes directly from a structured, cited source (e.g. a Wikidata statement) but has not been cross-checked.
    case sourced
    /// Asserted by the user or by a document they imported (GEDCOM, CSV).
    case userAsserted
    /// Extracted automatically and awaiting review. Never shown as established.
    case candidate
    /// Conflicting evidence exists.
    case disputed
    /// Rejected by the user or by verification. Kept for provenance; excluded from paths.
    case rejected

    /// Whether a relationship in this state may be shown as an established connection.
    public var isEstablished: Bool {
        switch self {
        case .verified, .sourced, .userAsserted: return true
        case .candidate, .disputed, .rejected: return false
        }
    }

    public var displayName: String {
        switch self {
        case .verified: return "Verified"
        case .sourced: return "Sourced"
        case .userAsserted: return "User-provided"
        case .candidate: return "Possible connection — research required"
        case .disputed: return "Disputed"
        case .rejected: return "Rejected"
        }
    }
}
