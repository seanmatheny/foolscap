// swift-tools-version: 6.2
import PackageDescription

// scribe-vlm: handwriting recognition with a local vision-language model on MLX,
// bundled as Contents/MacOS/scribe-vlm. A package of its own so the app's
// `swift build` and `make test` never compile MLX's C++, and because MLX's Metal
// library can only be built by Xcode's build system (`make scribe-vlm` runs
// xcodebuild; a plain `swift build` here compiles but traps at run time with
// "Failed to load the default metallib").
let package = Package(
    name: "scribe-vlm",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "FoolscapScribeVLM", targets: ["FoolscapScribeVLM"])],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "3.32.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(path: "../ScribeRaster"),
    ],
    targets: [
        .executableTarget(
            name: "FoolscapScribeVLM",
            dependencies: [
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "ScribeRaster", package: "ScribeRaster"),
            ]
        ),
    ]
)
