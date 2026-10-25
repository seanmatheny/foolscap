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

    @MainActor @Test func insertAllSplitsFilesAndSkipsDuplicates() {
        var doc = SecretsDocument.parse("## Beta\n- b: 2\n")
        let pasted = "Some notes first\n\n## Alpha #work\n- user: a\n- password: `pw`\n\n## Gamma\n```\nkey\n```\n## \n- user: \n## Beta\n- b: 2\n"
        let first = doc.insertAll(pasted)
        #expect(first.added.count == 2 && first.skipped == 1)
        #expect(doc.entries.map(\.title) == ["Alpha", "Beta", "Gamma"])
        #expect(doc.entries[0].raw == "## Alpha #work\n- user: a\n- password: `pw`\n")
        #expect(doc.entries[2].blocks.count == 1)
        let again = doc.insertAll(pasted)
        #expect(again.added.isEmpty && again.skipped == 3)
        #expect(doc.entries.count == 3)
        // Other heading levels start entries too (not inside a fence), stored as `## `.
        let levels = doc.insertAll("# Delta\n- d: 4\n### Epsilon\n```\n# not a heading\n```\n")
        #expect(levels.added.count == 2)
        #expect(doc.entries.map(\.title) == ["Alpha", "Beta", "Delta", "Epsilon", "Gamma"])
        #expect(doc.entries[3].raw == "## Epsilon\n```\n# not a heading\n```\n")
        // No heading at all: one entry titled by its first line, as typed into the new card.
        #expect(doc.insertAll("Zeta\n- z: 6").added.count == 1)
        #expect(doc.entries.last?.raw == "## Zeta\n- z: 6\n")
        // A list pasted after the new card's `## `: its introduction is a bare heading
        // (dropped), the first real heading doubles up, the template's lines tail the end.
        let card = "## A few entries\n\n# Eta #x\n- e: 7\n\n## Theta\n- t: 8\n- user: \n- password: ``\n- site: \n"
        let cleaned = SecretsSection.withoutTemplateLeftovers(card)
        #expect(SecretsDocument.pieces(of: cleaned) == ["## Eta #x\n- e: 7\n", "## Theta\n- t: 8\n"])
        // A single card keeps its empty lines and a bare title.
        #expect(SecretsSection.withoutTemplateLeftovers("## Iota\n- user: \n") == "## Iota\n- user: \n")
        #expect(SecretsDocument.pieces(of: "## Iota\n") == ["## Iota\n"])
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

    @Test func wrongDeviceKeyIsNamed() throws {
        let wrapped = try AgreementWrap.wrap(VaultKey.random(), recipient: P256.KeyAgreement.PrivateKey().publicKey)
        #expect(throws: KeyWrapError.wrongDeviceKey) { try AgreementWrap.unwrap(wrapped, using: P256.KeyAgreement.PrivateKey()) }
        let store = MemoryKeyStore()
        let pub = try store.enrol()
        #expect(try store.enrol().rawRepresentation == pub.rawRepresentation)
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
            // The store keeps the Mac's one key: a second enrolment (another vault) returns it.
            let blob = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-enclave-\(UUID().uuidString).bin")
            let store = EnclaveKeyStore(blobURL: blob)
            let first = try store.enrol().rawRepresentation
            #expect(try store.enrol().rawRepresentation == first)
            try store.destroy()
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

    /// Two devices, one vault file: each enrols a key of its own (0.19) and neither
    /// disturbs the other's; a slot removed on one device shuts that device out, the
    /// passphrase still gets in.
    @MainActor @Test func everyDeviceGetsASlotOfItsOwn() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-secrets-devices-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("vault.foolscap-secrets")
        let macStore = MemoryKeyStore(), phoneStore = MemoryKeyStore()
        let mac = SecretsVault(url: file, deviceStores: [macStore])
        mac.passphraseIterations = 1000
        mac.load()
        try mac.create(passphrase: "open sesame")
        #expect(mac.hasDeviceWrap && mac.header?.devices?.count == 1 && mac.header?.wraps[VaultHeader.deviceSlot] == nil)
        mac.edit { $0.insert("## GitHub\n- password: `x`") }
        mac.saveNow()
        mac.lock()

        // The phone: no key for this vault yet, so the passphrase, then its own slot.
        let phone = SecretsVault(url: file, deviceStores: [phoneStore])
        phone.passphraseIterations = 1000
        phone.load()
        #expect(phone.state == .locked && !phone.hasDeviceWrap && phone.canEnrolDevice)
        await phone.unlockWithDevice()
        #expect(phone.state == .locked && phone.lastError != nil)
        await phone.unlock(passphrase: "open sesame")
        #expect(phone.state == .unlocked)
        try phone.enrolDevice()
        #expect(phone.hasDeviceWrap && phone.header?.devices?.count == 2)
        #expect(phone.thisDeviceIDs.count == 1 && phone.enrolledDevices.first.map { phone.thisDeviceIDs.contains($0.id) } == true)
        phone.lock()
        await phone.unlockWithDevice()
        #expect(phone.state == .unlocked && phone.document?.entries.map(\.title) == ["GitHub"])
        phone.lock()

        // The Mac still opens with its key, sees both devices, and can drop the phone's.
        mac.load()
        await mac.unlockWithDevice()
        #expect(mac.state == .unlocked && mac.enrolledDevices.count == 2)
        let other = try #require(mac.enrolledDevices.first { !mac.thisDeviceIDs.contains($0.id) })
        try mac.removeDevice(id: other.id)
        #expect(mac.header?.devices?.count == 1 && mac.hasDeviceWrap)
        mac.lock()
        phone.load()
        #expect(!phone.hasDeviceWrap)
        await phone.unlock(passphrase: "open sesame")
        #expect(phone.state == .unlocked)
    }

    /// A vault from before 0.19 has one "device" slot and no list: the Mac whose key fits
    /// it still opens it, takes a named slot of its own on the way, and keeps the old slot
    /// (older builds read it) until it is removed from the list.
    @MainActor @Test func legacyMacSlotStillOpensAndGetsNamed() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-secrets-legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("vault.foolscap-secrets")
        let store = MemoryKeyStore()
        let publicKey = try store.enrol()
        let key = VaultKey.random()
        let now = Date()
        let header = VaultHeader(created: now, modified: now,
                                 wraps: [VaultHeader.deviceSlot: try AgreementWrap.wrap(key, recipient: publicKey),
                                         VaultHeader.passphraseSlot: try PassphraseWrap.wrap(key, passphrase: "words", iterations: 1000)],
                                 deviceKind: store.kindID)
        // Encoded without a `devices` key at all, as 0.18 wrote it.
        let json = try #require(String(data: try VaultEnvelope.encoder.encode(header), encoding: .utf8))
        #expect(!json.contains("devices"))
        try VaultEnvelope.encode(header: header, plaintext: Data("## Old\n- pin: `1`\n".utf8), key: key).write(to: file)

        let vault = SecretsVault(url: file, deviceStores: [store])
        vault.passphraseIterations = 1000
        vault.load()
        #expect(vault.state == .locked && vault.hasDeviceWrap)
        #expect(vault.enrolledDevices.map(\.id) == [VaultHeader.legacyDeviceID] && vault.thisDeviceIDs.contains(VaultHeader.legacyDeviceID))
        await vault.unlockWithDevice()
        #expect(vault.state == .unlocked && vault.document?.entries.map(\.title) == ["Old"])
        let devices = try #require(vault.header?.devices)
        #expect(devices.count == 1 && devices[0].id == DeviceWrap.fingerprint(publicKey) && vault.header?.wraps[VaultHeader.deviceSlot] != nil)
        #expect(vault.enrolledDevices.map(\.id) == [devices[0].id, VaultHeader.legacyDeviceID])

        // The old slot can go now; the named one opens the vault.
        try vault.removeDevice(id: VaultHeader.legacyDeviceID)
        #expect(vault.header?.wraps[VaultHeader.deviceSlot] == nil && vault.header?.deviceKind == nil && vault.hasDeviceWrap)
        vault.lock()
        await vault.unlockWithDevice()
        #expect(vault.state == .unlocked)
        // A second unlock through the named slot adds nothing more.
        #expect(vault.header?.devices?.count == 1)
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

// MARK: - The editing form

@Suite struct SecretFormTests {
    @Test func readsAnEntryAndWritesItBack() {
        let raw = "## GitHub #work #dev\n- user: smat924\n- password: `Tr0ub4dor&3`\n- site: https://github.com/#login\n```asc\nline one\nline two\n```\nWork org account.\nSSO through Okta.\n"
        let entry = SecretsDocument.parse(raw).entries[0]
        // A web address's anchor is not a tag.
        #expect(entry.tags == ["work", "dev"])
        let form = SecretForm(entry: entry)
        #expect(form.title == "GitHub" && form.tags == ["work", "dev"])
        #expect(form.fields.map(\.label) == ["user", "password", "site"])
        #expect(form.fields[1].isSecret && form.fields[1].value == "Tr0ub4dor&3")
        #expect(form.notes == "Work org account.\nSSO through Okta.")
        #expect(form.markdown() == raw)
        #expect(SecretForm(entry: SecretsDocument.parse(form.markdown()).entries[0]).sameContent(as: form))
    }

    @Test func keepsTypedTextFromReadingAsMarkdown() {
        var form = SecretForm.blank()
        form.title = "  Odd\nentry "
        form.tags = ["#a", "b c", "a"]
        form.fields[0].value = "bob"
        form.fields[1].value = "`tick`s and\nlines"
        form.fields[2].value = ""
        form.fields.append(.init(label: "pin: code`", value: "12", isSecret: false))
        form.notes = "## not a heading\n- not: a field\n```\n\\- kept backslash\nplain\n\n"
        let md = form.markdown()
        #expect(md == "## Odd entry #a #b #c\n- user: bob\n- password: ``tick`s and lines`\n- pin code: 12\n\\## not a heading\n\\- not: a field\n\\```\n\\\\- kept backslash\nplain\n")
        let back = SecretsDocument.parse(md).entries
        #expect(back.count == 1)
        let entry = back[0]
        #expect(entry.title == "Odd entry" && entry.tags == ["a", "b", "c"])
        #expect(entry.fields.map(\.label) == ["user", "password", "pin code"])
        #expect(entry.fields[1].isSecret && entry.fields[1].value == "`tick`s and lines")
        #expect(entry.blocks.isEmpty)
        #expect(entry.notes == ["## not a heading", "- not: a field", "```", "\\- kept backslash", "plain"])
    }

    @Test func emptyFieldsAreFieldsNotNotes() {
        let entry = SecretsDocument.parse(SecretsDocument.template).entries[0]
        #expect(entry.fields.map(\.label) == ["user", "password", "site"])
        #expect(entry.fields.allSatisfy(\.value.isEmpty) && entry.notes.isEmpty)
        #expect(SecretForm(entry: entry).markdown(keepingEmpty: true) == "## \n- user:\n- password: ``\n- site:\n")
        #expect(SecretForm(entry: entry).markdown() == "## \n")
    }

    @MainActor @Test func sectionEditsThroughTheForm() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-secret-form-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = NotesFolder(root: tmp)
        try folder.ensureLayout()
        let library = try NotebookLibrary(folder: folder, indexPath: TestIndex.path)
        let vault = SecretsVault(url: tmp.appendingPathComponent("vault.foolscap-secrets"), deviceStores: [MemoryKeyStore()])
        vault.passphraseIterations = 1000
        let defaults = UserDefaults(suiteName: "foolscap-secret-form-\(UUID().uuidString)")!
        let section = SecretsSection(library: library, vault: vault, defaults: defaults)
        vault.load()
        try section.createVault(passphrase: "words")

        // A new card: a pasted address goes into the site field as it is.
        section.beginAdd()
        #expect(section.form != nil && section.draft == nil)
        section.form?.title = "Bank"
        section.form?.fields[1].value = "hunter2"
        section.form?.fields[2].value = "https://online.example.bank/login#top"
        section.commitEdit()
        #expect(section.form == nil && !section.isEditing)
        let bank = try #require(section.document?.entries.first)
        #expect(bank.title == "Bank" && bank.tags.isEmpty)
        #expect(bank.fields.map(\.label) == ["password", "site"] && bank.changed != nil)
        #expect(bank.fields[1].value == "https://online.example.bank/login#top")

        // An untouched edit rewrites nothing; a cleared title changes nothing.
        section.beginEdit(bank)
        section.commitEdit()
        #expect(section.document?.entries.first?.raw == bank.raw)
        section.beginEdit(bank)
        section.form?.title = " "
        section.commitEdit()
        #expect(section.document?.entries.first?.raw == bank.raw)

        // Through the text and back: the form carries what was typed.
        section.beginEdit(bank)
        section.form?.tags = ["money"]
        section.editAsText()
        #expect(section.form == nil && section.draft?.text.hasPrefix("## Bank #money\n") == true)
        #expect(section.canEditAsForm)
        section.editAsForm()
        #expect(section.form?.tags == ["money"] && section.form?.fields.count == 2)
        section.commitEdit()
        #expect(section.document?.entries.first?.tags == ["money"])

        // An untouched new card shows the template as text; a list there makes several cards.
        section.beginAdd()
        section.editAsText()
        #expect(section.draft?.text == SecretsDocument.template)
        section.draft?.setText("## Alpha\n- a: 1\n## Zed\n- z: 2\n")
        #expect(!section.canEditAsForm)
        section.commitEdit()
        #expect(section.document?.entries.map(\.title) == ["Alpha", "Bank", "Zed"])
    }
}
