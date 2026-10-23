import Foundation
import MultiverseCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device foundation model (iOS 26, Apple Intelligence devices such as iPhone 16 Pro).
/// Free, private and offline. Like every MIE backend it only maps phrasing to tool calls and
/// rephrases tool results — it is never asked for facts.
struct OnDeviceLanguageModel: LanguageModel {
    var name: String { "Apple on-device model" }
    var isOnDevice: Bool { true }

    func isAvailable() async -> Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    func complete(system: String, prompt: String, maxTokens: Int) async throws -> String {
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else {
            throw LanguageModelUnavailable(reason: "Apple Intelligence is not enabled or not supported on this device")
        }
        let session = LanguageModelSession(instructions: system)
        let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.1, maximumResponseTokens: maxTokens))
        return response.content
        #else
        throw LanguageModelUnavailable(reason: "FoundationModels framework not available")
        #endif
    }
}
