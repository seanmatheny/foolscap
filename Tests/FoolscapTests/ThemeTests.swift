import Testing
import Foundation
@testable import FoolscapCore

@Suite struct ThemeTests {
    @Test func builtInIdsAreUniqueAndLookUp() {
        let ids = NotebookTheme.builtIn.map(\.id)
        #expect(Set(ids).count == ids.count)
        for theme in NotebookTheme.builtIn { #expect(NotebookTheme.builtIn(id: theme.id) == theme) }
        #expect(NotebookTheme.builtIn(id: "nope") == nil)
    }

    @Test func flatThemesCarryNoTexture() {
        let flat = NotebookTheme.builtIn.filter(\.flat)
        #expect(flat.map(\.id) == ["graphite", "nocturne", "obsidian", "nord", "daylight"])
        for theme in flat {
            #expect(theme.cover.textureTile.isEmpty && theme.cover.grainOpacity == 0)
            #expect(theme.page.textureTile.isEmpty && theme.page.textureOpacity == 0)
            #expect(theme.tabColors.count == 6)
            #expect(theme.type.body.design == .sans)
            // The same pitch as the leather themes, so the ruling geometry is shared.
            #expect(theme.linePitch == NotebookTheme.classicBlack.linePitch)
        }
        #expect(!NotebookTheme.midnight.flat && NotebookTheme.daylight.isDark == false)
    }

    @Test func paperChoiceLeavesAFlatPagePlain() {
        #expect(NotebookTheme.graphite.onPaper(.linen) == NotebookTheme.graphite)
        let textured = NotebookTheme.classicBlack.onPaper(.linen)
        #expect(textured.page.textureTile == PaperTexture.linen.tile && textured.page.textureOpacity > 0)
    }
}
