import SwiftUI
import FoolscapCore
import FoolscapStore
import FoolscapUI

/// What a note page shows over its editor while the note is not plainly there: iCloud
/// still downloading it, or a file that could not be read (said, with Try Again, rather
/// than an empty page the first keystroke would save over the note). Shared by the
/// daily page and the Reference tab.
public struct NoteLoadStatus: View {
    @Environment(\.notebookTheme) private var theme
    let document: NoteDocument
    let compact: Bool

    public init(document: NoteDocument, compact: Bool) {
        self.document = document
        self.compact = compact
    }

    public var body: some View {
        if document.isDownloading {
            Text("Downloading from iCloud…")
                .font(theme.type.body.face(13)).foregroundStyle(theme.dimInk.color)
                .padding(.top, 60).padding(.leading, compact ? PageRuling.textLeft : 64)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let error = document.loadError, !document.isLoaded {
            VStack(alignment: .leading, spacing: 8) {
                Text("This note could not be read: \(error.localizedDescription)")
                    .font(theme.type.body.face(13)).foregroundStyle(theme.dimInk.color)
                Button("Try Again") { Task { await document.reload() } }
                    .font(theme.type.body.face(12, weight: .semibold))
            }
            .padding(.top, 60).padding(.leading, compact ? PageRuling.textLeft : 64).padding(.trailing, 44)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The note changed on another device while it had edits here, or iCloud holds
/// conflicting copies of it: a banner asking which to keep.
public struct NoteChangeBanners: View {
    let document: NoteDocument
    let compact: Bool

    public init(document: NoteDocument, compact: Bool) {
        self.document = document
        self.compact = compact
    }

    public var body: some View {
        if document.externalChangePending {
            ExternalChangeBanner(document: document)
                .padding(.top, 44).padding(.trailing, compact ? PageRuling.textRight : 44)
        } else if !document.conflictVersions.isEmpty {
            ConflictBanner(document: document)
                .padding(.top, 44).padding(.trailing, compact ? PageRuling.textRight : 44)
        }
    }
}

public struct ConflictBanner: View {
    @Environment(\.notebookTheme) private var theme
    let document: NoteDocument
    public init(document: NoteDocument) { self.document = document }
    public var body: some View {
        let count = document.conflictVersions.count
        NoteBanner(symbol: "arrow.triangle.branch", text: "iCloud has \(count) conflicting cop\(count == 1 ? "y" : "ies") of this note.") {
            Button("Keep mine") { try? document.resolveConflicts(.keepMine) }
            Button("Take theirs") { try? document.resolveConflicts(.takeTheirs) }
            Button("Keep both") { try? document.resolveConflicts(.keepBoth) }
        }
    }
}

public struct ExternalChangeBanner: View {
    let document: NoteDocument
    public init(document: NoteDocument) { self.document = document }
    public var body: some View {
        NoteBanner(symbol: "exclamationmark.icloud", text: "This note changed on another device.") {
            Button("Keep mine") { document.keepLocalVersion() }
            Button("Take theirs") { document.takeExternalVersion() }
        }
    }
}

/// A capsule over the note with a message and its buttons in one row where they
/// fit (a window), the buttons under the message where they do not (a phone).
public struct NoteBanner<Buttons: View>: View {
    @Environment(\.notebookTheme) private var theme
    let symbol: String
    let text: String
    @ViewBuilder let buttons: Buttons

    public init(symbol: String, text: String, @ViewBuilder buttons: () -> Buttons) {
        self.symbol = symbol
        self.text = text
        self.buttons = buttons()
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                Text(text)
                buttons
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                    Text(text)
                }
                HStack(spacing: 8) { buttons }
            }
        }
        .font(theme.type.body.face(12))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.accent.color.opacity(0.18)))
        .foregroundStyle(theme.ink.color)
    }
}

public extension View {
    /// On the phone a note runs under the clock and the home indicator like the other
    /// pages' scroll views; the text view insets its content by the same room.
    @ViewBuilder
    func ignoresPageInsets(_ on: Bool) -> some View {
        if on { ignoresSafeArea(.container, edges: .vertical) } else { self }
    }
}
