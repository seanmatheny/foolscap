import Foundation
import CryptoKit
import LocalAuthentication
import FoolscapStore

/// What sits in front of the ciphertext. Its stored bytes are the GCM's additional
/// authenticated data, so a header edited on disk fails to open.
public struct VaultHeader: Codable, Hashable, Sendable {
    public var format = 1
    public var cipher = "AES-256-GCM"
    public var created: Date
    public var modified: Date
    /// "device" (this Mac's key) and "passphrase" (the recovery passphrase).
    public var wraps: [String: WrappedKey]
    /// Which device key store made the "device" wrap (`DeviceKeyStore.kindID`).
    public var deviceKind: String?

    public static let deviceSlot = "device", passphraseSlot = "passphrase"
}

public enum VaultError: LocalizedError, Equatable {
    case notAVault
    case unsupportedFormat(Int)
    case damaged
    case locked
    case noSuchWrap(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notAVault: return "This is not a Foolscap secrets vault."
        case .unsupportedFormat(let v): return "This vault was written by a newer Foolscap (format \(v))."
        case .damaged: return "The vault has been altered or damaged and cannot be opened."
        case .locked: return "The vault is locked."
        case .noSuchWrap(let s): return s == VaultHeader.deviceSlot ? "Touch ID is not set up for this vault." : "This vault has no recovery passphrase."
        case .cancelled: return "Unlock cancelled."
        }
    }
}

/// The file: `FSCV`, a big-endian UInt32 header length, the header JSON, then
/// `AES.GCM.SealedBox.combined` (nonce, ciphertext, tag) over the UTF-8 markdown.
public enum VaultEnvelope {
    static let magic = Data("FSCV".utf8)

    public struct Parsed: Sendable {
        public var headerBytes: Data
        public var header: VaultHeader
        public var sealed: Data
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func encode(header: VaultHeader, plaintext: Data, key: VaultKey) throws -> Data {
        let headerBytes = try encoder.encode(header)
        let box = try AES.GCM.seal(plaintext, using: key.symmetric, authenticating: headerBytes)
        var out = magic
        var length = UInt32(headerBytes.count).bigEndian
        out.append(Data(bytes: &length, count: 4))
        out.append(headerBytes)
        out.append(box.combined!)
        return out
    }

    public static func decode(_ data: Data) throws -> Parsed {
        guard data.count >= 8, data.prefix(4) == magic else { throw VaultError.notAVault }
        let length = Int(data.subdata(in: 4..<8).withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) })
        guard data.count >= 8 + length + 28 else { throw VaultError.damaged }
        let headerBytes = data.subdata(in: 8..<(8 + length))
        let header: VaultHeader
        do { header = try decoder.decode(VaultHeader.self, from: headerBytes) } catch { throw VaultError.damaged }
        guard header.format == 1 else { throw VaultError.unsupportedFormat(header.format) }
        return Parsed(headerBytes: headerBytes, header: header, sealed: data.subdata(in: (8 + length)..<data.count))
    }

    public static func open(_ parsed: Parsed, key: VaultKey) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: parsed.sealed)
            return try AES.GCM.open(box, using: key.symmetric, authenticating: parsed.headerBytes)
        } catch {
            throw VaultError.damaged
        }
    }
}

/// One vault file and its key while open. Edits save a second after the last
/// one; locking saves, wipes the key and drops the plaintext.
@MainActor
@Observable
public final class SecretsVault {
    public enum State: Equatable, Sendable {
        /// No file yet: the first run makes one.
        case absent
        case locked
        case unlocking
        case unlocked
        /// The file is there but cannot be read as a vault.
        case failed(String)
    }

    public let url: URL
    /// Device key stores in order of preference; the first that enrols is used.
    public let deviceStores: [any DeviceKeyStore]
    public private(set) var state: State = .absent
    public private(set) var header: VaultHeader?
    public private(set) var document: SecretsDocument?
    public private(set) var isDirty = false
    public private(set) var lastError: String?
    /// Why Touch ID could not be set up, for the Settings pane.
    public private(set) var deviceEnrolError: String?
    /// PBKDF2 rounds for new passphrase wraps; nil calibrates (tests pass a small number).
    public var passphraseIterations: Int?
    public var saveDelay: Duration = .seconds(1)

    @ObservationIgnored private var key: VaultKey?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    public init(url: URL, deviceStores: [any DeviceKeyStore]) {
        self.url = url
        self.deviceStores = deviceStores
    }

    /// The store that made this vault's device wrap (or the preferred one before enrolment).
    public var deviceStore: (any DeviceKeyStore)? {
        if let kind = header?.deviceKind, let s = deviceStores.first(where: { $0.kindID == kind }) { return s }
        return deviceStores.first
    }
    public var hasDeviceWrap: Bool {
        guard let header, header.wraps[VaultHeader.deviceSlot] != nil, let store = deviceStore else { return false }
        return store.isEnrolled
    }
    public var hasPassphraseWrap: Bool { header?.wraps[VaultHeader.passphraseSlot] != nil }
    public var byteCount: Int { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 }

    // MARK: Opening

    /// Read the header (never the contents) and settle into `.locked` or `.absent`.
    public func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { state = .absent; header = nil; return }
        do {
            let parsed = try VaultEnvelope.decode(try Data(contentsOf: url))
            header = parsed.header
            if state != .unlocked { state = .locked }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// First run: a fresh key wrapped with the passphrase and, where a device key
    /// store accepts, with this Mac's key. Writes an empty vault and opens it.
    public func create(passphrase: String) throws {
        let key = VaultKey.random()
        var wraps: [String: WrappedKey] = [:]
        wraps[VaultHeader.passphraseSlot] = try PassphraseWrap.wrap(key, passphrase: passphrase, iterations: passphraseIterations ?? PassphraseWrap.calibratedIterations(passphraseLength: passphrase.utf8.count))
        let now = Date()
        var header = VaultHeader(created: now, modified: now, wraps: wraps, deviceKind: nil)
        if let (store, wrapped) = enrolAnyDevice(key) {
            header.wraps[VaultHeader.deviceSlot] = wrapped
            header.deviceKind = store.kindID
        }
        self.key = key
        self.header = header
        document = SecretsDocument()
        isDirty = true
        state = .unlocked
        try write()
    }

    private func enrolAnyDevice(_ key: VaultKey) -> ((any DeviceKeyStore), WrappedKey)? {
        var problems: [String] = []
        for store in deviceStores {
            do {
                let publicKey = try store.enrol()
                let wrapped = try AgreementWrap.wrap(key, recipient: publicKey)
                deviceEnrolError = problems.isEmpty ? nil : problems.joined(separator: " ")
                return (store, wrapped)
            } catch {
                problems.append("\(store.displayName): \(error.localizedDescription)")
            }
        }
        deviceEnrolError = problems.joined(separator: " ")
        return nil
    }

    /// Touch ID (or the login password): the device key unwraps the vault key off
    /// the main thread while the system's sheet is up.
    public func unlockWithDevice() async {
        guard state == .locked, let header, let wrapped = header.wraps[VaultHeader.deviceSlot], let store = deviceStore else {
            lastError = VaultError.noSuchWrap(VaultHeader.deviceSlot).localizedDescription
            return
        }
        state = .unlocking
        lastError = nil
        do {
            let parsed = try VaultEnvelope.decode(try Data(contentsOf: url))
            let key = try await Task.detached(priority: .userInitiated) {
                let context = LAContext()
                context.localizedReason = "unlock your secrets"
                context.localizedFallbackTitle = "Use Password…"
                let device = try store.privateKey(context: context)
                return try AgreementWrap.unwrap(wrapped, using: device)
            }.value
            try finishUnlock(key: key, parsed: parsed)
        } catch let error as LAError where error.code == .userCancel || error.code == .appCancel || error.code == .systemCancel {
            state = .locked
        } catch {
            state = .locked
            lastError = Self.describe(error)
        }
    }

    public func unlock(passphrase: String) async {
        guard state == .locked, let header, let wrapped = header.wraps[VaultHeader.passphraseSlot] else {
            lastError = VaultError.noSuchWrap(VaultHeader.passphraseSlot).localizedDescription
            return
        }
        state = .unlocking
        lastError = nil
        do {
            let parsed = try VaultEnvelope.decode(try Data(contentsOf: url))
            let key = try await Task.detached(priority: .userInitiated) {
                try PassphraseWrap.unwrap(wrapped, passphrase: passphrase)
            }.value
            try finishUnlock(key: key, parsed: parsed)
        } catch {
            state = .locked
            lastError = Self.describe(error)
        }
    }

    private func finishUnlock(key: VaultKey, parsed: VaultEnvelope.Parsed) throws {
        // Locked while the prompt was up (sleep, quit): the key is not wanted any more.
        guard state == .unlocking else { key.wipe(); return }
        let plaintext = try VaultEnvelope.open(parsed, key: key)
        self.key = key
        header = parsed.header
        document = SecretsDocument.parse(String(decoding: plaintext, as: UTF8.self))
        isDirty = false
        state = .unlocked
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? LAError {
            switch e.code {
            case .biometryNotAvailable, .biometryNotEnrolled: return "Touch ID is not available; use the recovery passphrase."
            case .biometryLockout: return "Touch ID is locked out; use your password or the recovery passphrase."
            default: return e.localizedDescription
            }
        }
        return error.localizedDescription
    }

    // MARK: Editing and saving

    /// Change the plaintext; the vault saves a second after the last change.
    public func edit(_ mutate: (inout SecretsDocument) -> Void) {
        guard state == .unlocked, var doc = document else { return }
        mutate(&doc)
        guard doc != document else { return }
        document = doc
        isDirty = true
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self, saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Seal and write now (a few kilobytes of AES-GCM: fine on the main thread).
    public func saveNow() {
        saveTask?.cancel()
        guard state == .unlocked, isDirty else { return }
        do { try write() } catch { lastError = "Could not save the vault: \(error.localizedDescription)" }
    }

    private func write() throws {
        guard let key, var header, let document else { throw VaultError.locked }
        header.modified = Date()
        let data = try VaultEnvelope.encode(header: header, plaintext: Data(document.serialized().utf8), key: key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        self.header = header
        isDirty = false
    }

    /// Save if needed, forget the key and the text.
    public func lock() {
        saveTask?.cancel()
        if state == .unlocked, isDirty { saveNow() }
        key?.wipe()
        key = nil
        document = nil
        if state == .unlocked || state == .unlocking { state = .locked }
    }

    // MARK: Re-keying (unlocked only)

    public func changePassphrase(to passphrase: String) throws {
        guard state == .unlocked, let key, var header else { throw VaultError.locked }
        header.wraps[VaultHeader.passphraseSlot] = try PassphraseWrap.wrap(key, passphrase: passphrase, iterations: passphraseIterations ?? PassphraseWrap.calibratedIterations(passphraseLength: passphrase.utf8.count))
        self.header = header
        isDirty = true
        try write()
    }

    /// Make a new device key on this Mac and wrap the vault key with it (a first
    /// enrolment after a passphrase-only unlock on a new Mac, or a fresh key).
    public func enrolDevice() throws {
        guard state == .unlocked, let key, var header else { throw VaultError.locked }
        for store in deviceStores { try? store.destroy() }
        guard let (store, wrapped) = enrolAnyDevice(key) else {
            throw NSError(domain: "FoolscapSecrets", code: 1, userInfo: [NSLocalizedDescriptionKey: deviceEnrolError ?? "No device key store accepted a key."])
        }
        header.wraps[VaultHeader.deviceSlot] = wrapped
        header.deviceKind = store.kindID
        self.header = header
        isDirty = true
        try write()
    }

    /// The markdown as it stands, for an export the user has confirmed.
    public func plaintext() -> String? { state == .unlocked ? document?.serialized() : nil }
}
