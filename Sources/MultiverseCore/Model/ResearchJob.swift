import Foundation

public enum ResearchJobKind: String, Codable, Sendable, CaseIterable {
    /// Look up a person on Wikidata by name and import the chosen entity.
    case wikidataSearch
    /// Import a known Wikidata entity (QID) and its documented relationships.
    case wikidataEntity
    /// Import film/TV co-star network for a person with a Wikidata QID.
    case wikidataFilmography
    /// Fetch YouTube channel metadata (official API, user-supplied key).
    case youtubeChannel
    /// Scan recent uploads of a channel for collaboration candidates.
    case youtubeUploads
    /// Refresh `last_checked` and re-verify an existing relationship.
    case reverify
    /// Run duplicate detection over the graph.
    case duplicateScan
}

public enum ResearchJobStatus: String, Codable, Sendable, CaseIterable {
    case queued, running, paused, waitingForApproval, completed, failed, cancelled
    public var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
}

public struct ResearchJob: Codable, Sendable, Hashable, Identifiable {
    public var id: EntityID
    public var kind: ResearchJobKind
    /// Target of the job: a name, QID, channel ID or person ID depending on `kind`.
    public var target: String
    public var personID: EntityID?
    public var status: ResearchJobStatus
    public var priority: Int
    public var progress: Double
    /// Opaque resume state so an interrupted job continues where it stopped.
    public var cursor: String?
    public var attempts: Int
    public var lastError: String?
    public var createdAt: Date
    public var scheduledFor: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    /// Recurring refresh interval in seconds (nil = one-shot).
    public var refreshInterval: TimeInterval?

    public init(id: EntityID = IDGen.make(), kind: ResearchJobKind, target: String, personID: EntityID? = nil,
                status: ResearchJobStatus = .queued, priority: Int = 0, progress: Double = 0, cursor: String? = nil,
                attempts: Int = 0, lastError: String? = nil, createdAt: Date = Date(), scheduledFor: Date = Date(),
                startedAt: Date? = nil, finishedAt: Date? = nil, refreshInterval: TimeInterval? = nil) {
        self.id = id; self.kind = kind; self.target = target; self.personID = personID; self.status = status
        self.priority = priority; self.progress = progress; self.cursor = cursor; self.attempts = attempts
        self.lastError = lastError; self.createdAt = createdAt; self.scheduledFor = scheduledFor
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.refreshInterval = refreshInterval
    }

    /// Deduplication key — the scheduler refuses to queue a second live job with the same key.
    public var dedupKey: String { "\(kind.rawValue):\(target.lowercased())" }
}

public struct ResearchLogEntry: Codable, Sendable, Hashable {
    public enum Level: String, Codable, Sendable { case info, source, discovery, rejected, warning, error }
    public var jobID: EntityID
    public var at: Date
    public var level: Level
    public var message: String
    public init(jobID: EntityID, at: Date = Date(), level: Level, message: String) {
        self.jobID = jobID; self.at = at; self.level = level; self.message = message
    }
}
