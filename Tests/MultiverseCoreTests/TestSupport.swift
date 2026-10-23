import Foundation
import XCTest
@testable import MultiverseCore

/// Reversible test-only cipher (XOR + magic header). Production uses AES-GCM via CryptoKit.
struct TestCipher: FieldCipher {
    func seal(_ p: Data) throws -> Data { Data("TC1".utf8) + Data(p.map { $0 ^ 0x5A }) }
    func open(_ c: Data) throws -> Data {
        guard c.prefix(3) == Data("TC1".utf8) else { throw CipherError.authenticationFailed }
        return Data(c.dropFirst(3).map { $0 ^ 0x5A })
    }
}

/// Serves fixture files for URL substrings; records requests.
final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    var routes: [(String, Data)] = []
    var requests: [URL] = []
    var failuresBeforeSuccess = 0
    private let lock = NSLock()

    func route(_ contains: String, fixture: String) {
        routes.append((contains, try! fixtureData(fixture)))
    }

    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        let shouldFail: Bool = lock.withLock {
            requests.append(url)
            if failuresBeforeSuccess > 0 { failuresBeforeSuccess -= 1; return true }
            return false
        }
        if shouldFail { return HTTPResponse(status: 503, body: Data()) }
        let s = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        for (needle, data) in routes where s.contains(needle) { return HTTPResponse(status: 200, body: data) }
        return HTTPResponse(status: 404, body: Data())
    }
}

func fixtureData(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name)"])
    }
    return try Data(contentsOf: url)
}

func fixtureText(_ name: String) throws -> String { String(decoding: try fixtureData(name), as: UTF8.self) }

extension XCTestCase {
    func makeStore() throws -> GraphStore { try GraphStore.inMemory(cipher: TestCipher()) }

    func source(_ store: GraphStore, reliability: Double = 0.8, kind: SourceKind = .userEntry) throws -> Source {
        try store.addSource(Source(kind: kind, title: "test", documentRef: "test:\(UUID())", reliability: reliability))
    }

    @discardableResult
    func person(_ store: GraphStore, _ name: String, _ cats: Set<PersonCategory> = [], birth: Int? = nil) throws -> Person {
        try store.upsert(Person(displayName: name, categories: cats, birth: birth.map { HistoricalDate(year: $0) }))
    }

    @discardableResult
    func link(_ store: GraphStore, _ a: Person, _ b: Person, _ type: RelationshipType, status: VerificationStatus = .sourced,
              confidence: Double = 0.9, src: Source? = nil) throws -> Relationship {
        let s = try src ?? source(store)
        return try store.addRelationship(Relationship(fromID: a.id, toID: b.id, type: type, verification: status, confidence: confidence, provenance: "test"),
                                         evidence: [EvidenceInput(sourceID: s.id, description: "test evidence", extractedBy: "test")])
    }
}
