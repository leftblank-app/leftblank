import AppKit
@testable import LeftBlankApp
import LeftBlankCore
import Testing

extension WritingFlowTests {
    @Test func hoveringAlignRendersTheDocumentationExampleWithoutChangingTheDocument() async throws {
        let source = "#align(center)[Hi]\n#align(alignment.center)[Hi]\n"
        let app = try WritingFixture(text: source)
        defer { app.close() }
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        let selection = editor.selectedRange()
        let previewURL = app.workspace.previewURL
        let language = L10n.language
        defer { L10n.setLanguage(language) }
        L10n.setLanguage(.simplifiedChinese)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            app.window.appearance = NSAppearance(named: appearance)
            await app.layout()
            try await app.hover(over: "align")
            try await app.wait { editor.sourceHover.examplePreview?.loading == false }
            let image = try #require(editor.sourceHover.examplePreview?.image)
            #expect(image.size.width > 0 && image.size.height > 0)
            #expect(editor.sourceHover.help?.example?.source.contains("align(") == true)
            #expect(editor.selectedRange() == selection)
            #expect(app.workspace.text == source)
            #expect(app.workspace.previewURL == previewURL)
            if let artifacts = ProcessInfo.processInfo.environment["LEFTBLANK_UI_ARTIFACTS"] {
                let directory = URL(fileURLWithPath: artifacts)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let view = try #require(editor.sourceHover.panel?.contentView)
                await app.layout()
                view.layoutSubtreeIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("hover-align-\(appearance.rawValue).png"))
            }
            editor.sourceHover.dismiss()
        }
        #expect(try String(contentsOf: app.document, encoding: .utf8) == source)
        let root = app.workspace.stateDirectory.appendingPathComponent("HoverExamples")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func exampleRenderingPrefersImagesAndRejectsUnavailableContext() async throws {
        let app = try WritingFixture(text: "= Original", startService: false)
        defer { app.close() }
        let renderer = HoverExampleRenderer()
        let root = app.root.appendingPathComponent("Examples")
        func example(_ code: String, suffix: String = "") throws -> HoverExample {
            try #require(LanguageAssistance.hover(.object([
                "contents": .string("```typ\n\(code)\n```\n" + suffix),
            ]))?.example)
        }
        let svg = Data(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"50\"><rect width=\"100\" height=\"50\" fill=\"red\"/></svg>"
                .utf8,
        )
        let illustrated = try example(
            "#missing()",
            suffix: "<img src=\"data:image/svg+xml;base64,\(svg.base64EncodedString())\"/>",
        )
        let image = try #require(await renderer.image(
            for: illustrated,
            directory: root,
            packageCache: app.workspace.packageCache,
        ))
        #expect(await renderer
            .image(for: illustrated, directory: root, packageCache: app.workspace.packageCache) === image)
        let codeOnly = try example("#align(center)[Hi]")
        #expect(codeOnly.image == nil)
        let rendered = try #require(await renderer.image(
            for: codeOnly,
            directory: root,
            packageCache: app.workspace.packageCache,
        ))
        #expect(rendered.size.width > 0 && rendered.size.height > 0)
        #expect(try await renderer.image(
            for: example("#missing()"),
            directory: root,
            packageCache: app.workspace.packageCache,
        ) == nil)
        try Data("Private document".utf8).write(to: root.appendingPathComponent("secret.txt"))
        #expect(try await renderer.image(
            for: example("#read(\"../secret.txt\")"),
            directory: root,
            packageCache: app.workspace.packageCache,
        ) == nil)
        try FileManager.default.removeItem(at: root.appendingPathComponent("secret.txt"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func exampleCompileTimeoutAndCancellationReapTheWorker() async throws {
        func worker() -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["10"]
            return process
        }
        let timedOut = worker()
        let started = ContinuousClock.now
        #expect(await HoverCompilation(process: timedOut).run() == false)
        #expect(!timedOut.isRunning)
        #expect(started.duration(to: .now) >= .seconds(3))
        #expect(started.duration(to: .now) < .seconds(8))
        let cancelled = worker()
        let task = Task { await HoverCompilation(process: cancelled).run() }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        #expect(await task.value == false)
        #expect(!cancelled.isRunning)
    }
}
