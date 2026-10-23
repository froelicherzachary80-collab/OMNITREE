import Foundation

/// Describes what each research connector can and cannot access — rendered as the
/// source-availability dashboard.
public struct SourceConnectorInfo: Sendable, Identifiable {
    public enum Availability: String, Sendable { case available, needsKey, importOnly, planned }
    public let id: String
    public let name: String
    public let availability: Availability
    public let canAccess: String
    public let cannotAccess: String
    public let rateLimit: String
    public let license: String
}

public enum SourceRegistry {
    public static func connectors(youtubeKeyConfigured: Bool) -> [SourceConnectorInfo] {
        [
            .init(id: "wikidata", name: "Wikidata (SPARQL + API)", availability: .available,
                  canAccess: "People, dates, places, occupations, family statements (P22/P25/P26/P40/P3373/P1038), teacher/student, film & TV cast/director/producer credits, group membership.",
                  cannotAccess: "Anything not stated on Wikidata; private individuals.", rateLimit: "≈1 SPARQL query/s, cached 7 days", license: "CC0"),
            .init(id: "wikipedia", name: "Wikipedia REST", availability: .available,
                  canAccess: "Article summaries for public figures (biography text).", cannotAccess: "Full-text relationship extraction (planned v0.5).",
                  rateLimit: "≤4 req/s", license: "CC BY-SA 4.0 (attribution shown)"),
            .init(id: "youtube", name: "YouTube Data API v3", availability: youtubeKeyConfigured ? .available : .needsKey,
                  canAccess: "Channel metadata, upload lists, video titles & descriptions (mention / collaboration candidates).",
                  cannotAccess: "Video/audio content, private videos, transcripts not provided by you. No scraping.",
                  rateLimit: "10,000 free quota units/day (channels=1, search=100)", license: "YouTube API Terms of Service"),
            .init(id: "gedcom", name: "GEDCOM files", availability: .importOnly,
                  canAccess: "Your exported family trees (any genealogy program).", cannotAccess: "—", rateLimit: "Local", license: "Your data"),
            .init(id: "familysearch", name: "FamilySearch", availability: .importOnly,
                  canAccess: "Profile references (FSFTID) inside GEDCOM imports; links open FamilySearch.",
                  cannotAccess: "Direct API access requires FamilySearch partner approval.", rateLimit: "—", license: "FamilySearch terms"),
            .init(id: "wikitree", name: "WikiTree", availability: .importOnly,
                  canAccess: "WikiTree IDs inside GEDCOM imports; profile links.", cannotAccess: "Bulk API import (planned v0.4).",
                  rateLimit: "—", license: "WikiTree terms"),
            .init(id: "openalex", name: "OpenAlex", availability: .planned, canAccess: "Scientist co-authorship (v0.7).",
                  cannotAccess: "—", rateLimit: "100k/day", license: "CC0"),
            .init(id: "openlibrary", name: "Open Library", availability: .planned, canAccess: "Author records (v0.7).",
                  cannotAccess: "—", rateLimit: "Polite use", license: "CC0 / ODbL"),
            .init(id: "ia", name: "Internet Archive metadata", availability: .planned, canAccess: "Historical document metadata (v0.7).",
                  cannotAccess: "—", rateLimit: "Polite use", license: "Varies by item"),
            .init(id: "csv", name: "CSV / JSON imports", availability: .importOnly,
                  canAccess: "Creator lists, channel IDs, friend lists you provide.", cannotAccess: "—", rateLimit: "Local", license: "Your data"),
        ]
    }
}

/// Persistent research queue with dedup, priorities, retries with backoff, resumable cursors,
/// scheduled refreshes and an audit log. On iOS it runs while the app is active and in
/// short BGProcessingTask windows; it does not (and cannot) run indefinitely in the background.
public final class ResearchScheduler: @unchecked Sendable {
    public let store: GraphStore
    public let http: ResearchHTTP
    public var youtubeAPIKey: String?
    public var maxAttempts = 4
    public var onEvent: (@Sendable (EntityID, ResearchEvent) -> Void)?
    public private(set) var reports: [EntityID: ResearchReport] = [:]
    private let lock = NSLock()

    public init(store: GraphStore, http: ResearchHTTP, youtubeAPIKey: String? = nil) {
        self.store = store; self.http = http; self.youtubeAPIKey = youtubeAPIKey
    }

    // MARK: Queue

    /// Enqueues a job unless an equivalent live job already exists (duplicate avoidance).
    @discardableResult
    public func enqueue(_ job: ResearchJob) throws -> ResearchJob {
        let live = try store.db.query("SELECT id FROM research_job WHERE dedup_key = ? AND status IN ('queued','running','paused')", job.dedupKey)
        if let existing = live.first?.string("id"), let j = try self.job(existing) { return j }
        try save(job)
        return job
    }

    func save(_ j: ResearchJob) throws {
        try store.db.run("""
            INSERT OR REPLACE INTO research_job (id, kind, target, person_id, status, priority, progress, cursor, attempts, last_error,
                created_at, scheduled_for, started_at, finished_at, refresh_interval, dedup_key)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, params: [j.id, j.kind.rawValue, j.target, j.personID, j.status.rawValue, j.priority, j.progress, j.cursor, j.attempts,
                          j.lastError, j.createdAt, j.scheduledFor, j.startedAt, j.finishedAt, j.refreshInterval, j.dedupKey])
    }

    private func decode(_ r: Row) -> ResearchJob? {
        guard let kind = r.string("kind").flatMap(ResearchJobKind.init(rawValue:)),
              let status = r.string("status").flatMap(ResearchJobStatus.init(rawValue:)) else { return nil }
        return ResearchJob(id: r.string("id")!, kind: kind, target: r.string("target") ?? "", personID: r.string("person_id"),
                           status: status, priority: r.int("priority") ?? 0, progress: r.double("progress") ?? 0,
                           cursor: r.string("cursor"), attempts: r.int("attempts") ?? 0, lastError: r.string("last_error"),
                           createdAt: r.date("created_at") ?? Date(), scheduledFor: r.date("scheduled_for") ?? Date(),
                           startedAt: r.date("started_at"), finishedAt: r.date("finished_at"), refreshInterval: r.double("refresh_interval"))
    }

    public func job(_ id: EntityID) throws -> ResearchJob? {
        try store.db.query("SELECT * FROM research_job WHERE id = ?", id).first.flatMap(decode)
    }

    public func jobs(limit: Int = 200) throws -> [ResearchJob] {
        try store.db.query("SELECT * FROM research_job ORDER BY CASE status WHEN 'running' THEN 0 WHEN 'queued' THEN 1 WHEN 'paused' THEN 2 ELSE 3 END, priority DESC, created_at DESC LIMIT ?", limit)
            .compactMap(decode)
    }

    public func log(_ jobID: EntityID, _ level: ResearchLogEntry.Level, _ message: String) {
        _ = try? store.db.run("INSERT INTO research_log (job_id, at, level, message) VALUES (?,?,?,?)", jobID, Date(), level.rawValue, message)
    }

    public func history(_ jobID: EntityID) throws -> [ResearchLogEntry] {
        try store.db.query("SELECT * FROM research_log WHERE job_id = ? ORDER BY id", jobID).map {
            ResearchLogEntry(jobID: jobID, at: $0.date("at") ?? Date(), level: ResearchLogEntry.Level(rawValue: $0.string("level") ?? "info") ?? .info,
                             message: $0.string("message") ?? "")
        }
    }

    /// Jobs left `running` by a crash or suspension are put back in the queue so they resume from their cursor.
    public func recoverInterruptedJobs() throws -> Int {
        try store.db.run("UPDATE research_job SET status = 'queued' WHERE status = 'running'")
    }

    public func pause(_ id: EntityID) throws { try store.db.run("UPDATE research_job SET status = 'paused' WHERE id = ? AND status IN ('queued','running')", id) }
    public func resume(_ id: EntityID) throws { try store.db.run("UPDATE research_job SET status = 'queued' WHERE id = ? AND status = 'paused'", id) }
    public func cancel(_ id: EntityID) throws { try store.db.run("UPDATE research_job SET status = 'cancelled', finished_at = ? WHERE id = ? AND status NOT IN ('completed')", Date(), id) }

    public func nextRunnable(now: Date = Date()) throws -> ResearchJob? {
        try store.db.query("SELECT * FROM research_job WHERE status = 'queued' AND scheduled_for <= ? ORDER BY priority DESC, scheduled_for LIMIT 1", now)
            .first.flatMap(decode)
    }

    /// Runs queued jobs until the queue is empty, `maxJobs` is reached or the deadline passes.
    @discardableResult
    public func runPending(maxJobs: Int = .max, deadline: Date = .distantFuture) async -> Int {
        var count = 0
        while count < maxJobs, Date() < deadline, let job = try? nextRunnable() {
            await run(job)
            count += 1
        }
        return count
    }

    public func report(for jobID: EntityID) -> ResearchReport? { lock.withLock { reports[jobID] } }

    // MARK: Execution

    public func run(_ input: ResearchJob) async {
        var job = input
        job.status = .running
        job.startedAt = job.startedAt ?? Date()
        job.attempts += 1
        _ = try? save(job)
        log(job.id, .info, "Started \(job.kind.rawValue) for \(job.target) (attempt \(job.attempts))")
        let jobID = job.id
        let handler: ResearchEventHandler = { [weak self] event in
            guard let self else { return }
            switch event {
            case .inspectedSource(let s): self.log(jobID, .source, s)
            case .discovered(let d): self.log(jobID, .discovery, d.summary)
            case .rejected(let r): self.log(jobID, .rejected, r)
            case .progress(let p, _): _ = try? self.store.db.run("UPDATE research_job SET progress = ? WHERE id = ?", p, jobID)
            case .newPerson: break
            }
            self.onEvent?(jobID, event)
        }
        do {
            let (report, cursor, finished) = try await execute(job, onEvent: handler)
            lock.withLock { reports[job.id, default: ResearchReport(title: report.title)].merge(report) }
            job.cursor = cursor
            job.lastError = nil
            if finished {
                job.progress = 1
                job.finishedAt = Date()
                job.status = .completed
                log(job.id, .info, "Completed: \(report.discoveries.count) relationships, \(report.peopleAdded.count) new people")
                if let interval = job.refreshInterval {
                    // Scheduled refresh: queue the next run.
                    let next = ResearchJob(kind: job.kind, target: job.target, personID: job.personID, priority: job.priority,
                                           scheduledFor: Date().addingTimeInterval(interval), refreshInterval: interval)
                    try? save(next)
                }
            } else {
                job.status = .queued   // more pages remain; resumes from cursor
            }
        } catch {
            job.lastError = String(describing: error)
            log(job.id, .error, job.lastError!)
            if case HTTPError.offline = error {
                job.status = .paused
            } else if error is YouTubeKeyMissing {
                job.status = .paused
            } else if job.attempts < maxAttempts {
                // Exponential backoff; honour Retry-After on rate limits.
                var delay = pow(2.0, Double(job.attempts)) * 30
                if case HTTPError.rateLimited(let retry?) = error { delay = max(delay, retry) }
                job.status = .queued
                job.scheduledFor = Date().addingTimeInterval(delay)
            } else {
                job.status = .failed
                job.finishedAt = Date()
            }
        }
        try? save(job)
    }

    private func execute(_ job: ResearchJob, onEvent: @escaping ResearchEventHandler) async throws -> (ResearchReport, String?, Bool) {
        let wiki = WikidataResearchAgent(store: store, http: http)
        switch job.kind {
        case .wikidataSearch:
            let hits = try await wiki.wikidata.search(job.target, limit: 5)
            var report = ResearchReport(title: "Search \(job.target)")
            report.sourcesInspected.append("Wikidata search: \(job.target)")
            guard let top = hits.first else {
                report.unansweredQuestions.append("No Wikidata results for “\(job.target)”.")
                return (report, nil, true)
            }
            if hits.count > 1 {
                report.uncertainClaims.append("Several Wikidata matches for “\(job.target)”: " +
                    hits.prefix(5).map { "\($0.label) (\($0.qid)\($0.description.map { ", \($0)" } ?? ""))" }.joined(separator: "; ") +
                    ". Imported the top match; choose another from search if this is the wrong person.")
            }
            let (_, sub) = try await wiki.importPerson(qid: top.qid, onEvent: onEvent)
            report.merge(sub)
            return (report, nil, true)
        case .wikidataEntity:
            let (_, report) = try await wiki.importPerson(qid: job.target, onEvent: onEvent)
            return (report, nil, true)
        case .wikidataFilmography:
            guard let pid = job.personID else { return (ResearchReport(title: "Filmography"), nil, true) }
            return (try await wiki.importFilmography(of: pid, onEvent: onEvent), nil, true)
        case .youtubeChannel:
            guard let key = youtubeAPIKey, !key.isEmpty else { throw YouTubeKeyMissing() }
            let agent = YouTubeResearchAgent(store: store, youtube: YouTubeConnector(http: http, apiKey: key))
            let (pid, report) = try await agent.importChannel(job.target)
            if let pid, let channelID = try store.identities(of: pid).first(where: { $0.scheme == .youtubeChannel })?.value {
                try enqueue(ResearchJob(kind: .youtubeUploads, target: channelID, personID: pid, priority: job.priority - 1))
            }
            return (report, nil, true)
        case .youtubeUploads:
            guard let key = youtubeAPIKey, !key.isEmpty else { throw YouTubeKeyMissing() }
            guard let pid = job.personID else { return (ResearchReport(title: "Uploads"), nil, true) }
            let agent = YouTubeResearchAgent(store: store, youtube: YouTubeConnector(http: http, apiKey: key))
            // Cursor format: "<pagesDone>|<pageToken>"; stop after 4 pages (~200 videos) per job.
            let parts = job.cursor?.split(separator: "|", maxSplits: 1).map(String.init) ?? []
            let pages = Int(parts.first ?? "0") ?? 0
            let token = parts.count > 1 ? parts[1] : nil
            let (report, next) = try await agent.scanUploads(personID: pid, channelID: job.target, pageToken: token)
            let finished = next == nil || pages + 1 >= 4
            return (report, finished ? nil : "\(pages + 1)|\(next!)", finished)
        case .reverify:
            let status = try SourceVerificationAgent(store: store).reverify(job.target)
            var r = ResearchReport(title: "Re-verify")
            r.sourcesInspected.append("Stored evidence for \(job.target): \(status?.rawValue ?? "missing")")
            return (r, nil, true)
        case .duplicateScan:
            let proposals = try MergeEngine(store: store).scanForDuplicates()
            var r = ResearchReport(title: "Duplicate scan")
            r.uncertainClaims = proposals.map { "Possible duplicate (\(Int($0.score * 100))%) awaiting your review" }
            return (r, nil, true)
        }
    }

    public struct YouTubeKeyMissing: Error, CustomStringConvertible {
        public var description: String { "Add a free YouTube Data API key in Settings → Sources to research channels." }
    }
}
