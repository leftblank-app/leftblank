import AppKit
@testable import LeftBlankApp
import LeftBlankCore
import Testing

extension WritingFlowTests {
    @Test func closeCommandUsesTheWindowResponder() throws {
        let source = "= Keep this document open\n"
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        let delegate = AppDelegate(workspace: app.workspace)
        let previousMenu = NSApp.mainMenu, previousWindows = NSApp.windowsMenu
        defer {
            NSApp.mainMenu = previousMenu
            NSApp.windowsMenu = previousWindows
            app.window.delegate = nil
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        }
        delegate.installMenu()
        app.window.delegate = delegate
        app.window.orderFront(nil)
        let menu = try #require(NSApp.mainMenu)
        let close = try #require(menu.items.flatMap { $0.submenu?.items ?? [] }
            .first { $0.keyEquivalent == "w" })
        // A nil target lets AppKit choose the active window through the responder chain.
        #expect(close.target == nil)
        #expect(close.action == #selector(NSWindow.performClose(_:)))
        let action = try #require(close.action)
        #expect(menu.performKeyEquivalent(with: app.key(",", code: 43, modifiers: .command)))
        let settings = try #require(NSApp.windows.first {
            $0 !== app.window && $0.isVisible && $0.title == L10n.text("Settings")
        })
        defer { settings.close() }
        #expect(NSApp.sendAction(action, to: settings, from: close))
        #expect(!settings.isVisible)
        #expect(app.window.isVisible)
        #expect(!app.workspace.isLibraryHome)
        #expect(app.workspace.fileURL == app.document)
        #expect(app.workspace.text == source)

        // A different auxiliary window uses the same action, without a settings special case.
        let auxiliary = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: false,
        )
        auxiliary.isReleasedWhenClosed = false
        auxiliary.orderFront(nil)
        defer { auxiliary.close() }
        #expect(NSApp.sendAction(action, to: auxiliary, from: close))
        #expect(!auxiliary.isVisible)
        #expect(app.workspace.fileURL == app.document)

        // The writing window delegates closure to the document, even while settings is visible.
        #expect(menu.performKeyEquivalent(with: app.key(",", code: 43, modifiers: .command)))
        #expect(settings.isVisible)
        #expect(!delegate.windowShouldClose(app.window))
        #expect(app.workspace.isLibraryHome)
        #expect(app.window.isVisible && settings.isVisible)
        #expect(try String(contentsOf: app.document, encoding: .utf8) == source)
    }
}
