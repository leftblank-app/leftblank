import AppKit
@testable import LeftBlankApp
import LeftBlankCore
import Testing

extension WritingFlowTests {
    @Test func sourceHoverUsesPointerWithoutMovingCaretOrTakingFocus() async throws {
        let source = "// 中文 😀\n#rect(width: 20pt, height: 30pt)\n\nPlain writing.\n" + String(
            repeating: "More writing.\n",
            count: 80,
        )
        let app = try WritingFixture(text: source)
        defer { app.close() }
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        app.window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
        let selection = editor.selectedRange()
        let responder = app.window.firstResponder
        try await app.hover(over: "rect")
        try await Task.sleep(for: .milliseconds(150))
        #expect(editor.sourceHover.panel == nil)
        try await app.wait { editor.sourceHover.panel != nil }
        let panel = try #require(editor.sourceHover.panel)
        #expect(editor.sourceHover.help?.signature?.contains("rect") == true)
        #expect(editor.sourceHover.help?.documentation.lowercased().contains("rectangle") == true)
        #expect(editor.selectedRange() == selection)
        #expect(app.workspace.selection == selection)
        #expect(app.window.firstResponder === responder)
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(panel.parent === app.window)
        #expect(panel.frame.width == 360 && panel.frame.height <= 390)
        #expect(app.workspace.assistance == nil)
        #expect(editor.string == source)

        editor.sourceHover.scheduleDismissal()
        editor.sourceHover.keepVisible()
        try await Task.sleep(for: .milliseconds(250))
        #expect(editor.sourceHover.panel === panel, "Moving into the help card keeps it readable")
        editor.keyDown(with: app.key("\u{1b}", code: 53))
        #expect(editor.sourceHover.panel == nil)
        #expect(editor.selectedRange() == selection)

        try await app.hover(over: "Plain")
        try await Task.sleep(for: .milliseconds(650))
        #expect(editor.sourceHover.panel == nil, "Ordinary prose must not produce an empty help card")
        try await app.hover(over: "rect")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(650))
        #expect(editor.sourceHover.panel == nil, "A changed selection invalidates pending hover help")
        try await app.hover(over: "rect")
        editor.insertSnippet(Snippet(text: "// Changed\n"), replacing: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(650))
        #expect(editor.sourceHover.panel == nil, "Typing cannot be interrupted by an old hover result")
    }

    @Test func sourceHoverDismissesForScrollAndInputComposition() async throws {
        let app = try WritingFixture(text: "#rect(width: 20pt)\n" + String(repeating: "More writing.\n", count: 80))
        defer { app.close() }
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        try await app.hover(over: "rect")
        try await app.wait { editor.sourceHover.panel != nil }
        let clip = try #require(editor.enclosingScrollView?.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clip)
        #expect(editor.sourceHover.panel != nil, "An unchanged layout must not dismiss help")
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + 20))
        #expect(editor.sourceHover.panel == nil, "Scrolling dismisses help anchored to the old viewport")
        editor.setMarkedText(
            "拼",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0),
        )
        try #require(editor.hasMarkedText())
        try await app.hover(over: "rect")
        try await Task.sleep(for: .milliseconds(650))
        #expect(editor.sourceHover.panel == nil, "Hover cannot interrupt input-method composition")
        editor.unmarkText()
    }

    @Test func sourceHoverSupportsCustomAndPackageFunctionsAndBothAppearances() async throws {
        let source = "/// A friendly greeting.\n#let greet(name) = [Hello #name]\n#greet(\"Reader\")\n#import \"@preview/cetz:0.5.2\": canvas\n#canvas({})\n"
        let app = try WritingFixture(text: source)
        defer { app.close() }
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        let previousLanguage = L10n.language
        defer { L10n.setLanguage(previousLanguage) }
        L10n.setLanguage(.simplifiedChinese)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            app.window.appearance = NSAppearance(named: appearance)
            await app.layout()
            try await app.hover(over: "#greet", delta: 2)
            try await app.wait { editor.sourceHover.panel != nil }
            #expect(editor.sourceHover.help?.text.contains("friendly greeting") == true)
            let panel = try #require(editor.sourceHover.panel)
            #expect(panel.appearance?.name == appearance)
            if let artifacts = ProcessInfo.processInfo.environment["LEFTBLANK_UI_ARTIFACTS"] {
                let directory = URL(fileURLWithPath: artifacts)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let view = try #require(panel.contentView)
                view.layoutSubtreeIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("source-hover-\(appearance.rawValue).png"))
            }
            editor.sourceHover.dismiss()
        }
        try await app.hover(over: "#canvas", delta: 2)
        try await app.wait { editor.sourceHover.panel != nil }
        #expect(editor.sourceHover.help?.text.contains("canvas") == true)
        editor.sourceHover.scheduleDismissal()
        try await app.wait { editor.sourceHover.panel == nil }

        let call = (source as NSString).range(of: "#canvas").location + 2
        editor.setSelectedRange(NSRange(location: call, length: 0))
        app.workspace.goToDefinition()
        try await app.wait { app.workspace.isPackageSource }
        try await app.ready()
        #expect(!editor.isEditable)
        try await app.hover(over: "float(x)", delta: 1)
        try await app.wait { editor.sourceHover.panel != nil }
        #expect(editor.sourceHover.help?.documentationURL?.path.contains("float") == true)
        #expect(!editor.isEditable)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: app.window)
        #expect(editor.sourceHover.panel == nil)
    }
}

extension WritingFixture {
    func hover(over needle: String, delta: Int = 1) async throws {
        let editor = try #require(workspace.editor)
        // A real hover starts in an already displayed window. Showing a child
        // panel must not be the event that first lays out its hidden parent.
        window.orderFront(nil)
        await layout()
        try #require(window.isVisible)
        let range = (editor.string as NSString).range(of: needle)
        try #require(range.location != NSNotFound)
        let offset = range.location + delta
        editor.scrollRangeToVisible(NSRange(location: offset, length: 1))
        await layout()
        editor.prepareForPointerInteraction()
        let rect = editor.firstRect(forCharacterRange: NSRange(location: offset, length: 1), actualRange: nil)
        let point = window.convertFromScreen(NSRect(x: rect.minX + 1, y: rect.midY, width: 0, height: 0)).origin
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 0, pressure: 0,
        ))
        try #require(editor.sourceOffset(at: event) == offset)
        editor.mouseMoved(with: event)
    }
}
