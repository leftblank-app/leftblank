import AppKit
@testable import LeftBlankApp
import LeftBlankCore
import Testing

extension WritingFlowTests {
    @Test func longManuscriptCommandNavigation() async throws {
        let source = String(
            repeating: "= Chapter\n\nA paragraph with *strong*, _emphasis_ and `code`. 中文😀\n\n",
            count: 1500,
        )
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        app.workspace.togglePalette()
        app.workspace.searchMode = true
        app.workspace.query = ""
        await app.layout()
        let start = ContinuousClock.now
        for index in 0 ..< 500 {
            app.workspace.selectedCommandIndex = index % app.workspace.paletteEntryCount
            _ = app.workspace.highlightedCommand
            _ = app.workspace.filteredCommands
            _ = app.workspace.wordCount
            _ = app.workspace.position
        }
        let navigation = start.duration(to: .now)
        let editor = try #require(app.workspace.editor)
        let caretStart = ContinuousClock.now
        for index in 0 ..< 30 {
            editor.setSelectedRange(NSRange(location: index * 65, length: 0))
            editor.highlight()
        }
        let caret = caretStart.duration(to: .now)
        print(
            "LEFTBLANK PERFORMANCE: \(source.utf16.count) UTF16, 500 command selections \(navigation), 30 caret highlights \(caret)",
        )
        // Broad regression budgets tolerate instrumented CI and shared runners.
        // The old repeated-full-document path took 17.5 s and 13.4 s locally.
        #expect(navigation < .seconds(1))
        #expect(caret < .seconds(3))
        #expect(editor.string == source)
    }

    @Test func outlineAndCommandSelectionKeepTheWritingSurfaceStill() async throws {
        let app = try WritingFixture(text: "= First\n\nText\n\n== Second\n\nMore\n", startService: false)
        defer { app.close() }
        await app.layout()
        let editor = try #require(app.workspace.editor)
        let scroll = try #require(editor.enclosingScrollView)
        let frame = scroll.convert(scroll.bounds, to: nil)
        let inset = editor.textContainerInset
        app.workspace.outline = [
            .init(title: "First", level: 1, offset: 0),
            .init(title: "Second", level: 2, offset: 16),
        ]
        app.workspace.sidePanel = .outline
        await app.layout()
        #expect(scroll.convert(scroll.bounds, to: nil) == frame)
        #expect(editor.textContainerInset == inset)
        app.workspace.layout = .split
        await app.layout()
        let pin = try #require(descendants(app.window.contentView).compactMap { $0 as? HelpAnchor }
            .first { $0.title == L10n.text("Unpin outline") })
        let pinFrame = pin.convert(pin.bounds, to: nil)
        let sourceLeadingEdge = editor.convert(NSPoint(x: editor.textContainerInset.width, y: 0), to: nil).x
        #expect(
            pinFrame.maxX <= sourceLeadingEdge,
            "The pinned compact rail must fit beside the first source character",
        )
        app.workspace.layout = .writing
        await app.layout()
        app.workspace.jump(to: 16)
        app.workspace.sidePanel = nil
        app.workspace.togglePalette()
        await app.layout()
        let dockFrame = scroll.convert(scroll.bounds, to: nil)
        app.window.sendEvent(app.key("\u{f701}", code: 125))
        #expect(app.workspace.selectedCommandIndex == 3)
        app.window.sendEvent(app.key("\u{f703}", code: 124))
        #expect(app.workspace.selectedCommandIndex == 4)
        app.window.sendEvent(app.key("\u{f700}", code: 126))
        app.window.sendEvent(app.key("\u{f702}", code: 123))
        #expect(app.workspace.selectedCommandIndex == 0)
        app.workspace.searchMode = true
        for query in ["", "表格", "no-match", "page", ""] {
            app.workspace.query = query
            await app.layout()
            #expect(scroll.convert(scroll.bounds, to: nil) == dockFrame)
        }
        for index in stride(from: 0, to: app.workspace.paletteEntryCount, by: 8) {
            app.workspace.selectedCommandIndex = index
            await app.layout()
            #expect(scroll.convert(scroll.bounds, to: nil) == dockFrame)
        }
        let table = try #require(WritingCommand.all.first { $0.id == "table" })
        app.workspace.selectCommand(table)
        await app.layout()
        #expect(scroll.convert(scroll.bounds, to: nil) == dockFrame)
        app.workspace.backPalette()
        app.workspace.closePalette()
        await app.layout()
        #expect(scroll.convert(scroll.bounds, to: nil) == frame)
        #expect(editor.string == app.workspace.text)
    }

    @Test func narrowWindowCommandFormsAndIconsRemainAvailable() async throws {
        let app = try WritingFixture(text: "= Compact\n", startService: false)
        defer { app.close() }
        app.window.setContentSize(NSSize(width: 820, height: 540))
        app.workspace.togglePalette()
        for group in LeftBlankCore.CommandGroup.all {
            #expect(IconStore.image(group.icon) != nil)
            app.workspace.enterGroup(group.id)
            await app.layout()
        }
        #expect(Set(LeftBlankCore.CommandGroup.all.map(\.icon)).count == LeftBlankCore.CommandGroup.all.count)
        #expect(Set(WritingCommand.all.map(\.icon)).count == WritingCommand.all.count)
        for command in WritingCommand.all {
            let image = try #require(IconStore.image(command.icon))
            #expect(
                image.size.width <= 24 && image.size.height <= 24,
                "Native menu labels must not use the PDF artboard size",
            )
        }
        let cachedIcon = IconStore.image("command")
        #expect(cachedIcon === IconStore.image("command"))
        #expect(IconStore.image("missing-icon") == nil)
        #expect(IconStore.image("missing-icon") == nil)
        for command in WritingCommand.all.filter({ !$0.fields.isEmpty }) {
            let textFields = command.fields.filter { $0.resourceKind == nil }
            app.workspace.selectCommand(command)
            // SwiftUI may retain the previous form for more than one frame on
            // a shared runner. Wait for the actual form, not a fixed delay.
            try await app.wait {
                app.window.contentView?.layoutSubtreeIfNeeded()
                let current = descendants(app.window.contentView).compactMap { $0 as? FocusTextField }
                return current.compactMap { $0.accessibilityLabel() }.sorted() == textFields.map(\.title).sorted()
            }
            let fields = descendants(app.window.contentView).compactMap { $0 as? FocusTextField }
            #expect(fields.count == textFields.count, "Parameter form: \(command.id)")
            for field in fields {
                let frame = field.convert(field.bounds, to: nil)
                #expect(frame.minX >= 0 && frame.maxX <= app.window.frame.width)
                #expect(field.bounds.width > 70)
            }
        }
    }

    @Test func cachedMetricsAndParagraphStylesFollowEditsAndUndo() async throws {
        let original = "= 标题😀\n\n*bold* _italic_ `code`\n\nEnd\n"
        let app = try WritingFixture(text: original, startService: false)
        defer { app.close() }
        let editor = try #require(app.workspace.editor)
        for offset in [0, 5, 12, original.utf16.count, 0] {
            editor.setSelectedRange(NSRange(location: offset, length: 0))
            await app.settle(editor)
            #expect(app.workspace.position == TextPosition(offset: editor.selectedRange().location, in: original))
            #expect(app.workspace.wordCount == original.filter { !$0.isWhitespace }.count)
            // The heading keeps its font, marker included, wherever the caret is.
            let marker = try #require(editor.drawnAttribute(.font, at: 0) as? NSFont)
            #expect(marker.pointSize > app.workspace.fontSize)
        }
        editor.insertSnippet(Snippet(text: "新行😀\n"), replacing: NSRange(location: 0, length: 0))
        #expect(app.workspace.wordCount == editor.string.filter { !$0.isWhitespace }.count)
        editor.undoManager?.undo()
        editor.highlight()
        #expect(editor.string == original)
        #expect(app.workspace.wordCount == original.filter { !$0.isWhitespace }.count)
        app.workspace.fontSize = 20
        await app.layout()
        #expect(editor.appliedFontSize == 20)
    }

    @Test func toolbarLearningHintsAreAnchoredAndDoNotEditTheDocument() async throws {
        let app = try WritingFixture(text: "= Learn\n", startService: false)
        defer { app.close() }
        await app.layout()
        let toolbar = try #require(app.window.toolbar)
        let anchors = toolbar.items.flatMap { descendants($0.view) }.compactMap { $0 as? HelpAnchor }
        #expect(anchors.count == 6)
        #expect(anchors.filter { $0.shortcut != nil }.count == 5)
        for anchor in anchors {
            #expect(anchor.bounds.width >= 25)
            #expect(anchor.bounds.height >= 25)
            #expect(!anchor.title.isEmpty)
            anchor.showHelp()
            let size = try #require(anchor.popover?.contentSize)
            #expect(size.height <= 48 && size.height >= 24, "Help must hug its single line, not expand into a card")
            #expect(size.width <= 320 && size.width >= 80)
            anchor.dismiss()
        }
        #expect(app.workspace.text == "= Learn\n")
        app.window.orderFront(nil)
        func click(_ anchor: HelpAnchor, nearEdge: Bool = false) throws {
            let point = anchor.convert(NSPoint(x: nearEdge ? 3 : anchor.bounds.midX, y: anchor.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                try app.window.sendEvent(#require(NSEvent.mouseEvent(
                    with: type,
                    location: point,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: app.window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1,
                )))
            }
        }
        // Compact glyphs still have full-sized targets, including the empty
        // area beside the icon. Exercise the production responder path.
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            app.window.appearance = NSAppearance(named: appearance)
            for (title, layout) in [
                ("Read the Preview", EditorLayout.preview),
                ("Focus on Writing", .writing),
                ("Side-by-side Preview", .split),
            ] {
                await app.layout()
                let anchor = try #require(anchors.first { $0.title == L10n.text(title) })
                try click(anchor, nearEdge: true)
                #expect(app.workspace.layout == layout)
                #expect(app.workspace.text == "= Learn\n")
            }
        }
        app.workspace.layout = .split
        await app.layout()
        let reveal = try #require(descendants(app.window.contentView).compactMap { $0 as? HelpAnchor }
            .first { $0.title == L10n.text("Preview") })
        try click(reveal)
        await app.layout()
        for dark in [false, true, false] {
            app.workspace.previewDark = dark
            await app.layout()
            let colors = try #require(descendants(app.window.contentView).compactMap { $0 as? HelpAnchor }
                .first { $0.title == L10n.text("Preview Colors") })
            #expect(colors.bounds.width == 68)
            #expect(colors.bounds.height == 28)
        }
        let zoomOut = try #require(descendants(app.window.contentView).compactMap { $0 as? HelpAnchor }
            .first { $0.title == L10n.text("Zoom Out") })
        let zoomIn = try #require(descendants(app.window.contentView).compactMap { $0 as? HelpAnchor }
            .first { $0.title == L10n.text("Zoom In") })
        app.workspace.previewZoom = 1
        await app.layout()
        try click(zoomIn, nearEdge: true)
        #expect(abs(app.workspace.previewZoom - 1.1) < 0.001)
        try click(zoomOut, nearEdge: true)
        #expect(abs(app.workspace.previewZoom - 1) < 0.001)
        for (limit, anchor) in [(0.5, zoomOut), (2.0, zoomIn)] {
            app.workspace.previewZoom = limit
            await app.layout()
            try click(anchor)
            #expect(abs(app.workspace.previewZoom - limit) < 0.001)
        }
    }
}

@MainActor
private func descendants(_ view: NSView?) -> [NSView] {
    guard let view else {
        return []
    }
    return [view] + view.subviews.flatMap { descendants($0) }
}
