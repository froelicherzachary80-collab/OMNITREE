import Foundation

/// A structured request MIE knows how to execute with real graph / research functions.
public enum ResearchIntent: Equatable, Sendable {
    /// `"me"` refers to the user's own profile.
    case connect(String, String, exhaustive: Bool)
    case connectGroup(PersonCategory)
    case connectMany([String])
    case nearest(from: String, category: PersonCategory)
    case commonAncestors(String, String)
    case researchPerson(String)
    case researchFilmography(String)
    case researchGroup(String)
    case researchChannel(String)
    case collaborationsBetween(PersonCategory, PersonCategory)
    case find(String)
    case help
    case unknown(String)

    /// Tool name shown in the research trace.
    public var toolName: String {
        switch self {
        case .connect: return "pathfinder.connectionReport"
        case .connectGroup, .connectMany: return "pathfinder.multiConnection"
        case .nearest: return "pathfinder.nearest"
        case .commonAncestors: return "genealogy.commonAncestors"
        case .researchPerson: return "research.wikidataSearch"
        case .researchFilmography: return "research.wikidataFilmography"
        case .researchGroup: return "research.wikidataGroup"
        case .researchChannel: return "research.youtubeChannel"
        case .collaborationsBetween: return "graph.crossCategoryCollaborations"
        case .find: return "graph.search"
        case .help: return "assistant.help"
        case .unknown: return "assistant.unknown"
        }
    }
}

/// Deterministic natural-language → intent parser (Conversational Research Agent, stage 1).
/// When it returns `.unknown`, MIE asks the configured language model to map the request onto
/// the same JSON tool schema; free-form model output is never executed directly.
public enum IntentParser {
    static let selfWords: Set<String> = ["me", "i", "myself", "my self"]

    public static func parse(_ input: String) -> ResearchIntent {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.isEmpty { return .help }
        if ["help", "what can you do", "what can you do?", "?"].contains(lower) { return .help }

        if let m = match(text, #"(?i)how\s+are\s+all\s+(?:of\s+)?my\s+friends\s+(?:connected|related)"#) { _ = m; return .connectGroup(.friend) }
        if lower.contains("my friends") && (lower.contains("connect") || lower.contains("related")) { return .connectGroup(.friend) }

        if let m = match(text, #"(?i)(?:do|does)\s+(.+?)\s+share\s+(?:any\s+)?(?:documented\s+)?(?:common\s+)?ancestors?\s+with\s+(.+)"#) {
            return .commonAncestors(normalizeSubject(m[0]), clean(m[1]))
        }
        if let m = match(text, #"(?i)common\s+ancestors?\s+(?:of|between|for)\s+(.+?)\s+and\s+(.+)"#) {
            return .commonAncestors(normalizeSubject(m[0]), clean(m[1]))
        }

        if let m = match(text, #"(?i)(?:shortest|closest|nearest)\s+(?:verified\s+|documented\s+)?connection\s+(?:from\s+(.+?)\s+)?to\s+(?:a|an|any)\s+(.+)"#) {
            if let cat = category(in: m[1]) { return .nearest(from: m[0].isEmpty ? "me" : normalizeSubject(m[0]), category: cat) }
        }

        if let m = match(text, #"(?i)collaborations?\s+between\s+(.+?)\s+and\s+(.+)"#),
           let a = category(in: m[0]), let b = category(in: m[1]) {
            return .collaborationsBetween(a, b)
        }

        let exhaustive = lower.contains("every") || lower.contains("all documented") || lower.contains("all the connections")
        let connectPatterns = [
            #"(?i)how\s+am\s+i\s+(?:connected|related|linked)\s+to\s+(.+)"#,
        ]
        for p in connectPatterns { if let m = match(text, p) { return .connect("me", clean(m[0]), exhaustive: exhaustive) } }
        let pairPatterns = [
            #"(?i)how\s+(?:is|are|was|were)\s+(.+?)\s+(?:connected|related|linked)\s+(?:to|with)\s+(.+)"#,
            #"(?i)(?:connection|connections|path|link|links)\s+between\s+(.+?)\s+and\s+(.+)"#,
            #"(?i)^connect\s+(.+?)\s+(?:and|to|with)\s+(.+)"#,
            #"(?i)is\s+(.+?)\s+(?:connected|related)\s+to\s+(.+)"#,
        ]
        for p in pairPatterns {
            if let m = match(text, p) {
                let a = normalizeSubject(m[0]), b = clean(m[1])
                if b.lowercased().contains("minecraft creator universe") || b.lowercased().contains("universe") {
                    if let cat = category(in: b) { return .nearest(from: a, category: cat) }
                }
                return .connect(a, b, exhaustive: exhaustive)
            }
        }

        if let m = match(text, #"(?i)(?:research|investigate|import|add)\s+(?:all\s+)?(?:of\s+)?(?:the\s+)?members\s+of\s+(.+?)(?:\s+and\s+connect\s+them)?$"#) {
            return .researchGroup(clean(m[0]))
        }
        if lower.contains("youtube.com/") || match(text, #"(?i)(?:research|import|add|analy[sz]e)\s+(?:this\s+|the\s+|my\s+)?(?:youtube\s+)?channel\s+(.+)"#) != nil
            || match(text, #"^(?:research|import|add)\s+@[\w.-]+"#) != nil {
            if let url = text.split(separator: " ").first(where: { $0.contains("youtube.com/") || $0.hasPrefix("@") }) {
                return .researchChannel(String(url).trimmingCharacters(in: CharacterSet(charactersIn: ".,!?\"'")))
            }
            if let m = match(text, #"(?i)channel\s+(.+?)(?:\s+and\s+add.*)?$"#) { return .researchChannel(clean(m[0])) }
        }
        if let m = match(text, #"(?i)(?:filmography|co-?stars|credits|films|movies)\s+(?:of|for)\s+(.+)"#) {
            return .researchFilmography(clean(m[0]))
        }
        if let m = match(text, #"(?i)(?:research|investigate|look\s+up|search\s+for|who\s+is|who\s+was|tell\s+me\s+about)\s+(.+)"#) {
            return .researchPerson(clean(m[0]))
        }
        if let m = match(text, #"(?i)^(?:show|find|open)\s+(.+)"#) { return .find(clean(m[0])) }
        return .unknown(text)
    }

    /// Maps free text to a person category.
    public static func category(in text: String) -> PersonCategory? {
        let t = text.lowercased()
        if t.contains("minecraft") { return .minecraftCreator }
        if t.contains("youtuber") || t.contains("youtube") || t.contains("creator") { return .youtuber }
        if t.contains("streamer") || t.contains("twitch") { return .twitchStreamer }
        if t.contains("tiktok") { return .tiktokCreator }
        if t.contains("actor") || t.contains("actress") || t.contains("celebrit") { return .actor }
        if t.contains("musician") || t.contains("singer") { return .musician }
        if t.contains("director") { return .director }
        if t.contains("historical") || t.contains("history") { return .historicalFigure }
        if t.contains("scientist") { return .scientist }
        if t.contains("author") || t.contains("writer") { return .author }
        if t.contains("athlete") { return .athlete }
        if t.contains("royal") || t.contains("politic") || t.contains("president") { return .politicalOrRoyal }
        if t.contains("friend") { return .friend }
        if t.contains("family") || t.contains("relative") { return .familyMember }
        return nil
    }

    static func normalizeSubject(_ s: String) -> String {
        let c = clean(s)
        return selfWords.contains(c.lowercased()) ? "me" : c
    }

    static func clean(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "?.!,;:\"'“”‘’ "))
        for prefix in ["the actor ", "the actress ", "the youtuber ", "actor ", "actress ", "youtuber "] where out.lowercased().hasPrefix(prefix) {
            out = String(out.dropFirst(prefix.count))
        }
        return out
    }

    static func match(_ text: String, _ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<max(1, m.numberOfRanges)).map { i in
            guard m.range(at: i).location != NSNotFound, let r = Range(m.range(at: i), in: text) else { return "" }
            return String(text[r])
        }
    }

    /// JSON schema the language model must answer with when the rule parser fails.
    public static let modelSchemaPrompt = """
    You convert a user's request about people and their documented connections into ONE JSON object.
    Allowed forms (use exactly these keys):
    {"tool":"connect","a":"<name or me>","b":"<name>"}
    {"tool":"connectMany","names":["<name>", "..."]}
    {"tool":"nearest","from":"<name or me>","category":"<youtuber|minecraftCreator|actor|musician|historicalFigure|scientist|author|athlete|friend>"}
    {"tool":"commonAncestors","a":"<name or me>","b":"<name>"}
    {"tool":"research","name":"<person name>"}
    {"tool":"filmography","name":"<person name>"}
    {"tool":"group","name":"<group or community name>"}
    {"tool":"channel","ref":"<channel url, @handle or id>"}
    {"tool":"find","name":"<name>"}
    {"tool":"none"}
    Reply with JSON only. Never invent names that are not in the request.
    """

    /// Parses the model's JSON reply into an intent. Anything malformed becomes `.unknown`.
    public static func intent(fromModelJSON reply: String, original: String) -> ResearchIntent {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any],
              let tool = obj["tool"] as? String else { return .unknown(original) }
        // Guard against hallucinated names: every name must literally appear in the user's request.
        func grounded(_ s: String?) -> String? {
            guard let s, !s.isEmpty else { return nil }
            if s.lowercased() == "me" { return "me" }
            return original.lowercased().contains(s.lowercased()) ? s : nil
        }
        switch tool {
        case "connect": if let a = grounded(obj["a"] as? String), let b = grounded(obj["b"] as? String) { return .connect(a, b, exhaustive: false) }
        case "connectMany":
            let names = (obj["names"] as? [String] ?? []).compactMap(grounded)
            if names.count >= 2 { return .connectMany(names) }
        case "nearest":
            if let f = grounded(obj["from"] as? String), let c = (obj["category"] as? String).flatMap(PersonCategory.init(rawValue:)) { return .nearest(from: f, category: c) }
        case "commonAncestors": if let a = grounded(obj["a"] as? String), let b = grounded(obj["b"] as? String) { return .commonAncestors(a, b) }
        case "research": if let n = grounded(obj["name"] as? String) { return .researchPerson(n) }
        case "filmography": if let n = grounded(obj["name"] as? String) { return .researchFilmography(n) }
        case "group": if let n = grounded(obj["name"] as? String) { return .researchGroup(n) }
        case "channel": if let n = grounded(obj["ref"] as? String) { return .researchChannel(n) }
        case "find": if let n = grounded(obj["name"] as? String) { return .find(n) }
        default: break
        }
        return .unknown(original)
    }
}
