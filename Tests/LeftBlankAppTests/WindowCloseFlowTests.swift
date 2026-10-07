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
        #expect(app.workspace.discoveryMode == .templates, "With no earlier document, closing offers templates")
        #expect(app.window.isVisible && settings.isVisible)
        #expect(try String(contentsOf: app.document, encoding: .utf8) == source)
    }

    @Test func closeDocumentReturnsToPreviouslyOpenedWritingThenTemplates() async throws {
        let app = try WritingFixture(text: "= External\n", startService: false)
        defer { app.close() }
        let library = app.workspace.library
        await library.start()
        var ids: [String: UUID] = [:]
        for name in ["First", "Second", "Third"] {
            try await library.create(title: name, text: "= \(name)\n")
            let id = try #require(app.workspace.managedDocumentID)
            ids[name] = id
        }
        // Opening order, not modification order, decides where Command-W returns.
        try await library.open(#require(ids["Second"]))
        try await library.open(#require(ids["First"]))
        let editor = try #require(app.workspace.editor)
        editor.insertSnippet(
            Snippet(text: "Unsaved ending.\n"),
            replacing: NSRange(location: editor.string.utf16.count, length: 0),
        )
        let delegate = AppDelegate(workspace: app.workspace)
        for expected in ["Second", "Third"] {
            #expect(!delegate.windowShouldClose(app.window))
            try await app.wait {
                app.workspace.managedDocumentID == ids[expected] && !app.workspace.documentTransitionInProgress
            }
            #expect(!app.workspace.isLibraryHome)
            #expect(app.workspace.editor?.string == "= \(expected)\n")
            #expect(app.workspace.editor?.isEditable == true)
            #expect(app.workspace.discoveryMode == nil)
        }
        #expect(try await library.store.read(#require(ids["First"])).text == "= First\nUnsaved ending.\n")

        #expect(!delegate.windowShouldClose(app.window))
        #expect(app.workspace.isLibraryHome)
        #expect(app.workspace.discoveryMode == .templates)
        #expect(!app.workspace.libraryOpen, "The template page is the main view, not a sheet")
        #expect(library.recentDocumentIDs.isEmpty)
        #expect(try await library.store.list().count == 3, "Closing never removes writing from the library")
        #expect(try String(contentsOf: app.document, encoding: .utf8) == "= External\n")
    }

    @Test func closeDocumentSkipsUnavailableRecentWritingAcrossLaunches() async throws {
        let app = try WritingFixture(text: "= External\n", startService: false)
        defer { app.close() }
        let library = app.workspace.library
        await library.start()
        var ids: [UUID] = []
        for name in ["First", "Second", "Third"] {
            try await library.create(title: name, text: "= \(name)\n")
            let id = try #require(app.workspace.managedDocumentID)
            ids.append(id)
        }
        let (first, second, third) = (ids[0], ids[1], ids[2])
        #expect(library.recentDocumentIDs == [third, second, first])
        // Trashed elsewhere (another Mac or an agent) and removed from disk without this window noticing.
        _ = try await library.store.trash(second)
        let missing = UUID()
        try JSONEncoder().encode([third, missing, second, first]).write(
            to: app.workspace.stateDirectory.appendingPathComponent("recent-documents.json"),
        )
        #expect(app.workspace.prepareToClose())
        library.stop()

        let relaunched = Workspace(stateDirectory: app.workspace.stateDirectory)
        defer { relaunched.shutdown() }
        await relaunched.library.start()
        #expect(relaunched.managedDocumentID == third)
        #expect(relaunched.library.recentDocumentIDs == [third, missing, second, first])
        relaunched.closeDocument()
        try await app.wait { relaunched.managedDocumentID == first && !relaunched.documentTransitionInProgress }
        #expect(relaunched.text == "= First\n")
        #expect(relaunched.library.recentDocumentIDs.first == first)
        #expect(!relaunched.library.recentDocumentIDs.contains(third))

        // A listed document that can no longer be read falls back to the template page.
        try await relaunched.library.restore(second)
        try FileManager.default
            .removeItem(at: #require(relaunched.library.documents.first { $0.id == second }?.folderURL))
        relaunched.closeDocument()
        try await app.wait { relaunched.isLibraryHome && !relaunched.documentTransitionInProgress }
        #expect(relaunched.discoveryMode == .templates)
        #expect(!relaunched.library.recentDocumentIDs.contains(first))
        #expect(!relaunched.library.recentDocumentIDs.contains(second))
        #expect(try await relaunched.library.store.read(first).text == "= First\n")
        let log = try String(
            contentsOf: relaunched.stateDirectory.appendingPathComponent("Logs/events.jsonl"),
            encoding: .utf8,
        )
        #expect(log.contains("library.reopenFailed"))
    }
}
