// swift-tools-version: 6.2
import PackageDescription

/// LB-019 spike. One package, two platforms: the same presentation model and
/// TextKit adapters compile for macOS (NSTextView) and iPadOS (UITextView),
/// and the same tests run on both. Build the parser first:
///   scripts/build-syntax-xcframework.sh
/// then run scripts/visual-editing-spike.sh.
let package = Package(
    name: "VisualEditingSpike",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "VisualEditing", targets: ["VisualEditing"])],
    targets: [
        .binaryTarget(name: "LeftBlankSyntaxFFI", path: "Artifacts/LeftBlankSyntax.xcframework"),
        // Pure Swift, platform-neutral: syntax tree wrapper + presentation model.
        .target(name: "VisualPresentation", dependencies: ["LeftBlankSyntaxFFI"], path: "Sources/VisualPresentation"),
        // Thin text-system adapters shared between AppKit and UIKit.
        .target(name: "VisualEditing", dependencies: ["VisualPresentation"], path: "Sources/VisualEditing"),
        .testTarget(name: "VisualEditingTests", dependencies: ["VisualEditing"], path: "Tests"),
    ],
)
