import Foundation
import CryptoKit
import CommonCrypto
import LocalAuthentication
import Security
import FoolscapStore

/// The 32 random bytes that encrypt the vault. Held only while unlocked and
/// overwritten with zeros on lock (copies CryptoKit makes for a single seal are
/// short-lived; the decrypted text in the editor cannot be scrubbed).
public final class VaultKey: @unchecked Sendable {
    private(set) var bytes: Data

    init(bytes: Data) { self.bytes = bytes }

    public static func random() -> VaultKey {
        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        precondition(status == errSecSuccess, "no random bytes")
        return VaultKey(bytes: data)
    }

    var symmetric: SymmetricKey { SymmetricKey(data: bytes) }
    public var isWiped: Bool { bytes.allSatisfy { $0 == 0 } }

    public func wipe() { bytes.resetBytes(in: 0..<bytes.count) }
    deinit { wipe() }
}

/// One wrapped copy of the vault key, as stored in the vault's header.
public struct WrappedKey: Codable, Hashable, Sendable {
    public var kind: String
    /// `AES.GCM.SealedBox.combined` over the 32 key bytes.
    public var sealed: Data
    /// Agreement wraps: the one-time public key the key-encryption key was agreed with.
    public var ephemeralPublicKey: Data?
    public var salt: Data?
    /// Passphrase wraps: the PBKDF2 round count.
    public var iterations: Int?
}

public enum KeyWrapError: LocalizedError, Equatable {
    case wrongPassphrase
    case wrongKind(String)
    case keyDerivationFailed(Int32)
    case deviceKeyMissing

    public var errorDescription: String? {
        switch self {
        case .wrongPassphrase: return "That is not the recovery passphrase."
        case .wrongKind(let k): return "This vault was wrapped another way (\(k))."
        case .keyDerivationFailed(let s): return "Key derivation failed (\(s))."
        case .deviceKeyMissing: return "No Touch ID key on this Mac; use the recovery passphrase."
        }
    }
}

/// Wrap B: the recovery passphrase through PBKDF2-HMAC-SHA256, then AES-GCM.
public enum PassphraseWrap {
    public static let kind = "pbkdf2-hmac-sha256"
    public static let minimumIterations = 600_000

    /// Rounds that take about half a second on this Mac, never under the floor.
    public static func calibratedIterations(passphraseLength: Int = 16) -> Int {
        let rounds = CCCalibratePBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passphraseLength, 32, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 32, 500)
        return max(minimumIterations, Int(rounds))
    }

    static func derive(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        var out = Data(count: 32)
        let pass = Array(passphrase.utf8)
        let status = out.withUnsafeMutableBytes { outPtr in
            salt.withUnsafeBytes { saltPtr in
                pass.withUnsafeBufferPointer { passPtr in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         UnsafeRawPointer(passPtr.baseAddress!).assumingMemoryBound(to: CChar.self), pass.count,
                                         saltPtr.bindMemory(to: UInt8.self).baseAddress!, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                         outPtr.bindMemory(to: UInt8.self).baseAddress!, 32)
                }
            }
        }
        guard status == kCCSuccess else { throw KeyWrapError.keyDerivationFailed(status) }
        return SymmetricKey(data: out)
    }

    public static func wrap(_ key: VaultKey, passphrase: String, iterations: Int) throws -> WrappedKey {
        var salt = Data(count: 32)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let kek = try derive(passphrase: passphrase, salt: salt, iterations: iterations)
        let box = try AES.GCM.seal(key.bytes, using: kek)
        return WrappedKey(kind: kind, sealed: box.combined!, ephemeralPublicKey: nil, salt: salt, iterations: iterations)
    }

    public static func unwrap(_ wrapped: WrappedKey, passphrase: String) throws -> VaultKey {
        guard wrapped.kind == kind, let salt = wrapped.salt, let iterations = wrapped.iterations else { throw KeyWrapError.wrongKind(wrapped.kind) }
        let kek = try derive(passphrase: passphrase, salt: salt, iterations: iterations)
        do {
            let box = try AES.GCM.SealedBox(combined: wrapped.sealed)
            return VaultKey(bytes: try AES.GCM.open(box, using: kek))
        } catch {
            throw KeyWrapError.wrongPassphrase
        }
    }
}

/// A P-256 key agreement key: the Secure Enclave's, or a software one (tests,
/// and the login-keychain fallback).
public protocol AgreementPrivateKey {
    var publicKey: P256.KeyAgreement.PublicKey { get }
    func sharedSecretFromKeyAgreement(with publicKeyShare: P256.KeyAgreement.PublicKey) throws -> SharedSecret
}
extension P256.KeyAgreement.PrivateKey: AgreementPrivateKey {}
extension SecureEnclave.P256.KeyAgreement.PrivateKey: AgreementPrivateKey {}

/// Wrap A: ECDH with a one-time key against the device key, HKDF-SHA256 to a
/// key-encryption key, AES-GCM over the vault key. Wrapping needs only the
/// device's public key; unwrapping makes the Enclave do one agreement, which is
/// where Touch ID is asked for.
public enum AgreementWrap {
    public static let kind = "p256-ecdh-hkdf-sha256"
    static let info = Data("foolscap-secrets-wrap-v1".utf8)

    static func kek(_ shared: SharedSecret, salt: Data, ephemeralPublic: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info + ephemeralPublic, outputByteCount: 32)
    }

    public static func wrap(_ key: VaultKey, recipient: P256.KeyAgreement.PublicKey) throws -> WrappedKey {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        var salt = Data(count: 32)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let ephemeralPublic = ephemeral.publicKey.x963Representation
        let box = try AES.GCM.seal(key.bytes, using: kek(shared, salt: salt, ephemeralPublic: ephemeralPublic), authenticating: ephemeralPublic)
        return WrappedKey(kind: kind, sealed: box.combined!, ephemeralPublicKey: ephemeralPublic, salt: salt, iterations: nil)
    }

    public static func unwrap(_ wrapped: WrappedKey, using device: any AgreementPrivateKey) throws -> VaultKey {
        guard wrapped.kind == kind, let ephemeralPublic = wrapped.ephemeralPublicKey, let salt = wrapped.salt else { throw KeyWrapError.wrongKind(wrapped.kind) }
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: ephemeralPublic)
        let shared = try device.sharedSecretFromKeyAgreement(with: ephemeral)
        let box = try AES.GCM.SealedBox(combined: wrapped.sealed)
        return VaultKey(bytes: try AES.GCM.open(box, using: kek(shared, salt: salt, ephemeralPublic: ephemeralPublic), authenticating: ephemeralPublic))
    }
}

/// Where this Mac's half of the device wrap lives.
public protocol DeviceKeyStore: AnyObject, Sendable {
    /// Recorded in the vault header so the same store opens it next time.
    var kindID: String { get }
    /// What the Settings pane calls it ("Touch ID", "this Mac's keychain").
    var displayName: String { get }
    var isEnrolled: Bool { get }
    /// The public key to wrap with; nil when not enrolled. Never prompts.
    func publicKey() throws -> P256.KeyAgreement.PublicKey?
    /// Make a new key (replacing any old one) and return its public half.
    func enrol() throws -> P256.KeyAgreement.PublicKey
    /// The private key, for one agreement; the context carries the Touch ID prompt.
    func privateKey(context: LAContext) throws -> any AgreementPrivateKey
    func destroy() throws
}

/// The Secure Enclave: the key never leaves the chip, and `.userPresence` makes
/// every agreement ask for Touch ID (or the login password, the system's own
/// fallback). Its encrypted blob sits in Application Support, useless elsewhere.
public final class EnclaveKeyStore: DeviceKeyStore, @unchecked Sendable {
    public let blobURL: URL
    public init(blobURL: URL) { self.blobURL = blobURL }

    public var kindID: String { "secure-enclave" }
    public var displayName: String { "Touch ID" }
    public static var isAvailable: Bool { SecureEnclave.isAvailable }
    public var isEnrolled: Bool { FileManager.default.fileExists(atPath: blobURL.path) }

    public func publicKey() throws -> P256.KeyAgreement.PublicKey? {
        guard isEnrolled else { return nil }
        let blob = try Data(contentsOf: blobURL)
        return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob).publicKey
    }

    public func enrol() throws -> P256.KeyAgreement.PublicKey {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage, .userPresence], &error) else {
            throw error!.takeRetainedValue() as Error
        }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        try FileManager.default.createDirectory(at: blobURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try key.dataRepresentation.write(to: blobURL, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blobURL.path)
        return key.publicKey
    }

    public func privateKey(context: LAContext) throws -> any AgreementPrivateKey {
        guard isEnrolled else { throw KeyWrapError.deviceKeyMissing }
        let blob = try Data(contentsOf: blobURL)
        return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob, authenticationContext: context)
    }

    public func destroy() throws {
        if isEnrolled { try FileManager.default.removeItem(at: blobURL) }
    }
}

/// The fallback when the Enclave refuses this (self-signed) app: a software P-256
/// key in the login keychain, read only after Touch ID or the password has been
/// checked through LocalAuthentication. Device-bound in practice, not in silicon.
public final class KeychainKeyStore: DeviceKeyStore, @unchecked Sendable {
    public static let service = "com.seanmatheny.foolscap.secrets"
    let item: KeychainItem
    public init(account: String = "device-key") { item = KeychainItem(service: Self.service, account: account, label: "Foolscap Secrets") }

    public var kindID: String { "login-keychain" }
    public var displayName: String { "this Mac's keychain" }
    public var isEnrolled: Bool { (try? item.read()) != nil }

    public func publicKey() throws -> P256.KeyAgreement.PublicKey? {
        guard let raw = try item.read() else { return nil }
        return try P256.KeyAgreement.PrivateKey(rawRepresentation: raw).publicKey
    }

    public func enrol() throws -> P256.KeyAgreement.PublicKey {
        let key = P256.KeyAgreement.PrivateKey()
        try item.write(key.rawRepresentation)
        return key.publicKey
    }

    public func privateKey(context: LAContext) throws -> any AgreementPrivateKey {
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else { throw authError ?? KeyWrapError.deviceKeyMissing }
        let semaphore = DispatchSemaphore(value: 0)
        let outcome = OutcomeBox()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: context.localizedReason) { ok, error in
            outcome.result = error.map { .failure($0) } ?? .success(ok)
            semaphore.signal()
        }
        semaphore.wait()
        guard try outcome.result.get() else { throw LAError(.userCancel) }
        guard let raw = try item.read() else { throw KeyWrapError.deviceKeyMissing }
        return try P256.KeyAgreement.PrivateKey(rawRepresentation: raw)
    }

    public func destroy() throws { try item.delete() }
}

/// The result of an authentication callback, handed across the semaphore.
private final class OutcomeBox: @unchecked Sendable {
    var result: Result<Bool, Error> = .success(false)
}

/// A software key held in memory: tests, and nothing else.
public final class MemoryKeyStore: DeviceKeyStore, @unchecked Sendable {
    public var key: P256.KeyAgreement.PrivateKey?
    public var kindID: String { "memory" }
    public var displayName: String { "a test key" }
    public init() {}
    public var isEnrolled: Bool { key != nil }
    public func publicKey() throws -> P256.KeyAgreement.PublicKey? { key?.publicKey }
    public func enrol() throws -> P256.KeyAgreement.PublicKey { let k = P256.KeyAgreement.PrivateKey(); key = k; return k.publicKey }
    public func privateKey(context: LAContext) throws -> any AgreementPrivateKey {
        guard let key else { throw KeyWrapError.deviceKeyMissing }
        return key
    }
    public func destroy() throws { key = nil }
}
