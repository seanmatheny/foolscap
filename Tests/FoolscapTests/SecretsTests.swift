import Testing
import Foundation
import CryptoKit
@testable import FoolscapCore
@testable import FoolscapStore
@testable import FoolscapSecrets

// MARK: - Markdown

@Suite struct SecretsMarkdownTests {
    static let sample = """
    Some preamble.

    ## GitHub #work #dev
    - user: smat924
    - password: `Tr0ub4dor&3`
    - site: https://github.com
    - changed: 2026-10-03
    Work org account.

    ## Google (personal)
    - user: smat924@gmail.com
    - #personal
    ```asc
    -----BEGIN PGP PRIVATE KEY BLOCK-----
    ## not a heading
    -----END PGP PRIVATE KEY BLOCK-----
    ```
    ## école
    - pin: `1234`
    """

    @Test func parsesEntriesFieldsTagsBlocksAndNotes() {
        let doc = SecretsDocument.parse(Self.sample)
        #expect(doc.preamble == "Some preamble.\n\n")
        #expect(doc.entries.count == 3)
        let github = doc.entries[0]
        #expect(github.title == "GitHub")
        #expect(github.tags == ["work", "dev"])
        #expect(github.fields.map(\.label) == ["user", "password", "site"])
        #expect(github.fields[1].isSecret && github.fields[1].value == "Tr0ub4dor&3")
        #expect(github.fields[2].isURL)
        #expect(github.notes == ["Work org account."])
        #expect(github.changed.map { SecretEntry.dateFormatter.string(from: $0) } == "2026-10-03")
        let google = doc.entries[1]
        #expect(google.tags == ["personal"])
        #expect(google.blocks.count == 1 && google.blocks[0].info == "asc" && google.blocks[0].lineCount == 3)
        #expect(google.summary == "smat924@gmail.com")
        #expect(doc.entries[2].letter == .letter("E"))
        #expect(SecretLetter.filing(for: "7-Zip") == .other)
        #expect(SecretLetter.filing(for: "") == .other)
    }

    @Test func roundTripsByteForByte() {
        let doc = SecretsDocument.parse(Self.sample)
        #expect(doc.serialized() == Self.sample)
        let noNewline = "## A\n- x: y"
        #expect(SecretsDocument.parse(noNewline).serialized() == noNewline)
    }

    @Test func searchSkipsSecrets() {
        let doc = SecretsDocument.parse(Self.sample)
        #expect(doc.matching("troub").isEmpty)
        #expect(doc.matching("1234").isEmpty)
        #expect(doc.matching("ORG account").map(\.title) == ["GitHub"])
        #expect(doc.matching("ecole").map(\.title) == ["école"])
        #expect(doc.matching("personal").map(\.title) == ["Google (personal)"])
    }

    @Test func insertFilesByLetterAndStamps() {
        var doc = SecretsDocument.parse("## Alpha\n- a: 1\n## Gamma\n- g: 3\n")
        let id = doc.insert("Beta\n- b: 2")
        #expect(id != nil)
        #expect(doc.entries.map(\.title) == ["Alpha", "Beta", "Gamma"])
        #expect(doc.entries[1].raw == "## Beta\n- b: 2\n")
        doc.stamp(id: doc.entries[1].id, changed: SecretEntry.dateFormatter.date(from: "2026-10-10")!)
        #expect(doc.entries[1].raw == "## Beta\n- b: 2\n- changed: 2026-10-10\n")
        doc.stamp(id: doc.entries[1].id, changed: SecretEntry.dateFormatter.date(from: "2026-10-11")!)
        #expect(doc.entries[1].raw == "## Beta\n- b: 2\n- changed: 2026-10-11\n")
        #expect(doc.insert("   \n") == nil)
        #expect(doc.entries.count == 3)
    }

    @Test func replaceSplitsAndRemoves() {
        var doc = SecretsDocument.parse("## One\n- a: 1\n## Two\n- b: 2")
        let ids = doc.replace(id: doc.entries[0].id, with: "## One\n- a: 1\n## One and a half\n- c: 3")
        #expect(ids.count == 2)
        #expect(doc.entries.map(\.title) == ["One", "One and a half", "Two"])
        #expect(doc.serialized() == "## One\n- a: 1\n## One and a half\n- c: 3\n## Two\n- b: 2\n")
        doc.replace(id: doc.entries[2].id, with: "")
        #expect(doc.entries.map(\.title) == ["One", "One and a half"])
        doc.remove(id: doc.entries[0].id)
        #expect(doc.entries.map(\.title) == ["One and a half"])
    }

    @Test func removesTags() {
        var doc = SecretsDocument.parse("## One #work #dev\n- a: 1\n- #work\n- #personal #work\n")
        doc.removeTag("work", from: doc.entries[0].id)
        #expect(doc.entries[0].raw == "## One #dev\n- a: 1\n- #personal\n")
        #expect(doc.entries[0].tags == ["dev", "personal"])
    }

    @Test func groupsLettersToFit() {
        #expect(LetterGroup.groups(capacity: 27).count == 27)
        #expect(LetterGroup.groups(capacity: 27).map(\.label).first == "A")
        let short = LetterGroup.groups(capacity: 20)
        #expect(short.count == 20)
        #expect(short.last?.label == "#")
        #expect(short.contains { $0.label == "X–Z" })
        let tiny = LetterGroup.groups(capacity: 8)
        #expect(tiny.count == 8)
        #expect(tiny.flatMap(\.letters) == SecretLetter.all)
        let layout = ThumbIndexLayout(pageHeight: 710)
        #expect(layout.groups.count == 27 && layout.pitch > 25)
        #expect(ThumbIndexLayout(pageHeight: 510).groups.count < 27)
    }
}

// MARK: - Crypto and the vault

@Suite struct SecretsVaultTests {
    @Test func passphraseWrapRoundTripsAndRefusesTheWrongOne() throws {
        let key = VaultKey.random()
        let wrapped = try PassphraseWrap.wrap(key, passphrase: "correct horse", iterations: 1000)
        #expect(try PassphraseWrap.unwrap(wrapped, passphrase: "correct horse").bytes == key.bytes)
        #expect(throws: KeyWrapError.wrongPassphrase) { try PassphraseWrap.unwrap(wrapped, passphrase: "wrong horse") }
    }

    @Test func agreementWrapRoundTripsWithASoftwareKey() throws {
        let device = P256.KeyAgreement.PrivateKey()
        let key = VaultKey.random()
        let wrapped = try AgreementWrap.wrap(key, recipient: device.publicKey)
        #expect(try AgreementWrap.unwrap(wrapped, using: device).bytes == key.bytes)
        let other = P256.KeyAgreement.PrivateKey()
        #expect(throws: (any Error).self) { try AgreementWrap.unwrap(wrapped, using: other) }
    }

    /// The Secure Enclave spike: creation and one agreement, without user presence
    /// so it needs no Touch ID. Reports what this (unsigned) test process is allowed to do.
    @Test func secureEnclaveSpike() throws {
        guard SecureEnclave.isAvailable else { print("Secure Enclave: not available on this Mac"); return }
        do {
            let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey()
            let key = VaultKey.random()
            let wrapped = try AgreementWrap.wrap(key, recipient: enclave.publicKey)
            let again = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: enclave.dataRepresentation)
            #expect(try AgreementWrap.unwrap(wrapped, using: again).bytes == key.bytes)
            print("Secure Enclave: key created and agreement round-tripped")
        } catch {
            print("Secure Enclave: refused in the test process: \(error)")
        }
    }

    @Test func envelopeAuthenticatesTheHeader() throws {
        let key = VaultKey.random()
        let header = VaultHeader(created: Date(), modified: Date(), wraps: [:], deviceKind: nil)
        let data = try VaultEnvelope.encode(header: header, plaintext: Data("## A\n".utf8), key: key)
        let parsed = try VaultEnvelope.decode(data)
        #expect(try VaultEnvelope.open(parsed, key: key) == Data("## A\n".utf8))
        var tampered = parsed
        tampered.headerBytes[0] = tampered.headerBytes[0] ^ 1
        #expect(throws: VaultError.damaged) { try VaultEnvelope.open(tampered, key: key) }
        #expect(throws: VaultError.notAVault) { try VaultEnvelope.decode(Data("hello".utf8)) }
    }

    @MainActor @Test func vaultCreatesLocksAndReopensBothWays() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-secrets-\(UUID().uuidString)")
        let store = MemoryKeyStore()
        let vault = SecretsVault(url: dir.appendingPathComponent("vault.foolscap-secrets"), deviceStores: [store])
        vault.passphraseIterations = 1000
        vault.saveDelay = .milliseconds(10)
        vault.load()
        #expect(vault.state == .absent)
        try vault.create(passphrase: "open sesame")
        #expect(vault.state == .unlocked && vault.hasDeviceWrap && vault.hasPassphraseWrap)
        vault.edit { $0.insert("## GitHub\n- password: `x`") }
        // The debounced save runs on the main actor; other suites may hold it for a moment.
        for _ in 0..<100 where vault.isDirty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!vault.isDirty)
        let bytes = try Data(contentsOf: vault.url)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("GitHub"))
        vault.lock()
        #expect(vault.state == .locked && vault.document == nil)

        await vault.unlockWithDevice()
        #expect(vault.state == .unlocked)
        #expect(vault.document?.entries.map(\.title) == ["GitHub"])
        vault.lock()

        await vault.unlock(passphrase: "wrong")
        #expect(vault.state == .locked && vault.lastError == KeyWrapError.wrongPassphrase.localizedDescription)
        await vault.unlock(passphrase: "open sesame")
        #expect(vault.state == .unlocked)

        try vault.changePassphrase(to: "new words")
        vault.lock()
        await vault.unlock(passphrase: "new words")
        #expect(vault.state == .unlocked)

        // Another Mac: no device key, the passphrase gets in, then enrols.
        store.key = nil
        vault.lock()
        #expect(!vault.hasDeviceWrap)
        await vault.unlock(passphrase: "new words")
        try vault.enrolDevice()
        #expect(vault.hasDeviceWrap)
        vault.lock()
        await vault.unlockWithDevice()
        #expect(vault.state == .unlocked)
        try? FileManager.default.removeItem(at: dir)
    }

    @MainActor @Test func idleLockPolicy() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let lock = AutoLock(lockAfter: 300) { now }
        var locked = false
        lock.onLock = { locked = true }
        lock.start()
        #expect(!lock.shouldLock(at: now))
        now += 299
        #expect(!lock.shouldLock(at: now))
        lock.noteActivity()
        now += 299
        #expect(!lock.shouldLock(at: now))
        now += 2
        #expect(lock.shouldLock(at: now))
        lock.tick()
        #expect(locked && !lock.isRunning && lock.locksAt == nil)
    }

    @Test func secretsFolderIsCarriedButNeverIndexed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-notes-\(UUID().uuidString)")
        let folder = NotesFolder(root: root)
        try folder.ensureLayout()
        try FileManager.default.createDirectory(at: folder.secretsDirectory, withIntermediateDirectories: true)
        try Data("FSCV".utf8).write(to: folder.secretsDirectory.appendingPathComponent("vault.foolscap-secrets"))
        #expect(folder.listIndexableNotes(includingScribe: true, includingHighlights: true).isEmpty)
        #expect(NotesFolder.notebookFiles(under: root).map(\.relativePath) == ["Secrets/vault.foolscap-secrets"])
        try? FileManager.default.removeItem(at: root)
    }
}
