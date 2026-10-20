import Foundation
import FoolscapCore

/// The look of the notebook as Settings has it: everything the theme and the
/// chrome read from the defaults. The Mac writes it to a file in the notebook
/// folder (`AppearanceSync.fileName`), which iCloud carries to the phone; the
/// phone applies it to its own defaults when "Follow the Mac's appearance" is on.
public struct AppearanceSettings: Codable, Equatable, Sendable {
    public var themeID: String
    public var textScale: Double
    public var openingAnimation: Bool
    public var ruling: String
    public var marginRule: Bool
    public var elasticBand: Bool
    public var tabEdge: String
    public var paperTexture: String
    public var bodyFont: String
    public var headingFont: String
    public var monoFont: String
    /// The pens as their JSON, the way the default holds them.
    public var taskPens: String
    public var taskSortByPen: Bool

    /// What the defaults say now.
    public init(defaults: UserDefaults = .standard) {
        themeID = defaults.string(forKey: PreferenceKeys.themeID) ?? "classic-black"
        textScale = defaults.object(forKey: PreferenceKeys.textScale) as? Double ?? 1.0
        openingAnimation = defaults.object(forKey: PreferenceKeys.openingAnimation) as? Bool ?? true
        ruling = defaults.string(forKey: PreferenceKeys.ruling) ?? ""
        marginRule = defaults.bool(forKey: PreferenceKeys.marginRule)
        elasticBand = defaults.bool(forKey: PreferenceKeys.elasticBand)
        tabEdge = defaults.string(forKey: PreferenceKeys.tabEdge) ?? ""
        paperTexture = defaults.string(forKey: PreferenceKeys.paperTexture) ?? ""
        bodyFont = defaults.string(forKey: PreferenceKeys.bodyFont) ?? ""
        headingFont = defaults.string(forKey: PreferenceKeys.headingFont) ?? ""
        monoFont = defaults.string(forKey: PreferenceKeys.monoFont) ?? ""
        taskPens = defaults.string(forKey: TaskPens.key) ?? "[]"
        taskSortByPen = defaults.object(forKey: TaskPens.sortKey) as? Bool ?? true
    }

    /// Write these into `defaults`, only the keys that differ (so observers fire
    /// once per real change). A font family this device lacks falls back to the
    /// theme's own face; with `textSize` false the text scale is left alone (a phone
    /// keeps its own). Returns whether anything changed.
    @discardableResult
    public func apply(to defaults: UserDefaults = .standard, fontAvailable: (String) -> Bool, textSize: Bool = true) -> Bool {
        var changed = false
        func set(_ value: String, _ key: String) {
            if defaults.string(forKey: key) ?? "" != value { defaults.set(value, forKey: key); changed = true }
        }
        func set(_ value: Bool, _ key: String, default fallback: Bool) {
            if (defaults.object(forKey: key) as? Bool ?? fallback) != value { defaults.set(value, forKey: key); changed = true }
        }
        func font(_ family: String) -> String { family.isEmpty || fontAvailable(family) ? family : "" }
        set(themeID, PreferenceKeys.themeID)
        if textSize, (defaults.object(forKey: PreferenceKeys.textScale) as? Double ?? 1.0) != textScale {
            defaults.set(textScale, forKey: PreferenceKeys.textScale); changed = true
        }
        set(openingAnimation, PreferenceKeys.openingAnimation, default: true)
        set(ruling, PreferenceKeys.ruling)
        set(marginRule, PreferenceKeys.marginRule, default: false)
        set(elasticBand, PreferenceKeys.elasticBand, default: false)
        set(tabEdge, PreferenceKeys.tabEdge)
        set(paperTexture, PreferenceKeys.paperTexture)
        set(font(bodyFont), PreferenceKeys.bodyFont)
        set(font(headingFont), PreferenceKeys.headingFont)
        set(font(monoFont), PreferenceKeys.monoFont)
        set(taskPens, TaskPens.key)
        set(taskSortByPen, TaskPens.sortKey, default: true)
        return changed
    }
}

/// The appearance file in the notebook folder: dot-prefixed, so the index, the
/// Daily list and the root walker pass it by, and iCloud Drive still carries it.
public enum AppearanceSync {
    public static let fileName = ".foolscap-appearance.json"

    public static func url(in root: URL) -> URL { root.appendingPathComponent(fileName) }

    public static func encode(_ settings: AppearanceSettings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(settings)
    }

    public static func decode(_ data: Data) -> AppearanceSettings? {
        try? JSONDecoder().decode(AppearanceSettings.self, from: data)
    }

    /// The settings in `root`, or nil when there is no file or it does not parse.
    public static func read(root: URL, presenter: NSFilePresenter? = nil) -> AppearanceSettings? {
        let file = url(in: root)
        guard FileManager.default.fileExists(atPath: file.path) || ICloudPlaceholders.needsDownload(file) else { return nil }
        if ICloudPlaceholders.needsDownload(file) { ICloudPlaceholders.startDownload(file) }
        guard let data = try? FileIO.read(file, presenter: presenter) else { return nil }
        return decode(data)
    }

    /// Write `settings` to `root` unless the file already says the same.
    /// Returns whether a write happened.
    @discardableResult
    public static func write(_ settings: AppearanceSettings, root: URL, presenter: NSFilePresenter? = nil) throws -> Bool {
        let data = try encode(settings)
        let file = url(in: root)
        if let existing = try? FileIO.read(file, presenter: presenter), existing == data { return false }
        try FileIO.write(data, to: file, presenter: presenter)
        return true
    }
}
