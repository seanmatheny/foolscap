import SwiftUI
import AppKit
import FoolscapCore
import FoolscapStore
import FoolscapEditor

/// The Secrets tab: an encrypted address book of passwords, keys and codes,
/// filed A–Z, unlocked with Touch ID and locked again when idle.
@MainActor
@Observable
public final class SecretsSection: NotebookSection {
    public static let sectionID = "secrets"
    public static let enabledKey = "secretsEnabled"
    public static let lockMinutesKey = "secretsLockMinutes"
    public static let lockOnLeaveKey = "secretsLockOnLeave"
    public static let defaultLockMinutes = 5
    public static let vaultFileName = "vault.foolscap-secrets"
    /// The draft being edited is a marker, not an entry id.
    public static let newEntryID = "new"

    public let id = SecretsSection.sectionID
    /// The sixth tab colour (pewter) is its own.
    public let tab = TabAppearance(label: "Secrets", systemImage: "lock.fill", colorIndex: 5, shortcut: "y")

    public let library: NotebookLibrary
    public let vault: SecretsVault
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let autoLock: AutoLock
    @ObservationIgnored private var copiedReset: Task<Void, Never>?

    // Page state (in memory only; nothing here is written anywhere).
    public var selectedLetter: SecretLetter = .letter("A")
    public var searchText = ""
    /// Tag chips in the strip that are on: an entry must carry every one of them.
    public var selectedTags: [String] = []
    /// A letter clicked after a tag was chosen narrows the tag's entries to that letter;
    /// choosing a tag shows them across every letter again.
    public private(set) var letterPinned = false
    public private(set) var editingID: String?
    public private(set) var draft: NoteDocument?
    /// Titles folded to their one-line row.
    public var collapsed: Set<String> = []
    /// Field and block keys shown in the clear (`"<entry id>/<label>"`, `"<entry id>/block/<n>"`).
    public var revealed: Set<String> = []
    public private(set) var copiedKey: String?
    public private(set) var lockedAt: Date?
    /// Bumped when the lock deadline moves, so the countdown re-reads it.
    public private(set) var unlockGeneration = 0

    public static func defaultVault(for library: NotebookLibrary) -> SecretsVault {
        let support = AppSupport.directory.appendingPathComponent("Secrets", isDirectory: true)
        var stores: [any DeviceKeyStore] = []
        if EnclaveKeyStore.isAvailable { stores.append(EnclaveKeyStore(blobURL: support.appendingPathComponent("enclave-key.bin"))) }
        stores.append(KeychainKeyStore())
        return SecretsVault(url: library.folder.secretsDirectory.appendingPathComponent(vaultFileName), deviceStores: stores)
    }

    public init(library: NotebookLibrary, vault: SecretsVault? = nil, defaults: UserDefaults = .standard) {
        self.library = library
        self.vault = vault ?? Self.defaultVault(for: library)
        self.defaults = defaults
        let minutes = defaults.object(forKey: Self.lockMinutesKey) == nil ? Self.defaultLockMinutes : defaults.integer(forKey: Self.lockMinutesKey)
        autoLock = AutoLock(lockAfter: TimeInterval(max(1, minutes)) * 60)
        autoLock.onLock = { [weak self] in self?.lockNow() }
    }

    // MARK: Settings

    public var lockMinutes: Int {
        defaults.object(forKey: Self.lockMinutesKey) == nil ? Self.defaultLockMinutes : max(1, defaults.integer(forKey: Self.lockMinutesKey))
    }
    public var lockOnLeave: Bool { defaults.bool(forKey: Self.lockOnLeaveKey) }

    /// Called by the settings pane after the slider moves: the deadline follows at once.
    public func settingsChanged() {
        autoLock.lockAfter = TimeInterval(lockMinutes) * 60
        unlockGeneration += 1
    }

    // MARK: Lifecycle

    public func start() {
        vault.load()
        lockedAt = nil
    }

    public func stop() {
        lockNow()
        autoLock.stop()
    }

    public var isUnlocked: Bool { vault.state == .unlocked }
    /// When the vault locks if nothing happens; nil while locked.
    public var locksAt: Date? { autoLock.locksAt }

    /// Save, forget the key, show the padlock. Also the quit path (`AppModel.flush`).
    public func lockNow() {
        guard vault.state == .unlocked || vault.state == .unlocking else { return }
        if editingID != nil { commitEdit() }
        vault.lock()
        autoLock.stop()
        editingID = nil
        draft = nil
        revealed = []
        copiedKey = nil
        lockedAt = Date()
    }

    /// `applicationDidResignActive`: write pending edits without locking.
    public func saveIfDirty() { vault.saveNow() }

    /// The tab was turned away from; locks only when the setting asks for it.
    public func didLeaveTab() { if lockOnLeave { lockNow() } }

    public func unlockWithDevice() async {
        await vault.unlockWithDevice()
        if vault.state == .unlocked { didUnlock() }
    }

    public func unlock(passphrase: String) async {
        await vault.unlock(passphrase: passphrase)
        if vault.state == .unlocked { didUnlock() }
    }

    public func createVault(passphrase: String) throws {
        try vault.create(passphrase: passphrase)
        didUnlock()
    }

    private func didUnlock() {
        autoLock.lockAfter = TimeInterval(lockMinutes) * 60
        autoLock.start()
        unlockGeneration += 1
        lockedAt = nil
        // `--secrets-sample` fills an empty (scratch) vault with made-up entries for screenshots.
        if CommandLine.arguments.contains("--secrets-sample"), vault.document?.entries.isEmpty == true {
            let today = Date()
            vault.edit { doc in
                for text in Self.sampleEntries { if let id = doc.insert(text) { doc.stamp(id: id, changed: today) } }
            }
        }
        if let doc = vault.document, !doc.lettersWithEntries.contains(selectedLetter), let first = doc.lettersWithEntries.min() {
            selectedLetter = first
        }
    }

    static let sampleEntries: [String] = [
        "## GitHub #work #dev\n- user: smat924\n- password: `Tr0ub4dor&3-staple`\n- site: https://github.com\nWork org account; SSO through Okta.\n",
        "## Google (personal) #personal\n- user: sean@example.com\n- password: `correct-horse-battery`\n- site: https://accounts.google.com\nBackup email is the uni one.\n",
        "## Gym locker\n- combination: `14-22-38`\n- locker: 14\n",
        "## GPG signing key #dev\n- key id: 0x7A3F 9C2E 1B44 D081\n```asc\n-----BEGIN PGP PRIVATE KEY BLOCK-----\nlQdGBGXkQ2sBEADK8f1x9m2o4u7w0y3z5a6b8c1d2e4f6g8h0i2j4k6l8m0n2o4p6q\n-----END PGP PRIVATE KEY BLOCK-----\n```\nExpires 2027-04.\n",
        "## Apple ID #personal\n- user: sean@example.com\n- password: `pear-tree-2026`\n- site: https://appleid.apple.com\n",
        "## Bank #personal\n- account: 12-3456-7890123-00\n- pin: `4321`\n- site: https://online.example.bank\n",
        "## Wi-Fi at home\n- ssid: Matheny-5G\n- password: `teapot-lemon-42`\n",
        "## Zoom #work\n- user: sean@example.com\n- password: `meeting-room-9`\n- site: https://zoom.us\n",
        "## 1Password emergency kit\n- secret key: `A3-XXXXXX-XXXXXX-XXXXX-XXXXX-XXXXX-XXXXX`\nPrinted copy in the desk drawer.\n",
    ]

    // MARK: What the page shows

    public var document: SecretsDocument? { vault.document }
    public var entryCount: Int { document?.entries.count ?? 0 }
    public var lettersWithEntries: Set<SecretLetter> { document?.lettersWithEntries ?? [] }
    public var knownTags: [String] { document?.tags ?? [] }
    public var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The strip's chips: the vault's tags, most used first, plus any chosen tag that
    /// has since lost its last entry (so it can still be switched off).
    public var stripTags: [String] {
        var tags = knownTags
        for chosen in selectedTags where !tags.contains(chosen) { tags.append(chosen) }
        return tags
    }

    public func toggleTag(_ tag: String) {
        if let i = selectedTags.firstIndex(of: tag) { selectedTags.remove(at: i) } else { selectedTags.append(tag) }
        letterPinned = false
    }

    public func clearTags() {
        selectedTags = []
        letterPinned = false
    }

    /// Search hits and tagged entries are listed across the letters, under letter dividers.
    public var showsAllLetters: Bool { isSearching || (!selectedTags.isEmpty && !letterPinned) }

    private func passesTags(_ entry: SecretEntry) -> Bool { selectedTags.allSatisfy { entry.tags.contains($0) } }

    /// Letters with something to show under the search and tag filters (every letter
    /// with entries when neither is on).
    public var lettersWithMatches: Set<SecretLetter> {
        guard let document else { return [] }
        let pool = isSearching ? document.matching(searchText) : document.entries
        return Set(pool.filter(passesTags).map(\.letter))
    }

    public struct LetterEntries: Identifiable {
        public var letter: SecretLetter
        public var entries: [SecretEntry]
        public var id: SecretLetter { letter }
    }

    /// The cards to show: search hits grouped by letter, or the given letters' entries.
    public func entriesToShow(for letters: [SecretLetter]) -> [LetterEntries] {
        guard let document else { return [] }
        if showsAllLetters {
            let hits = (isSearching ? document.matching(searchText) : document.entries).filter(passesTags)
            return SecretLetter.all.compactMap { letter in
                let under = hits.filter { $0.letter == letter }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                return under.isEmpty ? nil : LetterEntries(letter: letter, entries: under)
            }
        }
        return letters.map { LetterEntries(letter: $0, entries: document.entries(under: $0).filter(passesTags)) }
    }

    public func select(_ letter: SecretLetter) {
        selectedLetter = letter
        searchText = ""
        letterPinned = true
    }

    // MARK: Edits

    public var isEditing: Bool { editingID != nil }

    /// A new card at the top of the current letter, already in edit-as-text mode.
    public func beginAdd() {
        guard isUnlocked else { return }
        if editingID != nil { commitEdit() }
        draft = makeDraft(SecretsDocument.template)
        editingID = Self.newEntryID
    }

    public func beginEdit(_ entry: SecretEntry) {
        guard isUnlocked else { return }
        if editingID != nil { commitEdit() }
        draft = makeDraft(entry.raw)
        editingID = entry.id
    }

    private func makeDraft(_ text: String) -> NoteDocument {
        // A path and URL the editor needs for its own bookkeeping; this document never
        // enters the library and the editor's attachments, link cards and fold memory are off.
        let doc = NoteDocument(path: "Secrets/draft.md", url: AppSupport.directory.appendingPathComponent("Secrets/draft-never-written.md"), day: nil)
        doc.setText(text)
        return doc
    }

    /// Done: the draft's text goes into the vault (an empty title drops the entry).
    public func commitEdit() {
        guard let editingID, let draft else { return }
        let text = draft.text
        let today = Date()
        var landed: SecretLetter?
        vault.edit { doc in
            if editingID == Self.newEntryID {
                if let id = doc.insert(text) {
                    // The stamp rewrites the entry (and so its id): read the letter first.
                    landed = doc.entries.first { $0.id == id }?.letter
                    doc.stamp(id: id, changed: today)
                }
            } else if let before = doc.entries.first(where: { $0.id == editingID }) {
                if SecretsDocument.normalised(text) != before.raw {
                    for id in doc.replace(id: editingID, with: text) { doc.stamp(id: id, changed: today) }
                }
            }
        }
        self.editingID = nil
        self.draft = nil
        if let landed, !isSearching { selectedLetter = landed }
    }

    public func cancelEdit() {
        editingID = nil
        draft = nil
    }

    public func delete(_ entry: SecretEntry) {
        if editingID == entry.id { cancelEdit() }
        vault.edit { $0.remove(id: entry.id) }
    }

    public func removeTag(_ tag: String, from entry: SecretEntry) {
        vault.edit { $0.removeTag(tag, from: entry.id) }
    }

    public func toggleCollapsed(_ entry: SecretEntry) {
        if collapsed.contains(entry.title) { collapsed.remove(entry.title) } else { collapsed.insert(entry.title) }
    }

    public func toggleRevealed(_ key: String) {
        if revealed.contains(key) { revealed.remove(key) } else { revealed.insert(key) }
    }

    /// Copy a value; the tick beside it shows for a moment, the clipboard clears later.
    public func copy(_ value: String, key: String) {
        ConcealedPasteboard.copy(value)
        copiedKey = key
        copiedReset?.cancel()
        copiedReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            if self?.copiedKey == key { self?.copiedKey = nil }
        }
    }

    // MARK: Section

    public func makeRootView() -> AnyView { AnyView(SecretsPage(section: self)) }
    public func makeSettingsPane() -> AnyView? { AnyView(SecretsSettingsPane(section: self)) }
}

public extension SecretsDocument {
    /// Take a `#tag` off an entry's heading or list lines (a tag-only list line goes).
    mutating func removeTag(_ tag: String, from id: String) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        // The tag goes with the space before it (so "One #work #dev" closes up to "One #dev").
        let escaped = NSRegularExpression.escapedPattern(for: tag)
        guard let pattern = try? Regex("(\\s#" + escaped + "|^#" + escaped + ")(?=\\s|$)") else { return }
        let lines = entry.raw.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            String(line).replacing(pattern, with: "").replacing(/\s+$/, with: "")
        }
        let kept = lines.filter { $0.firstMatch(of: /^\s*[-*]\s*$/) == nil }
        replace(id: id, with: kept.joined(separator: "\n"))
    }
}
