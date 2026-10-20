import Foundation
import Testing
@testable import FoolscapCore
@testable import FoolscapStore

@Suite struct AppearanceSyncTests {
    private func scratchDefaults() -> UserDefaults {
        let name = "foolscap-appearance-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func theFileRoundTripsAndIsOnlyWrittenWhenItChanged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-appearance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = scratchDefaults()
        defaults.set("oxblood", forKey: PreferenceKeys.themeID)
        defaults.set(1.2, forKey: PreferenceKeys.textScale)
        defaults.set("lined", forKey: PreferenceKeys.ruling)
        defaults.set("Georgia", forKey: PreferenceKeys.bodyFont)
        defaults.set(TaskPens.encode([TagPen(tag: "home", colour: .pink)]), forKey: TaskPens.key)
        let settings = AppearanceSettings(defaults: defaults)
        #expect(try AppearanceSync.write(settings, root: root))
        #expect(!(try AppearanceSync.write(settings, root: root)), "the same look is not written twice")
        #expect(AppearanceSync.read(root: root) == settings)
        #expect(AppearanceSync.url(in: root).lastPathComponent.hasPrefix("."), "the index and the Daily list pass dotfiles by")
    }

    @Test func applyingWritesOnlyTheKeysThatDifferAndDropsAFontTheDeviceLacks() {
        let source = scratchDefaults()
        source.set("forest", forKey: PreferenceKeys.themeID)
        source.set("Charter", forKey: PreferenceKeys.bodyFont)
        source.set("Hoefler Text", forKey: PreferenceKeys.headingFont)
        source.set(true, forKey: PreferenceKeys.marginRule)
        let settings = AppearanceSettings(defaults: source)
        let phone = scratchDefaults()
        #expect(settings.apply(to: phone, fontAvailable: { $0 == "Charter" }))
        #expect(phone.string(forKey: PreferenceKeys.themeID) == "forest")
        #expect(phone.string(forKey: PreferenceKeys.bodyFont) == "Charter")
        #expect(phone.string(forKey: PreferenceKeys.headingFont) ?? "" == "", "a family the device lacks falls back to the theme's face")
        #expect(phone.bool(forKey: PreferenceKeys.marginRule))
        #expect(!settings.apply(to: phone, fontAvailable: { $0 == "Charter" }), "applied again, nothing changes")
    }

    @Test func aDeviceCanKeepItsOwnTextSize() {
        let source = scratchDefaults()
        source.set(0.85, forKey: PreferenceKeys.textScale)
        source.set("kraft", forKey: PreferenceKeys.themeID)
        let settings = AppearanceSettings(defaults: source)
        let phone = scratchDefaults()
        phone.set(1.1, forKey: PreferenceKeys.textScale)
        #expect(settings.apply(to: phone, fontAvailable: { _ in true }, textSize: false))
        #expect(phone.string(forKey: PreferenceKeys.themeID) == "kraft")
        #expect(phone.double(forKey: PreferenceKeys.textScale) == 1.1, "the phone's own size stays")
    }
}
