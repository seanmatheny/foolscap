import SwiftUI
import AppKit
import FoolscapCore
import FoolscapStore
import FoolscapEditor
import FoolscapUI

/// The Jira tab: the issues assigned to you, grouped by their Jira status, on
/// the same ruling as the Tasks tab.
struct JiraPage: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: JiraSection

    private var pitch: CGFloat { theme.linePitch }
    private var scale: CGFloat { theme.type.body.size / 15 }

    var body: some View {
        let palette = EditorPalette(theme: theme)
        GeometryReader { geo in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    RulingView(pitch: pitch, topInset: pitch + PageRuling.ruleOffset(palette), marginX: PageRuling.textLeft)
                        .frame(minHeight: geo.size.height)
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        if section.status.needsCredentials {
                            signIn
                        } else if section.state.issues.isEmpty {
                            Text(section.status.isRunning ? (section.status.phase ?? "Fetching your issues…") : "Nothing assigned to you.")
                                .font(.system(size: 14 * scale, design: .serif)).italic().foregroundStyle(theme.dimInk.color)
                                .frame(height: pitch)
                        } else {
                            ForEach(section.groups) { group in
                                groupView(group)
                            }
                        }
                        Spacer(minLength: pitch * 2)
                    }
                    .padding(.leading, PageRuling.textLeft)
                    .padding(.trailing, 44)
                    .padding(.top, pitch + PageRuling.rowShift(palette))
                }
            }
        }
        .foregroundStyle(theme.ink.color)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Jira").font(theme.type.heading.font).fontWeight(.bold)
            Text("\(section.openCount)").font(.system(size: 13 * scale, design: .serif)).foregroundStyle(theme.dimInk.color)
            Spacer()
            Text(section.statusText).font(.system(size: 12 * scale, design: .serif)).foregroundStyle(theme.dimInk.color).lineLimit(1)
            if section.credentials != nil {
                Button {
                    section.syncNow()
                } label: {
                    Label(section.status.isRunning ? "Syncing…" : "Sync now", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11.5, weight: .medium, design: .serif))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Capsule().fill(theme.accent.color.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .disabled(section.status.isRunning)
            }
        }
        .frame(height: pitch * 1.5)
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect Foolscap to Jira Cloud with your site, your email and an API token, and the issues assigned to you appear here. A sun on an issue adds it to Today.")
                .font(.system(size: 14 * scale, design: .serif)).opacity(0.75)
                .frame(maxWidth: 520, alignment: .leading)
            Button {
                UserDefaults.standard.set("jira", forKey: "settingsTab")
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Text("Open Settings…")
                    .font(.system(size: 13, weight: .semibold, design: .serif))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(theme.accent.color.opacity(0.16)))
                    .overlay(Capsule().stroke(theme.accent.color.opacity(0.35), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            if let error = section.status.lastError {
                Text(error).font(.system(size: 13, design: .serif)).foregroundStyle(.red)
            }
        }
        .padding(.top, pitch / 2)
    }

    private func groupView(_ group: JiraSection.Group) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group.name)
                    .font(.system(size: 17 * scale, weight: .bold, design: .serif))
                    .highlighted(group.isActive ? theme.highlighter[.today] : nil)
                Text("\(group.issues.count)").font(.system(size: 12 * scale, design: .serif)).foregroundStyle(theme.dimInk.color)
            }
            .frame(height: pitch)
            ForEach(group.issues) { issue in
                JiraIssueRow(section: section, issue: issue, pitch: pitch)
            }
            Spacer().frame(height: pitch)
        }
    }
}

struct JiraIssueRow: View {
    @Environment(\.notebookTheme) private var theme
    let section: JiraSection
    let issue: JiraIssue
    let pitch: CGFloat
    @State private var hovering = false
    private var scale: CGFloat { theme.type.body.size / 15 }

    var body: some View {
        let pulled = section.isPulled(issue)
        HStack(alignment: .center, spacing: 8) {
            Button { section.pull(issue) } label: {
                Image(systemName: pulled ? "sun.max.fill" : "sun.max")
                    .font(.system(size: 13 * scale, weight: .regular))
                    .foregroundStyle(pulled ? theme.accent.color : theme.dimInk.color)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .disabled(pulled)
            .help(pulled ? "Already in Today" : "Pull into Today")
            Circle()
                .fill(TaskPriority(rawValue: issue.taskPriorityLevel)?.color?.color ?? .clear)
                .frame(width: 8, height: 8)
                .help(issue.priority ?? "")
            Text(issue.key)
                .font(.system(size: 11.5 * scale, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.dimInk.color)
            Text(issue.summary)
                .font(.system(size: 14.5 * scale, design: .serif))
                .lineLimit(1)
            if let parent = issue.parentSummary {
                // The epic, as a chip in Jira's purple.
                Text(parent)
                    .font(.system(size: 10.5 * scale, weight: .medium, design: .serif))
                    .foregroundStyle(theme.isDark ? Color(red: 0.80, green: 0.74, blue: 0.95) : Color(red: 0.36, green: 0.24, blue: 0.62))
                    .lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 1.5)
                    .background(Capsule().fill(Color(red: 0.49, green: 0.37, blue: 0.80).opacity(theme.isDark ? 0.28 : 0.16)))
                    .help("Epic: \(parent)")
            }
            Spacer(minLength: 8)
            if let due = issue.dueDate {
                Text("due \(due)").font(.system(size: 11.5 * scale, design: .serif)).foregroundStyle(theme.dimInk.color)
            }
            Button { section.open(issue) } label: {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 12 * scale))
                    .foregroundStyle(theme.dimInk.color)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.35)
            .help("Open in Jira")
        }
        .frame(height: pitch)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Pull into Today") { section.pull(issue) }.disabled(pulled)
            Button("Open in Jira") { section.open(issue) }
            Button("Copy Key") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(issue.key, forType: .string)
            }
        }
    }
}
