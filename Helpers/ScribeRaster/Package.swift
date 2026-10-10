// swift-tools-version: 6.2
import PackageDescription

// Page rasterisation shared by the two recognition helpers (scribe-ocr in the main
// package, scribe-vlm in Helpers/scribe-vlm). A package of its own so the MLX helper
// can depend on it without pulling in the app.
let package = Package(
    name: "ScribeRaster",
    platforms: [.macOS(.v26)],
    products: [.library(name: "ScribeRaster", targets: ["ScribeRaster"])],
    targets: [.target(name: "ScribeRaster")]
)
