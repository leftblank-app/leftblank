// swift-tools-version: 6.2
import Foundation
import PackageDescription

// The iPad Xcode project uses Sources/Package.swift to resolve only the shared core.
// App Store and direct builds never resolve or link an external updater.
let preview = ProcessInfo.processInfo.environment["LEFTBLANK_DISTRIBUTION"] == "preview"
let distributionSettings: [SwiftSetting] = preview ? [.define("LEFTBLANK_PREVIEW")] : []
let updaterPackages: [Package.Dependency] = preview ? [.package(
    url: "https://github.com/sparkle-project/Sparkle.git",
    exact: "2.10.0",
)] : []
let updaterProducts: [Target.Dependency] = preview ? [.product(name: "Sparkle", package: "Sparkle")] : []

let package = Package(
    name: "LeftBlank",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "LeftBlankCore", targets: ["LeftBlankCore"]),
               .executable(name: "LeftBlank", targets: ["LeftBlankLauncher"])],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")] +
        updaterPackages,
    targets: [
        // typst-syntax behind a C ABI (Engine/SyntaxBridge). scripts/build-syntax.sh,
        // which scripts/bootstrap.sh runs, builds it before the first `swift build`.
        .binaryTarget(name: "LeftBlankSyntaxLibrary", path: "Engine/SyntaxBridge/target/LeftBlankSyntax.xcframework"),
        .target(name: "LeftBlankSyntaxFFI", dependencies: ["LeftBlankSyntaxLibrary"]),
        .target(
            name: "LeftBlankCore",
            dependencies: ["ZIPFoundation", "LeftBlankSyntaxFFI"],
            resources: [.process("Resources")],
            swiftSettings: distributionSettings,
        ),
        .target(
            name: "LeftBlankApp",
            dependencies: ["LeftBlankCore"] + updaterProducts,
            path: "Sources/LeftBlank",
            swiftSettings: distributionSettings,
        ),
        .executableTarget(
            name: "LeftBlankLauncher",
            dependencies: ["LeftBlankApp"],
            linkerSettings: preview ? [.unsafeFlags([
                "-Xlinker",
                "-rpath",
                "-Xlinker",
                "@executable_path/../Frameworks",
            ])] : [],
        ),
        .target(name: "LeftBlankTestSupport", path: "Tests/Support"),
        .testTarget(name: "LeftBlankCoreTests", dependencies: ["LeftBlankCore", "LeftBlankTestSupport"]),
        .testTarget(
            name: "LeftBlankAppTests",
            dependencies: ["LeftBlankApp", "LeftBlankCore", "LeftBlankTestSupport"] +
                updaterProducts,
            swiftSettings: distributionSettings,
        ),
    ],
)
