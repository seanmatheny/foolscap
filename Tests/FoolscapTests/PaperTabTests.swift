import Testing
import Foundation
@testable import FoolscapCore
@testable import FoolscapUI

@Suite struct PaperTabTests {
    let tabs = [TabAppearance(label: "Daily Notes", systemImage: "calendar"), TabAppearance(label: "Tasks", systemImage: "checklist"),
                TabAppearance(label: "Highlights", systemImage: "highlighter"), TabAppearance(label: "Secrets", systemImage: "lock.fill")]

    @Test func tabsShrinkToTheirIconsWhenThePageIsTooShort() {
        let full = PaperTab.length(for: tabs[0])
        #expect(full == tabs.map { PaperTab.length(for: $0) }.max())
        let needed = full * 4 + PaperTab.spacing * 3
        #expect(PaperTab.length(for: tabs, available: needed).compact == false)
        #expect(PaperTab.length(for: tabs, available: needed).length == full)
        #expect(PaperTab.length(for: tabs, available: needed - 1).compact == true)
        #expect(PaperTab.length(for: tabs, available: needed - 1).length == PaperTab.compactLength)
        // Not yet measured: keep the labels rather than flash the icons.
        #expect(PaperTab.length(for: tabs, available: 0).compact == false)
        #expect(PaperTab.length(for: [], available: 10).compact == false)
    }
}
