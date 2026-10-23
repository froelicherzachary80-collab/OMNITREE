import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A text-generation backend. MIE never relies on a model for facts: models only
/// (a) parse a request into a tool call when the rule parser cannot, and
/// (b) rephrase tool results that are passed to them verbatim.
public protocol LanguageModel: Sendable {
    var name: String { get }
    var isOnDevice: Bool { get }
    func isAvailable() async -> Bool
    func complete(system: String, prompt: String, maxTokens: Int) async throws -> String
}

public struct LanguageModelUnavailable: Error, CustomStringConvertible {
    public let reason: String
    public var description: String { "Language model unavailable: \(reason)" }
}

/// Talks to a free, self-hosted Ollama server on a computer the user owns
/// (e.g. `ollama run qwen2.5:7b-instruct` or `llama3.1:8b` — Apache-2.0 / Llama community licence).
public struct OllamaLanguageModel: LanguageModel {
    public let baseURL: URL
    public let model: String
    public var name: String { "Ollama · \(model)" }
    public var isOnDevice: Bool { false }

    public init(baseURL: URL = URL(string: "http://localhost:11434")!, model: String = "qwen2.5:7b-instruct") {
        self.baseURL = baseURL
        self.model = model
    }

    private func request(_ path: String, body: [String: Any]?, timeout: TimeInterval) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try await withCheckedThrowingContinuation { cont in
            URLSession.shared.dataTask(with: req) { data, response, error in
                if let error { cont.resume(throwing: error); return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status), let data else {
                    cont.resume(throwing: LanguageModelUnavailable(reason: "HTTP \(status) from Ollama")); return
                }
                cont.resume(returning: data)
            }.resume()
        }
    }

    public func isAvailable() async -> Bool {
        guard let data = try? await request("api/tags", body: nil, timeout: 3),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return false }
        return models.contains { ($0["name"] as? String)?.hasPrefix(model.split(separator: ":").first.map(String.init) ?? model) == true }
    }

    public func complete(system: String, prompt: String, maxTokens: Int) async throws -> String {
        let body: [String: Any] = [
            "model": model, "stream": false,
            "options": ["temperature": 0.1, "num_predict": maxTokens],
            "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
        ]
        let data = try await request("api/chat", body: body, timeout: 120)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = json["message"] as? [String: Any], let content = msg["content"] as? String else {
            throw LanguageModelUnavailable(reason: "unexpected Ollama response")
        }
        return content
    }
}
