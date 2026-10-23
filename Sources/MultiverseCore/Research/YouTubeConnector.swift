import Foundation

public struct YouTubeChannel: Sendable, Hashable {
    public let id: String
    public let title: String
    public let handle: String?
    public let description: String
    public let subscriberCount: Int?
    public let uploadsPlaylistID: String?
    public let thumbnailURL: String?
}

public struct YouTubeVideo: Sendable, Hashable {
    public let id: String
    public let channelID: String
    public let title: String
    public let description: String
    public let publishedAt: String?
    public var url: String { "https://www.youtube.com/watch?v=\(id)" }
}

/// A connection candidate extracted from public video metadata. Always enters the graph as a
/// `candidate` that needs verification — a mention is never treated as a friendship or kinship.
public struct YouTubeConnectionCandidate: Sendable, Hashable {
    public enum Signal: String, Sendable { case handleMention, channelLink, featuringInTitle, collabKeyword }
    public let videoID: String
    public let mentionedHandle: String?
    public let mentionedChannelID: String?
    public let signal: Signal
    public let snippet: String

    public var relationshipType: RelationshipType {
        switch signal {
        case .featuringInTitle, .collabKeyword: return .videoCollaboration
        case .handleMention, .channelLink: return .channelMention
        }
    }

    public var confidence: Double {
        switch signal {
        case .featuringInTitle: return 0.55
        case .collabKeyword: return 0.45
        case .channelLink: return 0.35
        case .handleMention: return 0.3
        }
    }
}

/// Official YouTube Data API v3 (free daily quota, user-supplied API key). No scraping.
public struct YouTubeConnector: Sendable {
    public let http: ResearchHTTP
    public let apiKey: String
    static let base = "https://www.googleapis.com/youtube/v3"

    public init(http: ResearchHTTP, apiKey: String) { self.http = http; self.apiKey = apiKey }

    /// Approximate quota units per call, for the dashboard (channels/playlistItems = 1, search = 100).
    public static let quotaCost: [String: Int] = ["channels": 1, "playlistItems": 1, "videos": 1, "search": 100]

    private func call(_ endpoint: String, _ params: [String: String]) async throws -> [String: Any] {
        var q = params; q["key"] = apiKey
        let url = try URL.build("\(Self.base)/\(endpoint)", q)
        let cacheKey = "yt:\(endpoint)?" + params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return (try await http.getJSON(url, cacheKey: cacheKey) as? [String: Any]) ?? [:]
    }

    /// Accepts a channel ID (UC…), a handle (@name) or a channel URL.
    public static func parseChannelReference(_ input: String) -> (id: String?, handle: String?) {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "/channel/") {
            return (String(s[r.upperBound...].prefix { $0 != "/" && $0 != "?" }), nil)
        }
        if let r = s.range(of: "youtube.com/@") {
            return (nil, "@" + String(s[r.upperBound...].prefix { $0 != "/" && $0 != "?" }))
        }
        if s.hasPrefix("UC") && s.count == 24 { return (s, nil) }
        if s.hasPrefix("@") { return (nil, s) }
        return (nil, "@" + s.replacingOccurrences(of: " ", with: ""))
    }

    public func channel(_ reference: String) async throws -> YouTubeChannel? {
        let ref = Self.parseChannelReference(reference)
        var params = ["part": "snippet,statistics,contentDetails"]
        if let id = ref.id { params["id"] = id } else if let h = ref.handle { params["forHandle"] = h }
        return Self.parseChannels(try await call("channels", params)).first
    }

    public func recentUploads(playlistID: String, pageToken: String? = nil, maxResults: Int = 50) async throws -> (videos: [YouTubeVideo], next: String?) {
        var params = ["part": "snippet", "playlistId": playlistID, "maxResults": String(min(50, maxResults))]
        if let pageToken { params["pageToken"] = pageToken }
        let json = try await call("playlistItems", params)
        return (Self.parsePlaylistItems(json), json["nextPageToken"] as? String)
    }

    // MARK: Parsing

    public static func parseChannels(_ json: [String: Any]) -> [YouTubeChannel] {
        ((json["items"] as? [[String: Any]]) ?? []).compactMap { item in
            guard let id = item["id"] as? String, let snippet = item["snippet"] as? [String: Any] else { return nil }
            let stats = item["statistics"] as? [String: Any]
            let uploads = ((item["contentDetails"] as? [String: Any])?["relatedPlaylists"] as? [String: Any])?["uploads"] as? String
            let thumb = ((snippet["thumbnails"] as? [String: Any])?["high"] as? [String: Any])?["url"] as? String
            return YouTubeChannel(id: id, title: snippet["title"] as? String ?? id, handle: snippet["customUrl"] as? String,
                                  description: snippet["description"] as? String ?? "",
                                  subscriberCount: (stats?["subscriberCount"] as? String).flatMap(Int.init),
                                  uploadsPlaylistID: uploads, thumbnailURL: thumb)
        }
    }

    public static func parsePlaylistItems(_ json: [String: Any]) -> [YouTubeVideo] {
        ((json["items"] as? [[String: Any]]) ?? []).compactMap { item in
            guard let snippet = item["snippet"] as? [String: Any],
                  let vid = (snippet["resourceId"] as? [String: Any])?["videoId"] as? String else { return nil }
            return YouTubeVideo(id: vid, channelID: snippet["channelId"] as? String ?? "", title: snippet["title"] as? String ?? "",
                                description: snippet["description"] as? String ?? "", publishedAt: snippet["publishedAt"] as? String)
        }
    }

    /// Extracts collaboration / mention candidates from a video's public title and description.
    public static func extractCandidates(from video: YouTubeVideo, ownHandle: String?) -> [YouTubeConnectionCandidate] {
        var out: [YouTubeConnectionCandidate] = []
        var seen = Set<String>()
        let own = ownHandle?.lowercased()
        func add(_ c: YouTubeConnectionCandidate) {
            let key = (c.mentionedHandle ?? c.mentionedChannelID ?? "") + c.signal.rawValue
            if seen.insert(key).inserted { out.append(c) }
        }
        let handleRegex = try! NSRegularExpression(pattern: "(?<![\\w.])@([A-Za-z0-9._-]{3,30})")
        let channelRegex = try! NSRegularExpression(pattern: "youtube\\.com/(?:channel/(UC[A-Za-z0-9_-]{22})|@([A-Za-z0-9._-]{3,30}))")
        let featRegex = try! NSRegularExpression(pattern: "\\b(?:ft\\.?|feat\\.?|featuring|w/|with)\\s+@?([A-Za-z0-9._-]{3,30})", options: [.caseInsensitive])

        func matches(_ re: NSRegularExpression, _ text: String) -> [NSTextCheckingResult] {
            re.matches(in: text, range: NSRange(text.startIndex..., in: text))
        }
        func group(_ m: NSTextCheckingResult, _ i: Int, _ text: String) -> String? {
            guard m.range(at: i).location != NSNotFound, let r = Range(m.range(at: i), in: text) else { return nil }
            return String(text[r])
        }

        for m in matches(featRegex, video.title) {
            if let name = group(m, 1, video.title), "@\(name.lowercased())" != own {
                add(.init(videoID: video.id, mentionedHandle: "@" + name, mentionedChannelID: nil, signal: .featuringInTitle, snippet: video.title))
            }
        }
        for m in matches(channelRegex, video.description) {
            let snippet = String(video.description.prefix(200))
            if let id = group(m, 1, video.description) {
                add(.init(videoID: video.id, mentionedHandle: nil, mentionedChannelID: id, signal: .channelLink, snippet: snippet))
            } else if let h = group(m, 2, video.description), "@\(h.lowercased())" != own {
                add(.init(videoID: video.id, mentionedHandle: "@" + h, mentionedChannelID: nil, signal: .channelLink, snippet: snippet))
            }
        }
        for text in [video.title, video.description] {
            for m in matches(handleRegex, text) {
                if let h = group(m, 1, text), "@\(h.lowercased())" != own, !h.contains("gmail") {
                    let collab = text.lowercased().contains("collab")
                    add(.init(videoID: video.id, mentionedHandle: "@" + h, mentionedChannelID: nil,
                              signal: collab ? .collabKeyword : .handleMention, snippet: String(text.prefix(200))))
                }
            }
        }
        return out
    }
}

/// YouTube Research Agent: imports a channel as a person/creator and records mention/collab candidates.
public struct YouTubeResearchAgent: Sendable {
    public let store: GraphStore
    public let youtube: YouTubeConnector
    public init(store: GraphStore, youtube: YouTubeConnector) { self.store = store; self.youtube = youtube }

    @discardableResult
    public func importChannel(_ reference: String, categories: Set<PersonCategory> = [.youtuber]) async throws -> (EntityID?, ResearchReport) {
        var report = ResearchReport(title: "YouTube \(reference)")
        guard let ch = try await youtube.channel(reference) else {
            report.unansweredQuestions.append("YouTube returned no channel for \(reference).")
            return (nil, report)
        }
        let url = "https://www.youtube.com/channel/\(ch.id)"
        report.sourcesInspected.append(url)
        let (person, created) = try IdentityResolver(store: store).resolveOrCreate(scheme: .youtubeChannel, value: ch.id, url: url) {
            Person(displayName: ch.title, aliases: ch.handle.map { [$0] } ?? [], categories: categories,
                   biography: ch.description.nilIfEmpty, imageURL: ch.thumbnailURL, imageLicense: "YouTube channel thumbnail (display only)",
                   origin: .youtube)
        }
        try store.addPlatformAccount(PlatformAccount(personID: person.id, platform: "youtube", handle: ch.handle, externalID: ch.id,
                                                     url: url, title: ch.title, subscriberCount: ch.subscriberCount))
        if created { report.peopleAdded.append(person.id) } else { report.peopleUpdated.append(person.id) }
        return (person.id, report)
    }

    /// Scans one page of uploads. Returns the next page token so the job can resume later.
    public func scanUploads(personID: EntityID, channelID: String, pageToken: String?, resolveMentions: Int = 10) async throws -> (ResearchReport, next: String?) {
        var report = ResearchReport(title: "Uploads of \(channelID)")
        guard let ch = try await youtube.channel(channelID), let uploads = ch.uploadsPlaylistID else {
            report.unansweredQuestions.append("Uploads playlist unavailable for \(channelID).")
            return (report, nil)
        }
        let (videos, next) = try await youtube.recentUploads(playlistID: uploads, pageToken: pageToken)
        var resolved = 0
        for v in videos {
            report.sourcesInspected.append(v.url)
            for c in YouTubeConnector.extractCandidates(from: v, ownHandle: ch.handle) {
                // Resolve the mentioned channel through the official API — never by display name.
                var otherID: EntityID? = nil
                if let cid = c.mentionedChannelID { otherID = try store.personID(scheme: .youtubeChannel, value: cid) }
                if otherID == nil, resolved < resolveMentions, let ref = c.mentionedChannelID ?? c.mentionedHandle {
                    resolved += 1
                    if let (pid, sub) = try? await importChannel(ref) { otherID = pid; report.merge(sub) }
                }
                guard let other = otherID, other != personID else {
                    report.uncertainClaims.append("Unresolved mention \(c.mentionedHandle ?? c.mentionedChannelID ?? "?") in \(v.url)")
                    continue
                }
                let source = try store.addSource(Source(kind: .youtubeAPI, title: "YouTube video: \(v.title)", url: v.url,
                                                        publisher: "YouTube Data API", reliability: Source.defaultReliability(.youtubeAPI)))
                let rel = try store.addRelationship(
                    Relationship(fromID: personID, toID: other, type: c.relationshipType, verification: .candidate,
                                 confidence: c.confidence, startDate: HistoricalDate.parse(v.publishedAt),
                                 provenance: "YouTubeResearchAgent \(c.signal.rawValue)", contextLabel: v.id),
                    evidence: [EvidenceInput(sourceID: source.id, description: "Public video metadata signal '\(c.signal.rawValue)'. Requires review.",
                                             quote: c.snippet, extractedBy: "YouTubeResearchAgent")])
                report.discoveries.append(.init(relationshipID: rel.id, summary: "\(c.relationshipType.displayName) candidate from \(v.title)",
                                                status: .candidate, sourceURL: v.url))
            }
        }
        return (report, next)
    }
}
