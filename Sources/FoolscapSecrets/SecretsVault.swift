import Foundation
import CryptoKit
import LocalAuthentication
import FoolscapStore

/// One enrolled device's wrapped copy of the vault key (since 0.19). Its id is the
/// fingerprint of the device's public key, so a device finds its own slot by its key
/// alone, nothing stored beside it; the name is for the Settings pane's list.
public struct DeviceWrap: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// Which store holds the key (`DeviceKeyStore.kindID`).
    public var kind: String
    /// "Sean's MacBook Pro", "iPhone".
    public var name: String
    public var enrolled: Date
    public var wrapped: WrappedKey

    /// 24 hex characters of SHA-256 over the key's X9.63 bytes.
    public static func fingerprint(_ key: P256.KeyAgreement.PublicKey) -> String {
        SHA256.hash(data: key.x963Representation).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

/// What sits in front of the ciphertext. Its stored bytes are the GCM's additional
/// authenticated data, so a header edited on disk fails to open. Still format 1: the
/// `devices` list (0.19) is an addition older builds skip over, and they still open
/// the vault with the passphrase, or with the legacy "device" slot while it is kept.
public struct VaultHeader: Codable, Hashable, Sendable {
    public var format = 1
    public var cipher = "AES-256-GCM"
    public var created: Date
    public var modified: Date
    /// "passphrase" (the recovery passphrase) and, in vaults from before 0.19, "device":
    /// the one Mac's key, before devices had slots of their own.
    public var wraps: [String: WrappedKey]
    /// Which device key store made the legacy "device" wrap (`DeviceKeyStore.kindID`).
    public var deviceKind: String?
    /// One wrapped key per enrolled device; absent in files from before 0.19.
    public var devices: [DeviceWrap]?

    public static let deviceSlot = "device", passphraseSlot = "passphrase"
    /// The legacy slot's id in `enrolledDevices`, so it can be removed like the others.
    public static let legacyDeviceID = "legacy"
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
        case .noSuchWrap(let s): return s == VaultHeader.deviceSlot ? "\(DeviceAuth.biometryName) is not set up for this vault on this \(DeviceAuth.deviceWord)." : "This vault has no recovery passphrase."
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
    public private(set) var header: VaultHeader? {
        didSet { refreshDeviceSlot() }
    }
    /// The slot this device's key opens, found once per header change (the stores'
    /// keys are read from disk to fingerprint them, not something for a view body).
    private var thisDeviceSlot: DeviceSlot?
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

    /// A wrapped key this device can open, and the store whose key opens it.
    struct DeviceSlot {
        let store: any DeviceKeyStore
        let wrapped: WrappedKey
        /// The pre-0.19 "device" slot rather than one of this device's own.
        let legacy: Bool
    }

    /// This device's slot: the one fingerprinted for a key its stores hold; on a Mac,
    /// failing that, the legacy "device" slot when a store of the kind that made it is
    /// enrolled (the slot was always a Mac's, so a phone never takes it for its own).
    private func findDeviceSlot() -> DeviceSlot? {
        guard let header else { return nil }
        for store in deviceStores where store.isEnrolled {
            guard let publicKey = try? store.publicKey() else { continue }
            let id = DeviceWrap.fingerprint(publicKey)
            if let wrap = header.devices?.first(where: { $0.id == id }) { return DeviceSlot(store: store, wrapped: wrap.wrapped, legacy: false) }
        }
        #if os(macOS)
        if let legacy = header.wraps[VaultHeader.deviceSlot], let kind = header.deviceKind,
           let store = deviceStores.first(where: { $0.kindID == kind }), store.isEnrolled {
            return DeviceSlot(store: store, wrapped: legacy, legacy: true)
        }
        #endif
        return nil
    }

    private func refreshDeviceSlot() { thisDeviceSlot = findDeviceSlot() }

    /// The store that opens this vault here (or the preferred one before enrolment).
    public var deviceStore: (any DeviceKeyStore)? { thisDeviceSlot?.store ?? deviceStores.first }
    /// This device has a key that opens the vault.
    public var hasDeviceWrap: Bool { thisDeviceSlot != nil }
    /// A device key store is there to enrol with.
    public var canEnrolDevice: Bool { !deviceStores.isEmpty }
    public var hasPassphraseWrap: Bool { header?.wraps[VaultHeader.passphraseSlot] != nil }

    /// Every device with a slot, this one's first, the legacy Mac slot (if still there)
    /// last under its own id.
    public var enrolledDevices: [DeviceWrap] {
        guard let header else { return [] }
        var list = header.devices ?? []
        let mine = thisDeviceIDs
        list.sort { (mine.contains($0.id) ? 0 : 1, $0.enrolled) < (mine.contains($1.id) ? 0 : 1, $1.enrolled) }
        if let legacy = header.wraps[VaultHeader.deviceSlot] {
            let kind = header.deviceKind ?? ""
            let name = kind == "login-keychain" ? "A Mac's keychain (enrolled before 0.19)" : "A Mac's Touch ID (enrolled before 0.19)"
            list.append(DeviceWrap(id: VaultHeader.legacyDeviceID, kind: kind, name: name, enrolled: header.created, wrapped: legacy))
        }
        return list
    }

    /// The slot ids this device's keys answer to (the legacy id too when it opened here).
    public var thisDeviceIDs: Set<String> {
        var ids = Set(deviceStores.compactMap { store -> String? in
            guard store.isEnrolled, let key = try? store.publicKey() else { return nil }
            return DeviceWrap.fingerprint(key)
        })
        if thisDeviceSlot?.legacy == true { ids.insert(VaultHeader.legacyDeviceID) }
        return ids
    }
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
    /// store accepts, with this device's key. Writes an empty vault and opens it.
    public func create(passphrase: String) throws {
        let key = VaultKey.random()
        var wraps: [String: WrappedKey] = [:]
        wraps[VaultHeader.passphraseSlot] = try PassphraseWrap.wrap(key, passphrase: passphrase, iterations: passphraseIterations ?? PassphraseWrap.calibratedIterations(passphraseLength: passphrase.utf8.count))
        let now = Date()
        var header = VaultHeader(created: now, modified: now, wraps: wraps, deviceKind: nil)
        if let slot = enrolAnyDevice(key) { header.devices = [slot] }
        self.key = key
        self.header = header
        document = SecretsDocument()
        isDirty = true
        state = .unlocked
        try write()
    }

    /// Wrap the key for this device: the first store that has (or makes) a key.
    private func enrolAnyDevice(_ key: VaultKey) -> DeviceWrap? {
        var problems: [String] = []
        for store in deviceStores {
            do {
                let publicKey = try store.enrol()
                let wrapped = try AgreementWrap.wrap(key, recipient: publicKey)
                deviceEnrolError = problems.isEmpty ? nil : problems.joined(separator: " ")
                return DeviceWrap(id: DeviceWrap.fingerprint(publicKey), kind: store.kindID, name: DeviceAuth.deviceName, enrolled: Date(), wrapped: wrapped)
            } catch {
                problems.append("\(store.displayName): \(error.localizedDescription)")
            }
        }
        deviceEnrolError = problems.joined(separator: " ")
        return nil
    }

    /// Touch ID or Face ID (or the password or passcode): the device key unwraps the
    /// vault key off the main thread while the system's sheet is up.
    public func unlockWithDevice() async {
        guard state == .locked, let slot = thisDeviceSlot else {
            lastError = VaultError.noSuchWrap(VaultHeader.deviceSlot).localizedDescription
            return
        }
        state = .unlocking
        lastError = nil
        let store = slot.store, wrapped = slot.wrapped
        do {
            let parsed = try VaultEnvelope.decode(try Data(contentsOf: url))
            let key = try await Task.detached(priority: .userInitiated) {
                let context = LAContext()
                // The Mac's sheet reads "Foolscap is trying to …"; the phone's shows the reason on its own.
                context.localizedReason = DeviceAuth.isPhone ? "Unlock your secrets" : "unlock your secrets"
                context.localizedFallbackTitle = DeviceAuth.fallbackTitle
                let device = try store.privateKey(context: context)
                return try AgreementWrap.unwrap(wrapped, using: device)
            }.value
            try finishUnlock(key: key, parsed: parsed)
            // A vault from before 0.19 opened through its one Mac slot: this Mac takes a slot
            // of its own as well, so the device list names it. The legacy slot stays for
            // older builds until it is removed from the list.
            if slot.legacy, state == .unlocked { try? enrolDevice() }
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
            case .biometryNotAvailable, .biometryNotEnrolled: return "\(DeviceAuth.biometryName) is not available; use the recovery passphrase."
            case .biometryLockout: return "\(DeviceAuth.biometryName) is locked out; use \(DeviceAuth.fallbackName) or the recovery passphrase."
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
        // A device key made or dropped meanwhile (tests; a reset) shows on the padlock page.
        refreshDeviceSlot()
    }

    // MARK: Re-keying (unlocked only)

    public func changePassphrase(to passphrase: String) throws {
        guard state == .unlocked, let key, var header else { throw VaultError.locked }
        header.wraps[VaultHeader.passphraseSlot] = try PassphraseWrap.wrap(key, passphrase: passphrase, iterations: passphraseIterations ?? PassphraseWrap.calibratedIterations(passphraseLength: passphrase.utf8.count))
        self.header = header
        isDirty = true
        try write()
    }

    /// Give this device a slot: wrap the vault key with its key (the one it already has,
    /// which every other vault on it is wrapped against; a new one only when it has none)
    /// and file it under the key's fingerprint, replacing any older slot of the same key.
    /// A first enrolment after a passphrase unlock on a new device, or a repair. Other
    /// devices' slots are not touched.
    public func enrolDevice() throws {
        guard state == .unlocked, let key, var header else { throw VaultError.locked }
        guard let slot = enrolAnyDevice(key) else {
            throw NSError(domain: "FoolscapSecrets", code: 1, userInfo: [NSLocalizedDescriptionKey: deviceEnrolError ?? "No device key store accepted a key."])
        }
        var devices = header.devices ?? []
        devices.removeAll { $0.id == slot.id }
        devices.append(slot)
        header.devices = devices
        self.header = header
        isDirty = true
        try write()
    }

    /// Drop a device's slot (a phone that is gone; the legacy Mac slot once this Mac has
    /// one of its own). The passphrase still opens the vault whatever is removed.
    public func removeDevice(id: String) throws {
        guard state == .unlocked, var header else { throw VaultError.locked }
        if id == VaultHeader.legacyDeviceID {
            header.wraps[VaultHeader.deviceSlot] = nil
            header.deviceKind = nil
        } else {
            header.devices?.removeAll { $0.id == id }
        }
        self.header = header
        isDirty = true
        try write()
    }

    /// The markdown as it stands, for an export the user has confirmed.
    public func plaintext() -> String? { state == .unlocked ? document?.serialized() : nil }
}
