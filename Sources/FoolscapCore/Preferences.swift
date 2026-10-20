import Foundation

/// Settings keys the app mirrors into the theme and the chrome environment.
/// Here in Core so the store can carry them between devices (`AppearanceSettings`).
public enum PreferenceKeys {
    public static let themeID = "themeID"
    public static let textScale = "textScale"
    public static let openingAnimation = "openingAnimation"
    public static let ruling = "ruling"
    public static let marginRule = "marginRule"
    public static let elasticBand = "elasticBand"
    public static let tabEdge = "tabEdge"
    public static let paperTexture = "paperTexture"
    /// Font family names; empty means the theme's own face.
    public static let bodyFont = "bodyFont"
    public static let headingFont = "headingFont"
    public static let monoFont = "monoFont"
}
