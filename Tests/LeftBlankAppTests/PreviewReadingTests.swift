import AppKit
import Foundation
@testable import LeftBlankApp
import LeftBlankCore
import SwiftUI
import Testing
import WebKit

extension WritingFlowTests {
    @Test func realSemanticAndCodeHighlightingPreservesTypingUndoAndDocumentSwitches() async throws {
        let source = "= 中文😀\n\n```python\ntotal = sum(range(1, 11))\nprint(total)\n```\n\n$alpha + beta = gamma$\n"
        let app = try WritingFixture(text: source)
        defer { app.close() }
        try await app.ready()
        try await app.wait { app.workspace.syntaxSnapshot?.source == source }
        let editor = try #require(app.workspace.editor)
        let sum = (source as NSString).range(of: "sum")
        let number = (source as NSString).range(of: "11")
        let code = (source as NSString).range(of: "total")
        #expect(editorColor(editor, at: sum.location) == Theme.sourceFunction)
        #expect(editorColor(editor, at: number.location) == Theme.sourceNumber)
        #expect(editorColor(editor, at: code.location) != Theme.sourceFunction)
        #expect(editor.string == source)
        #expect(editor.selectedRange().location == source.utf16.count)
        editor.insertSnippet(Snippet(text: "42"), replacing: number)
        let edited = editor.string
        try await app.wait { app.workspace.syntaxSnapshot?.source == edited }
        editor.undoManager?.undo()
        try await app.wait { app.workspace.syntaxSnapshot?.source == source }
        #expect(editor.string == source)
        #expect(app.workspace.text == source)
        // Rapid edits and switching documents must never apply old UTF-16 ranges.
        for _ in 0 ..< 8 {
            editor.insertSnippet(Snippet(text: "😀"), replacing: NSRange(location: 0, length: 0))
        }
        let next = app.root.appendingPathComponent("next.typ")
        try Data("= Next\n\n#let value = 7\n".utf8).write(to: next)
        #expect(app.workspace.open(next))
        try await app.wait { app.workspace.syntaxSnapshot?.source == "= Next\n\n#let value = 7\n" }
        #expect(editor.string == app.workspace.text)
    }

    @Test func readingStylesRevealSourceWithoutChangingUndoOrText() throws {
        let source = "= 中文😀标题\n\n*bold* and _italic_ and `code`.\n\nEnd\n"
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        let editor = try #require(app.workspace.editor)
        editor.highlight()
        let storage = try #require(editor.textStorage)
        let hiddenFont = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(hiddenFont.pointSize < 1)
        #expect(editor.string == source)
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.highlight()
        #expect((storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 0 > 1)
        let bold = (source as NSString).range(of: "bold")
        editor.insertSnippet(Snippet(text: "changed"), replacing: bold)
        #expect(app.workspace.text.contains("*changed*"))
        app.workspace.styledSource = false
        editor.undoManager?.undo()
        #expect(editor.string == source)
        #expect(app.workspace.text == source)
        editor.undoManager?.redo()
        #expect(app.workspace.text == editor.string)
        #expect(app.workspace.text.contains("changed"))
        app.workspace.styledSource = true
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.highlight()
        #expect(app.workspace.text == editor.string)
        editor.setMarkedText(
            "中文输入",
            selectedRange: NSRange(location: 4, length: 0),
            replacementRange: editor.selectedRange(),
        )
        #expect(editor.hasMarkedText())
        editor.highlight()
        #expect(editor.hasMarkedText(), "Styling must not interrupt IME composition")
        editor.unmarkText()
    }

    @Test func nestedDiscoveryMathInsertionAndEditingCommands() async throws {
        let app = try WritingFixture(text: "= Formula\n\n$ x + y $\n\n")
        defer { app.close() }
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        editor.setSelectedRange((editor.string as NSString).range(of: "x"))
        app.workspace.togglePalette()
        app.window.sendEvent(app.key("m", code: 46))
        #expect(app.workspace.paletteGroups.count == 3)
        await app.layout()
        app.window.sendEvent(app.key("b", code: 11))
        #expect(app.workspace.paletteGroup == "math-basic")
        await app.layout()
        let fraction = try #require(WritingCommand.all.first { $0.id == "fraction" })
        #expect(app.workspace.keyPath(for: fraction) == "m b f")
        app.workspace.selectCommand(fraction)
        try await app.wait { !app.workspace.applyingCommand }
        #expect(editor.string.filter { $0 == "$" }.count == 2)
        #expect(editor.string.contains("frac("))
        editor.undoManager?.undo()
        #expect(app.workspace.text == "= Formula\n\n$ x + y $\n\n")
        editor.setSelectedRange(NSRange(location: 0, length: 9))
        for id in ["indent", "outdent", "comment", "comment", "previewDark"] {
            try app.workspace.execute(#require(WritingCommand.all.first { $0.id == id }))
        }
        #expect(app.workspace.previewDark)
        #expect(!WritingCommand.all.contains { $0.id == "styledSource" })
        #expect(editor.string.hasPrefix("= Formula"))
        editor.insertSnippet(
            Snippet(text: "#let    a= (1,2,3)\n"),
            replacing: NSRange(location: editor.string.utf16.count, length: 0),
        )
        let before = editor.string
        app.workspace.formatDocument()
        try await app.wait { editor.string != before || app.workspace.message != nil }
        #expect(!editor.string.contains("#let    a="))
        editor.undoManager?.undo()
        #expect(editor.string == before)
        #expect(app.workspace.text == before)
    }

    @Test func universeImportIsPinnedDeduplicatedAndUndoable() throws {
        let app = try WritingFixture(text: "= Package import\n", startService: false)
        defer { app.close() }
        let package = try JSONDecoder().decode(
            UniversePackage.self,
            from: Data(#"{"name":"cetz","version":"0.5.2","compiler":"0.14.0"}"#.utf8),
        )
        let editor = try #require(app.workspace.editor)
        app.workspace.layout = .preview
        try app.workspace.importPackage(package)
        #expect(app.workspace.layout == .split)
        #expect(editor.string.hasPrefix("#import \"@preview/cetz:0.5.2\"\n\n"))
        #expect(throws: CommandError.self) { try app.workspace.importPackage(package) }
        editor.undoManager?.undo()
        #expect(app.workspace.text == "= Package import\n")
        let newer = try JSONDecoder().decode(
            UniversePackage.self,
            from: Data(#"{"name":"example","version":"1.0.0","compiler":"99.0.0"}"#.utf8),
        )
        #expect(throws: CommandError.self) { try app.workspace.importPackage(newer) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LEFTBLANK_BOOK_PREVIEW"] == "1"))
    func completeBookPreviewRemainsUsableInLargeWindow() async throws {
        let app = try WritingFixture(text: "", startService: false)
        defer { app.close() }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        #expect(app.workspace.open(repository.appendingPathComponent("Examples/Books/SICP/main.typ")))
        app.window.setContentSize(NSSize(width: 1920, height: 1300))
        try await app.ready()
        app.workspace.layout = .preview
        await app.layout()
        let web = try #require(findWebView(app.window.contentView))
        web.configuration.preferences.inactiveSchedulingPolicy = .none
        web.configuration.userContentController.addUserScript(WKUserScript(
            source: "window.requestAnimationFrame = callback => setTimeout(() => callback(performance.now()), 16); window.cancelAnimationFrame = clearTimeout;",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
        ))
        web.reload()
        try await waitForJavaScript(
            web,
            condition: "document.querySelectorAll('#typst-app .typst-doc > g.typst-page').length === 448",
        )
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('canvas').length") as? Int == 0)
        for page in [0, 223, 447, 0] {
            // Use the same navigation path as Return to Reading. A raw DOM
            // scroll can race its pending resize/reload anchor restoration.
            let restored = try await web.evaluateJavaScript(
                "window.leftblankRestoreReading({page: \(page), x: 0.5, y: 0, viewportY: 0})",
            )
            #expect(restored as? Bool == true)
            try await waitForJavaScript(
                web,
                condition: "(() => { const page = document.querySelector('.typst-doc > g.typst-page[data-page-number=\"\(page)\"]'); return page && page.querySelectorAll('use').length > 20 && page.getBoundingClientRect().top < innerHeight && page.getBoundingClientRect().bottom > 0; })()",
            )
            let snapshot = try await web.takeSnapshot(configuration: nil)
            #expect(snapshot.size.width >= 1800)
            let snapshotData = try #require(snapshot.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: snapshotData))
            var darkPixels = 0, lightPixels = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 16) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 16) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                        continue
                    }
                    let luminance = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                    if luminance < 0.3 {
                        darkPixels += 1
                    }
                    if luminance > 0.9 {
                        lightPixels += 1
                    }
                }
            }
            #expect(
                darkPixels > 10 && lightPixels > 100,
                "The WebKit snapshot must contain painted page content, not a blank surface",
            )
            let artifacts = repository.appendingPathComponent("build/benchmarks")
            try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: artifacts.appendingPathComponent("book-preview-\(page + 1).png"))
            #expect(try await web.evaluateJavaScript("document.querySelectorAll('canvas').length") as? Int == 0)
        }
        #expect(try await web
            .evaluateJavaScript("document.querySelectorAll('#typst-app .typst-doc > g.typst-page').length") as? Int ==
            448)
    }

    @Test func previewProcessTerminationRecoversOnceThenReportsFailure() {
        var errors: [String] = []
        let coordinator = PreviewView.Coordinator { errors.append($0) }
        let web = WKWebView()
        coordinator.webViewWebContentProcessDidTerminate(web)
        #expect(errors.isEmpty)
        coordinator.webViewWebContentProcessDidTerminate(web)
        #expect(errors.count == 1)
    }

    @Test func explicitSourceJumpsFollowInPreviewWithoutFollowingOrdinarySelection() async throws {
        let source = (1 ... 6).map { "= Chapter \($0)\n\nDistinct page \($0) content. 中文😀\n" }
            .joined(separator: "\n#pagebreak()\n")
        let app = try WritingFixture(text: source)
        defer { app.close() }
        try await app.ready()
        app.workspace.layout = .split
        await app.layout()
        let web = try #require(findWebView(app.window.contentView))
        web.configuration.preferences.inactiveSchedulingPolicy = .none
        // This fixture is intentionally offscreen. macOS 15 WebKit suspends
        // native smooth-scroll animation there even when JS timers are active.
        // Keep Tinymist's real destination and native scrolling; skip animation.
        let scheduling = """
        window.requestAnimationFrame = callback => setTimeout(() => callback(performance.now()), 16);
        window.cancelAnimationFrame = clearTimeout;
        const nativeScrollTo = Element.prototype.scrollTo;
        Element.prototype.scrollTo = function(options, ...rest) {
            if (options && typeof options === 'object') {
                const trace = {options, before: this.scrollTop, id: this.id};
                const result = nativeScrollTo.call(this, {...options, behavior: 'instant'});
                trace.after = this.scrollTop;
                window.leftblankRequestedScroll = trace;
                return result;
            }
            return nativeScrollTo.call(this, options, ...rest);
        };
        """
        web.configuration.userContentController.addUserScript(WKUserScript(
            source: scheduling,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
        ))
        web.reload()
        // Establish a ready old page first, reproducing reload's asynchronous
        // provisional-navigation callback on the CI WebKit version.
        try await waitForJavaScript(
            web,
            condition: "document.querySelectorAll('.typst-doc > g.typst-page').length === 6",
        )
        web.reload()
        // Queue the jump while the preview is still loading.
        app.workspace.jump(to: (source as NSString).range(of: "Chapter 6").location)
        try await waitForJavaScript(
            web,
            condition: "(() => { const page = document.querySelector('.typst-doc > g.typst-page[data-page-number=\"5\"]'); return page && page.getBoundingClientRect().top < innerHeight && page.getBoundingClientRect().bottom > 0; })()",
        )
        let editor = try #require(app.workspace.editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        await app.layout()
        #expect(try await (web
                .evaluateJavaScript("document.getElementById('typst-container-main').scrollTop") as? Double ?? 0) >
            1000)
        // Retain a real viewport anchor as Tinymist does during resize. The
        // explicit source jump must supersede that position, including when a
        // later rendering pass runs after the jump.
        try await web.evaluateJavaScript("""
        (() => {
            const impl = document.getElementById('typst-container').documents[0].impl;
            const svg = impl.hookedElem.firstElementChild;
            const scroll = impl.hookedElem.parentElement;
            const fixedTop = svg.getBoundingClientRect().top - scroll.getBoundingClientRect().top + scroll.scrollTop;
            impl.svgResizeAnchor = {
                contentY: (scroll.scrollTop - fixedTop) / impl.lastSvgScale,
                scaleRatio: impl.currentScaleRatio,
                viewportAnchor: impl.captureViewportTopResizeAnchor(svg, scroll)
            };
            impl.keepSvgResizeAnchorAlive();
        })()
        """)
        app.workspace.jump(to: (source as NSString).range(of: "Chapter 1").location)
        try await waitForJavaScript(
            web,
            condition: "document.getElementById('typst-container-main').scrollTop < innerHeight",
        )
        try await web.evaluateJavaScript("document.getElementById('typst-container').documents[0].impl.rescale$svg()")
        #expect(try await (web
                .evaluateJavaScript("document.getElementById('typst-container-main').scrollTop") as? Double ??
                .infinity) <
            820)
        #expect(editor.string == source)
        app.workspace.previewReading.followsWriting = true
        editor.setSelectedRange(NSRange(location: (source as NSString).range(of: "Chapter 4").location, length: 0))
        try await waitForJavaScript(
            web,
            condition: "(() => { const page = document.querySelector('g.typst-page[data-page-number=\"3\"]'); return page && page.getBoundingClientRect().top > 0 && page.getBoundingClientRect().bottom < innerHeight; })()",
        )
        let captured = try #require(await web.evaluateJavaScript("window.leftblankCaptureReading()"))
        let readingPosition = try #require(PreviewReadingAnchor(message: captured))
        try await app.wait { app.workspace.previewReading.anchor == readingPosition }
        app.workspace.previewReading.rememberReturnPosition()
        #expect(!app.workspace.previewReading.followsWriting)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(350))
        #expect(app.workspace.previewReading.returnAnchor == readingPosition)
        #expect(try await web.evaluateJavaScript("window.leftblankCaptureReading()?.page") as? Int == readingPosition
            .page)
    }

    @Test func realPreviewRetainsPagesOnErrorThenRecoversAndTogglesDark() async throws {
        _ = NSApplication.shared
        let originalAppearance = NSApp.appearance
        defer { NSApp.appearance = originalAppearance }
        let app = try WritingFixture(text: "= Preview sentinel\n\nA short paragraph.\n")
        defer { app.close() }
        try await app.ready()
        app.workspace.layout = .split
        await app.layout()
        let web = try #require(findWebView(app.window.contentView))
        // A hidden test window has no display ticks. Drive animation frames with
        // a timer so the real Tinymist WASM renderer can update its actual DOM.
        web.configuration.preferences.inactiveSchedulingPolicy = .none
        web.configuration.userContentController.addUserScript(WKUserScript(
            source: "window.requestAnimationFrame = callback => setTimeout(() => callback(performance.now()), 16); window.cancelAnimationFrame = clearTimeout; window.leftblankTestFrames = true;",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
        ))
        web.reload()
        // Wait for the reloaded document itself, not pages still shown by the
        // previous one, and for its load to finish so the preview coordinator
        // has applied its state before this test changes it.
        try await waitForJavaScript(
            web,
            condition: "window.leftblankTestFrames === true && document.querySelectorAll('#typst-app .typst-doc > g').length > 0",
        )
        try await app.wait { app.workspace.hasSuccessfulPreview && !web.isLoading }
        let initialURL = app.workspace.previewURL
        let before = try await web
            .evaluateJavaScript("document.querySelectorAll('#typst-app .typst-doc > g').length") as? Int
        #expect((before ?? 0) > 0)
        app.workspace.previewDark = true
        await app.layout()
        try await waitForJavaScript(
            web,
            condition: "document.getElementById('typst-app').classList.contains('invert-colors') && document.getElementById('typst-app').classList.contains('normal-image')",
        )
        // App appearance changes only the canvas, never the page color setting
        // or live renderer. Switching system appearance uses the same callback.
        for (appearance, canvas) in [(AppAppearance.light, "rgb(250, 250, 250)"), (.dark, "rgb(34, 38, 43)")] {
            app.workspace.appearance = appearance
            await app.layout()
            try await waitForJavaScript(
                web,
                condition: "getComputedStyle(document.body).backgroundColor === '\(canvas)'",
            )
            #expect(try await web
                .evaluateJavaScript(
                    "document.getElementById('typst-app').classList.contains('invert-colors')",
                ) as? Bool ==
                true)
            #expect(try await web
                .evaluateJavaScript("document.querySelectorAll('#typst-app .typst-doc > g').length") as? Int == before)
            for selector in ["html", "body", "#typst-container-main", "#typst-app"] {
                #expect(try await web
                    .evaluateJavaScript(
                        "getComputedStyle(document.querySelector('\(selector)')).backgroundColor",
                    ) as? String ==
                    canvas)
            }
            #expect(resolvedHex(web.underPageBackgroundColor, appearance: web.effectiveAppearance) ==
                (appearance == .dark ? 0x22262B : 0xFAFAFA))
            #expect(app.workspace.previewURL == initialURL)
        }
        app.workspace.previewZoom = 1.4
        await app.layout()
        try await waitForJavaScript(web, condition: "document.getElementById('typst-container').style.width === '140%'")
        let editor = try #require(app.workspace.editor)
        editor.insertSnippet(
            Snippet(text: "#unknown-function("),
            replacing: NSRange(location: editor.string.utf16.count, length: 0),
        )
        try await app.wait { app.workspace.diagnostics.contains { $0.severity == 1 } }
        #expect(app.workspace.previewStale)
        #expect(app.workspace.hasSuccessfulPreview)
        #expect(app.workspace.previewURL == initialURL)
        #expect(try await web
            .evaluateJavaScript("document.querySelectorAll('#typst-app .typst-doc > g').length") as? Int == before)
        editor.undoManager?.undo()
        try await app.wait { !app.workspace.previewStale && app.workspace.diagnostics.isEmpty }
        #expect(app.workspace.previewURL == initialURL)
        editor.insertSnippet(
            Snippet(text: "\n#pagebreak()\n= Recovered page\n"),
            replacing: NSRange(location: editor.string.utf16.count, length: 0),
        )
        try await app.wait { !app.workspace.previewStale }
        try await waitForJavaScript(
            web,
            condition: "document.querySelectorAll('#typst-app .typst-doc > g').length === 2",
        )
        app.workspace.previewDark = false
        await app.layout()
        try await waitForJavaScript(
            web,
            condition: "!document.getElementById('typst-app').classList.contains('invert-colors')",
        )
        app.workspace.appearance = .light
        await app.layout()
        try await waitForJavaScript(
            web,
            condition: "getComputedStyle(document.getElementById('typst-app')).backgroundColor === 'rgb(250, 250, 250)'",
        )
        // Query the actual hit-tested gap between two rendered pages, rather
        // than merely checking the inline body style (which CSS can override).
        let gapColor = try await web.evaluateJavaScript("""
        (() => {
            const pages = document.querySelectorAll('.typst-doc > rect.typst-page-inner');
            const scroll = document.getElementById('typst-container-main');
            const first = pages[0].getBoundingClientRect();
            const second = pages[1].getBoundingClientRect();
            scroll.scrollTop += (first.bottom + second.top) / 2 - innerHeight / 2;
            const a = pages[0].getBoundingClientRect(), b = pages[1].getBoundingClientRect();
            const x = Math.min(a.right, innerWidth) / 2, y = (a.bottom + b.top) / 2;
            if (b.top <= a.bottom) return 'missing page gap';
            let element = document.elementFromPoint(x, y);
            while (element) {
                const background = getComputedStyle(element).backgroundColor;
                if (background !== 'rgba(0, 0, 0, 0)') return background;
                element = element.parentElement;
            }
            return 'missing background';
        })()
        """) as? String
        #expect(gapColor == "rgb(250, 250, 250)")
        #expect(try await web
            .evaluateJavaScript("getComputedStyle(document.querySelector('.typst-page-outer')).fill") as? String ==
            "none")
        #expect(try await web
            .evaluateJavaScript("getComputedStyle(document.querySelector('.typst-page-inner')).fill") as? String ==
            "rgb(255, 255, 255)")
    }
}

@MainActor
func findWebView(_ view: NSView?) -> WKWebView? {
    guard let view else {
        return nil
    }
    if let web = view as? WKWebView {
        return web
    }
    return view.subviews.compactMap { findWebView($0) }.first
}

@MainActor
func waitForJavaScript(_ web: WKWebView, condition: String) async throws {
    let deadline = ContinuousClock.now + .seconds(15)
    while ContinuousClock.now < deadline {
        if await (try? web.evaluateJavaScript(condition)) as? Bool == true {
            return
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    let state = try? await web
        .evaluateJavaScript(
            "JSON.stringify({visibility:document.visibilityState, classes:document.getElementById('typst-app')?.className, dark:window.leftblankPreviewDark, requestedScroll:window.leftblankRequestedScroll, scroll:document.getElementById('typst-container-main')?.scrollTop, height:innerHeight, pages:[...document.querySelectorAll('.typst-doc > g.typst-page')].map(p=>({page:p.dataset.pageNumber,top:p.getBoundingClientRect().top,bottom:p.getBoundingClientRect().bottom})), renderers:document.getElementById('typst-container')?.documents?.map(d=>({rendering:d.impl.isRendering,initialized:d.impl.moduleInitialized,anchor:d.impl.svgResizeAnchor,scale:d.impl.lastSvgScale}))})",
        )
    Issue.record(
        "Preview did not reach expected state: \(condition); state: \(state ?? "unavailable"); loading: \(web.isLoading), in window: \(web.window != nil)",
    )
    throw CommandError.invalid("Preview state timed out")
}
