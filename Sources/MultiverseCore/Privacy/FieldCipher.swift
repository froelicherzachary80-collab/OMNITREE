import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Encrypts sensitive person data before it reaches SQLite.
public protocol FieldCipher: Sendable {
    func seal(_ plaintext: Data) throws -> Data
    func open(_ ciphertext: Data) throws -> Data
}

public enum CipherError: Error { case unavailable, invalidKey, authenticationFailed }

#if canImport(CryptoKit)
/// AES-256-GCM using CryptoKit. On iOS the key lives in the Keychain (see `KeychainKeyStore` in the app target).
public struct AESGCMFieldCipher: FieldCipher {
    private let key: SymmetricKey
    public init(keyData: Data) throws {
        guard keyData.count == 32 else { throw CipherError.invalidKey }
        key = SymmetricKey(data: keyData)
    }
    public static func generateKeyData() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
    public func seal(_ plaintext: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: key).combined else { throw CipherError.unavailable }
        return combined
    }
    public func open(_ ciphertext: Data) throws -> Data {
        do { return try AES.GCM.open(try AES.GCM.SealedBox(combined: ciphertext), using: key) }
        catch { throw CipherError.authenticationFailed }
    }
}
#endif

/// Used where no cipher is configured: refuses to store private data rather than writing it in the clear.
public struct UnavailableCipher: FieldCipher {
    public init() {}
    public func seal(_ plaintext: Data) throws -> Data { throw CipherError.unavailable }
    public func open(_ ciphertext: Data) throws -> Data { throw CipherError.unavailable }
}
