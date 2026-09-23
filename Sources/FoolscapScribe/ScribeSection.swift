import SwiftUI
import FoolscapCore

/// Placeholder for the Kindle Scribe tab. It proves the section seam: a tab,
/// a read-only task provider whose tasks appear in the Tasks tab, and a
/// settings pane. The real module will port scribe-ocr.swift, the Amazon
/// notebook fetch, and the TODO heuristics from KindleScribeSync-mac.
@MainActor
public final class ScribeSection: NotebookSection {
    public let id = "scribe"
    public let tab = TabAppearance(label: "Scribe", systemImage: "pencil.and.scribble")
    private let provider = ScribeTaskProvider()

    public init() {}

    public func makeRootView() -> AnyView { AnyView(ScribePlaceholderPage()) }
    public var taskProvider: (any TaskProvider)? { provider }
    public func makeSettingsPane() -> AnyView? { AnyView(Text("Amazon account and OCR options will live here.")) }
}

/// Tasks recognised in handwritten notebooks. Read-only: their status lives
/// on the Kindle page, so the Tasks tab shows them with a lock.
final class ScribeTaskProvider: TaskProvider {
    let id = "scribe"
    var changes: AsyncStream<Void> { AsyncStream { _ in } }

    func tasks() async throws -> [TaskItem] {
        [TaskItem(providerID: id, title: "Sample handwritten TODO #scribe", status: .notStarted, tags: ["scribe"],
                  indent: 0, source: TaskSource(path: "Kindle/Work Notebook.pdf", line: 3), isReadOnly: true)]
    }

    func setStatus(_ status: TaskStatus, of task: TaskItem) async throws { throw TaskWriteError.readOnly }
}

struct ScribePlaceholderPage: View {
    @Environment(\.notebookTheme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Kindle Scribe").font(.system(size: 26, weight: .bold, design: .serif))
            Text("Handwritten notebooks will sync here, be OCR'd, and feed their TODOs into the Tasks tab.")
                .font(.system(size: 15, design: .serif)).opacity(0.7)
            Spacer()
        }
        .foregroundStyle(theme.ink.color)
        .padding(EdgeInsets(top: 34, leading: 64, bottom: 24, trailing: 40))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
