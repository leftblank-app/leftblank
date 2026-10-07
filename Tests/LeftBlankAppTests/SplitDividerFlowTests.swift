import AppKit
@testable import LeftBlankApp
import LeftBlankCore
import Testing

extension WritingFlowTests {
    @Test func sideBySideDividerDragsPersistsAndResets() async throws {
        let suite = "LeftBlank.split.flow." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = "= Split\n\nA quiet 中文😀 paragraph.\n"
        let app = try WritingFixture(text: source, defaults: defaults)
        defer { app.close() }
        app.window.orderFront(nil)
        // A real preview web view must sit beneath the divider's target.
        try await app.ready()
        #expect(dividers(app).isEmpty, "Writing mode has no divider target")

        app.workspace.layout = .split
        await app.layout()
        let web = try #require(views(app).compactMap { $0 as? PreviewWebView }.first)
        let divider = try #require(dividers(app).first)
        let area = try #require(app.window.contentView).bounds.width
        #expect(abs(editorWidth(app) - (area - 1) / 2) <= 1)
        #expect(divider.accessibilityIdentifier() == "split-divider")
        #expect(divider.accessibilityRole() == .splitter)
        #expect(divider.accessibilityLabel() == L10n.text("Resize Writing and Preview"))
        #expect(divider.accessibilityValue() as? String == "50%")
        // The target covers a few points on both sides of the 1 pt line,
        // above the editor and the preview.
        let center = divider.convert(NSPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil)
        for offset: CGFloat in [-4, 0, 4] {
            #expect(hit(app, NSPoint(x: center.x + offset, y: center.y)) === divider)
        }
        #expect(hit(app, NSPoint(x: center.x - 12, y: center.y)) !== divider)

        let start = editorWidth(app)
        let preview = app.workspace.previewURL
        try drag(app, from: center, by: [-40, -90, -150])
        await app.layout()
        // Resizing reflows the same mounted preview; it never remounts or reloads it.
        #expect(app.workspace.previewURL == preview)
        #expect(views(app).compactMap { $0 as? PreviewWebView }.first === web)
        #expect(abs(web.convert(web.bounds, to: nil).width - (area - 1 - editorWidth(app))) <= 1)
        #expect(abs(editorWidth(app) - (start - 150)) <= 1)
        #expect(abs(dividerX(app) - editorWidth(app)) <= 1, "The divider follows the editor edge")
        let dragged = SplitLayout.fraction(editorWidth: editorWidth(app), in: area, divider: 1)
        #expect(abs(SplitLayout.storedFraction(in: defaults) - dragged) < 0.002)
        #expect(app.workspace.text == source)

        // A new window, like a relaunch, restores the stored ratio.
        let next = try WritingFixture(text: source, startService: false, defaults: defaults)
        next.workspace.layout = .split
        await next.layout()
        #expect(abs(editorWidth(next) - editorWidth(app)) <= 1)
        next.close()

        // Resizing the window keeps the ratio rather than the width.
        app.window.setContentSize(NSSize(width: 1600, height: 820))
        await app.layout()
        let wide = try #require(app.window.contentView).bounds.width
        #expect(abs(editorWidth(app) - SplitLayout.editorWidth(in: wide, fraction: dragged, divider: 1)) <= 1)
        app.window.setContentSize(NSSize(width: area, height: 820))
        await app.layout()

        // In an ordinary window the minimum pane width, not the ratio limit,
        // stops the divider on either side.
        try drag(app, from: currentDivider(app).convert(NSPoint(x: 5, y: 200), to: nil), by: [-400, -2000])
        await app.layout()
        #expect(abs(editorWidth(app) - SplitLayout.minimumPaneWidth) <= 1)
        #expect(abs(SplitLayout.storedFraction(in: defaults) - SplitLayout.fractionRange.lowerBound) < 0.001)
        try drag(app, from: currentDivider(app).convert(NSPoint(x: 5, y: 200), to: nil), by: [3000])
        await app.layout()
        #expect(abs(area - 1 - editorWidth(app) - SplitLayout.minimumPaneWidth) <= 1)
        #expect(abs(SplitLayout.storedFraction(in: defaults) - SplitLayout.fractionRange.upperBound) < 0.001)

        // VoiceOver can move the divider in steps.
        let before = editorWidth(app)
        #expect(try currentDivider(app).accessibilityPerformDecrement())
        await app.layout()
        #expect(editorWidth(app) < before)
        let decremented = editorWidth(app)
        #expect(try currentDivider(app).accessibilityPerformIncrement())
        await app.layout()
        #expect(editorWidth(app) > decremented)

        // Double-clicking restores equal panes and stores that choice.
        let reset = try currentDivider(app).convert(NSPoint(x: 5, y: 200), to: nil)
        try click(app, at: reset, count: 1)
        try click(app, at: reset, count: 2)
        await app.layout()
        #expect(abs(editorWidth(app) - (area - 1) / 2) <= 1)
        #expect(SplitLayout.storedFraction(in: defaults) == SplitLayout.defaultFraction)

        // Other layouts keep no target at the former divider or window edges.
        for layout in [EditorLayout.writing, .preview] {
            app.workspace.layout = layout
            await app.layout()
            #expect(dividers(app).isEmpty)
            for x in [2, reset.x, area - 2] {
                #expect(!(hit(app, NSPoint(x: x, y: 200)) is SplitDividerView))
            }
        }
        #expect(app.workspace.text == source)
    }

    private func views(_ app: WritingFixture) -> [NSView] {
        func all(_ view: NSView?) -> [NSView] {
            guard let view else {
                return []
            }
            return [view] + view.subviews.flatMap(all)
        }
        return all(app.window.contentView)
    }

    private func dividers(_ app: WritingFixture) -> [SplitDividerView] {
        views(app).compactMap { $0 as? SplitDividerView }
    }

    private func currentDivider(_ app: WritingFixture) throws -> SplitDividerView {
        try #require(dividers(app).first)
    }

    private func editorWidth(_ app: WritingFixture) -> CGFloat {
        guard let scroll = app.workspace.editor?.enclosingScrollView else {
            return -1
        }
        return scroll.convert(scroll.bounds, to: nil).width
    }

    private func dividerX(_ app: WritingFixture) -> CGFloat {
        guard let divider = dividers(app).first else {
            return -1
        }
        return divider.convert(divider.bounds, to: nil).midX
    }

    private func hit(_ app: WritingFixture, _ point: NSPoint) -> NSView? {
        guard let content = app.window.contentView else {
            return nil
        }
        return content.hitTest(content.superview?.convert(point, from: nil) ?? point)
    }

    private func mouse(
        _ app: WritingFixture,
        _ type: NSEvent.EventType,
        at point: NSPoint,
        count: Int = 1,
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: app.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: count,
            pressure: type == .leftMouseUp ? 0 : 1,
        ))
    }

    /// Sends a press, intermediate drags and a release through the window.
    private func drag(_ app: WritingFixture, from point: NSPoint, by distances: [CGFloat]) throws {
        try app.window.sendEvent(mouse(app, .leftMouseDown, at: point))
        for distance in distances {
            try app.window.sendEvent(mouse(app, .leftMouseDragged, at: NSPoint(x: point.x + distance, y: point.y)))
            app.window.contentView?.layoutSubtreeIfNeeded()
        }
        let end = NSPoint(x: point.x + (distances.last ?? 0), y: point.y)
        try app.window.sendEvent(mouse(app, .leftMouseUp, at: end))
    }

    private func click(_ app: WritingFixture, at point: NSPoint, count: Int) throws {
        try app.window.sendEvent(mouse(app, .leftMouseDown, at: point, count: count))
        try app.window.sendEvent(mouse(app, .leftMouseUp, at: point, count: count))
    }
}
