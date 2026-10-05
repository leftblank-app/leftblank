import Foundation
import LeftBlankCore
import LeftBlankTestSupport
import PDFKit
import Testing

@Test(.enabled(if: ProcessInfo.processInfo.environment["LEFTBLANK_INTEGRATION"] == "1"))
func bundledWelcomeCompilesWithRepairedPackagesAndBlockedRegistry() throws {
    let root = TestPaths.temporaryDirectory.appendingPathComponent("welcome-offline-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let cache = root.appendingPathComponent("packages")
    try BundledPackages.prepare(in: cache, resources: repo.appendingPathComponent("Resources/Packages"))
    // Reproduce package files accidentally edited through diagnostic navigation.
    try Data("= Accidentally pasted document".utf8)
        .write(to: cache.appendingPathComponent("preview/cetz/0.5.2/src/draw/shapes.typ"))
    try Data().write(to: cache.appendingPathComponent("preview/cetz/0.5.2/src/anchor.typ"))
    try BundledPackages.prepare(in: cache, resources: repo.appendingPathComponent("Resources/Packages"))
    try WelcomeDocument.prepareAssets(in: root)
    #expect(try Data(contentsOf: root.appendingPathComponent(WelcomeDocument.markFilename)) ==
        Data(contentsOf: repo.appendingPathComponent("Brand/mark-dark.svg")))
    for language in [AppLanguage.english, .simplifiedChinese] {
        let input = root.appendingPathComponent("welcome-\(language.rawValue).typ")
        let output = input.deletingPathExtension().appendingPathExtension("pdf")
        let source = WelcomeDocument.source(language: language)
        #expect(source.contains("@preview/cetz:0.5.2"))
        #expect(source.contains("@preview/codly:1.3.0"))
        if language == .english {
            #expect(try source == String(
                contentsOf: repo.appendingPathComponent("Examples/Welcome.typ"),
                encoding: .utf8,
            ))
        }
        try Data(source.utf8).write(to: input)
        let process = Process()
        process.executableURL = repo.appendingPathComponent(".tools/tinymist")
        process.arguments = [
            "compile",
            "--font-path",
            repo.appendingPathComponent("Sources/LeftBlankCore/Resources/Fonts").path,
            "--root",
            root.path,
            "--package-path",
            root.appendingPathComponent("empty-local").path,
            "--package-cache-path",
            cache.path,
            input.path,
            output.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        // Both the fresh cache and local package directory are isolated. A missing
        // transitive import fails rather than silently using a global cache/network.
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] {
            environment[key] = "http://127.0.0.1:9"
        }
        environment["NO_PROXY"] = ""
        environment["no_proxy"] = ""
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try Data(contentsOf: output).starts(with: Data("%PDF".utf8)))
        let pdf = try #require(PDFDocument(url: output))
        #expect(pdf.pageCount == 2)
        let firstPage = try #require(pdf.page(at: 0)?.string)
        let tagline = language == .english ? "Ink for your thoughts" : "此中有真意，欲辨已忘言"
        #expect(firstPage.contains(tagline))
        for index in 0 ..< pdf.pageCount {
            let page = try #require(pdf.page(at: index))
            let label = "0\(index + 1)"
            let pageString = try #require(page.string)
            let range = (pageString as NSString).range(of: label, options: .backwards)
            let number = try #require(page.selection(for: range))
            #expect(
                abs(number.bounds(for: page).midX - page.bounds(for: .mediaBox).midX) < 2,
                "Page numbers should be centered",
            )
        }
        #expect(WelcomeDocument.thumbnailURL(language: language) != nil)
        if let artifacts = ProcessInfo.processInfo.environment["LEFTBLANK_DISCOVERY_ARTIFACTS"] {
            let directory = URL(fileURLWithPath: artifacts)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(contentsOf: output).write(to: directory.appendingPathComponent("welcome-\(language.rawValue).pdf"))
        }
    }
    #expect(WelcomeDocument.thumbnailURL != nil)
    #expect(BuiltInTemplate.welcome.matches("欢迎 公式"))
    #expect(BuiltInTemplate.blank.matches("空白"))
    #expect(!BuiltInTemplate.blank.matches("resume"))
}
