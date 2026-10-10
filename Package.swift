// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "foolscap",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "FoolscapCore", targets: ["FoolscapCore"]),
        .library(name: "FoolscapStore", targets: ["FoolscapStore"]),
        .library(name: "FoolscapEditor", targets: ["FoolscapEditor"]),
        .library(name: "FoolscapUI", targets: ["FoolscapUI"]),
        .library(name: "FoolscapScribe", targets: ["FoolscapScribe"]),
        .library(name: "FoolscapHighlights", targets: ["FoolscapHighlights"]),
        .library(name: "FoolscapJira", targets: ["FoolscapJira"]),
        .library(name: "FoolscapSecrets", targets: ["FoolscapSecrets"]),
        .executable(name: "Foolscap", targets: ["FoolscapApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.6.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // Page rendering shared with the MLX helper in Helpers/scribe-vlm.
        .package(path: "Helpers/ScribeRaster"),
    ],
    targets: [
        // Models, protocols and markdown parsing helpers (SwiftUI only for the theme
        // environment key, so a plug-in section needs nothing else).
        .target(
            name: "FoolscapCore",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")]
        ),
        // Files on disk, iCloud coordination, SQLite FTS index.
        .target(
            name: "FoolscapStore",
            dependencies: ["FoolscapCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        // TextKit 2 hybrid markdown editor.
        .target(
            name: "FoolscapEditor",
            dependencies: ["FoolscapCore", "FoolscapStore", "FoolscapUI"]
        ),
        // Skeuomorphic notebook chrome and themes.
        .target(
            name: "FoolscapUI",
            dependencies: ["FoolscapCore"],
            resources: [.copy("Textures")]
        ),
        // The app's own sections: Daily Notes, Tasks, search, preferences, export.
        .target(
            name: "FoolscapSections",
            dependencies: ["FoolscapCore", "FoolscapStore", "FoolscapEditor", "FoolscapUI"]
        ),
        // Kindle Scribe section: Amazon sync, handwriting OCR, transcripts, TODO tasks.
        .target(
            name: "FoolscapScribe",
            dependencies: ["FoolscapCore", "FoolscapStore", "FoolscapUI", "FoolscapEditor", .product(name: "ScribeRaster", package: "ScribeRaster")]
        ),
        // Kindle highlights section: the Kindle app's databases and book files read
        // natively (Calibre's KFX plugin out of process for KFX text), one markdown
        // file per book, three highlights a day.
        .target(
            name: "FoolscapHighlights",
            dependencies: ["FoolscapCore", "FoolscapStore", "FoolscapUI", .product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Resources/kfx_extract.py")]
        ),
        // Jira Cloud section: the issues assigned to the user, pulled into Today as
        // `#jira` tasks. Writes nothing to the notebook but those task lines.
        .target(
            name: "FoolscapJira",
            dependencies: ["FoolscapCore", "FoolscapStore", "FoolscapUI", "FoolscapEditor"]
        ),
        // Secrets section: an encrypted markdown vault (passwords, keys, codes) filed A–Z,
        // opened with Touch ID or a recovery passphrase. Never indexed, never searched.
        .target(
            name: "FoolscapSecrets",
            dependencies: ["FoolscapCore", "FoolscapStore", "FoolscapUI", "FoolscapEditor"]
        ),
        // The OCR helper, bundled as Contents/MacOS/scribe-ocr. A separate process so
        // Vision's recognition models are unloaded again when a run finishes.
        .executableTarget(
            name: "FoolscapScribeOCR",
            dependencies: [.product(name: "ScribeRaster", package: "ScribeRaster")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "FoolscapApp",
            dependencies: ["FoolscapCore", "FoolscapStore", "FoolscapEditor", "FoolscapUI", "FoolscapSections", "FoolscapScribe", "FoolscapHighlights", "FoolscapJira", "FoolscapSecrets"],
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "FoolscapTests",
            dependencies: ["FoolscapCore", "FoolscapStore", "FoolscapEditor", "FoolscapSections", "FoolscapScribe", "FoolscapHighlights", "FoolscapJira", "FoolscapSecrets"]
        ),
    ]
)
