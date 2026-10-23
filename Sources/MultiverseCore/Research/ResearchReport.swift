import Foundation

/// Running account of what a research task did — surfaced verbatim in the "Ask Multiverse AI" panel.
public struct ResearchReport: Sendable {
    public struct Discovery: Sendable, Hashable {
        public let relationshipID: EntityID
        public let summary: String
        public let status: VerificationStatus
        public let sourceURL: String?
    }

    public var title: String
    public var sourcesInspected: [String] = []
    public var discoveries: [Discovery] = []
    public var rejectedClaims: [String] = []
    public var uncertainClaims: [String] = []
    public var peopleAdded: [EntityID] = []
    public var peopleUpdated: [EntityID] = []
    public var unansweredQuestions: [String] = []
    public var errors: [String] = []

    public init(title: String) { self.title = title }

    public mutating func merge(_ other: ResearchReport) {
        sourcesInspected += other.sourcesInspected.filter { !sourcesInspected.contains($0) }
        discoveries += other.discoveries
        rejectedClaims += other.rejectedClaims
        uncertainClaims += other.uncertainClaims
        peopleAdded += other.peopleAdded
        peopleUpdated += other.peopleUpdated
        unansweredQuestions += other.unansweredQuestions
        errors += other.errors
    }

    public var isEmpty: Bool { discoveries.isEmpty && peopleAdded.isEmpty && peopleUpdated.isEmpty }
}

/// Progress callbacks for UI.
public enum ResearchEvent: Sendable {
    case progress(Double, String)
    case inspectedSource(String)
    case discovered(ResearchReport.Discovery)
    case rejected(String)
    case newPerson(EntityID)
}

public typealias ResearchEventHandler = @Sendable (ResearchEvent) -> Void
