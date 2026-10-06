import AppKit
@testable import LeftBlankApp
import LeftBlankCore
import PDFKit
import SwiftUI
import Testing

extension WritingFlowTests {
    @Test(arguments: [false, true])
    func blankCreationReturnsToWriting(closeFirst: Bool) async throws {
        let app = try WritingFixture(text: "= Preserve this document\n", startService: false)
        defer { app.close() }
        await app.workspace.library.start()
        let delegate = AppDelegate(workspace: app.workspace)
        let previousMenu = NSApp.mainMenu, previousWindowsMenu = NSApp.windowsMenu
        defer { NSApp.mainMenu = previousMenu
            NSApp.windowsMenu = previousWindowsMenu
        }
        delegate.installMenu()
        app.window.delegate = delegate
        defer { app.window.delegate = nil }
        let menu = try #require(NSApp.mainMenu)
        app.window.orderFront(nil)
        if closeFirst {
            #expect(menu.performKeyEquivalent(with: app.key("w", code: 13, modifiers: .command)))
            await app.layout()
        }
        #expect(app.workspace.isLibraryHome == closeFirst)
        app.workspace.openDiscovery(.templates)
        await app.layout()
        #expect(app.workspace.libraryOpen == !closeFirst)
        if !closeFirst {
            try await app.wait { app.window.attachedSheet != nil }
        }
        let browserWindow = app.window.attachedSheet ?? app.window
        func blankButton(in view: NSView) -> HelpAnchor? {
            if let anchor = view as? HelpAnchor, anchor.title == L10n.text("Start with a blank page") {
                return anchor
            }
            return view.subviews.lazy.compactMap { blankButton(in: $0) }.first
        }
        let view = try #require(browserWindow.contentView)
        let button = try #require(blankButton(in: view))
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            try browserWindow.sendEvent(#require(NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: browserWindow.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1,
            )))
        }
        try await app.wait {
            app.workspace.managedDocumentID != nil && app.workspace.discoveryMode == nil &&
                app.window.attachedSheet == nil
        }
        await app.layout()
        #expect(!app.workspace.isLibraryHome)
        #expect(!app.workspace.libraryOpen)
        #expect(app.window.isVisible)
        #expect(app.workspace.discoveryMode == nil)
        let documents = try await app.workspace.library.store.list()
        #expect(documents.count == 1)
        let document = try #require(documents.first)
        #expect(app.workspace.managedDocumentID == document.id)
        #expect(app.workspace.fileURL == document.sourceURL)
        #expect(app.workspace.editor?.string == DocumentTemplate.blank.source)
        #expect(app.workspace.editor?.isEditable == true)
        #expect(try String(contentsOf: app.document, encoding: .utf8) == "= Preserve this document\n")
    }

    @Test func newDocumentDiscoversTemplatesWithoutCreatingOrReplacingWriting() async throws {
        let app = try WritingFixture(text: "= My unfinished idea\n", startService: false)
        defer { app.close() }
        let delegate = AppDelegate(workspace: app.workspace)
        let previousMenu = NSApp.mainMenu, previousWindowsMenu = NSApp.windowsMenu
        defer { NSApp.mainMenu = previousMenu
            NSApp.windowsMenu = previousWindowsMenu
        }
        delegate.installMenu()
        let menu = try #require(NSApp.mainMenu)
        #expect(menu.performKeyEquivalent(with: app.key("n", code: 45, modifiers: .command)))
        #expect(app.workspace.discoveryMode == .templates)
        #expect(app.workspace.libraryOpen)
        #expect(try await app.workspace.library.store.list().isEmpty)
        #expect(app.workspace.text == "= My unfinished idea\n")
        app.workspace.openLibrary()
        #expect(app.workspace.discoveryMode == nil)
        try app.workspace.execute(#require(WritingCommand.all.first { $0.id == "universe" }))
        #expect(app.workspace.discoveryMode == .packages)
        app.workspace.newDocument()
        #expect(app.workspace.discoveryMode == .templates)
        #expect(app.workspace.fileURL == app.document)
        #expect(!WritingCommand.all.contains { $0.id == "newCodeNotes" })
        #expect(WritingCommand.search("模板").contains { $0.id == "new" })

        // A saved legacy preference must not turn the explicit blank choice into code notes.
        app.workspace.documentTemplate = .codeNotes
        try await app.workspace.library.create(builtIn: .blank)
        #expect(!app.workspace.libraryOpen)
        #expect(app.workspace.managedDocumentID != nil)
        #expect(app.workspace.text == DocumentTemplate.blank.source)
        #expect(try String(contentsOf: app.document, encoding: .utf8) == "= My unfinished idea\n")
        app.workspace.showLibraryHome()
        app.workspace.newDocument()
        #expect(app.workspace.discoveryMode == .templates)
        #expect(
            !app.workspace.libraryOpen,
            "An empty library changes its inline route, never presents a sheet on itself",
        )
    }

    @Test func welcomeCreationCompilesBothLanguagesAndPreservesExistingWriting() async throws {
        let app = try WritingFixture(text: "= My own words\n", startService: false)
        defer { app.close() }
        let language = L10n.language
        defer { L10n.setLanguage(language) }
        var previousID: UUID?
        for language in [AppLanguage.english, .simplifiedChinese] {
            L10n.setLanguage(language)
            try await app.workspace.library.create(builtIn: .welcome)
            let id = try #require(app.workspace.managedDocumentID)
            #expect(id != previousID)
            previousID = id
            #expect(app.workspace.text == WelcomeDocument.source(language: language))
            let sourceURL = try #require(app.workspace.fileURL)
            let originalMark = try WelcomeDocument.assets()[WelcomeDocument.markFilename]
            #expect(try Data(contentsOf: sourceURL.deletingLastPathComponent()
                    .appendingPathComponent(WelcomeDocument.markFilename)) == originalMark)
            let exported = app.root.appendingPathComponent("welcome-project-\(language.rawValue)")
            try await app.workspace.library.store.exportProject(id, to: exported)
            #expect(
                try Data(contentsOf: exported.appendingPathComponent(WelcomeDocument.markFilename)) == originalMark,
                "Source export must retain the document's logo asset",
            )
            try await app.ready()
            let pdf = app.root.appendingPathComponent("welcome-\(language.rawValue).pdf")
            try await app.workspace.exportPDF(to: pdf)
            let result = try #require(PDFDocument(url: pdf))
            #expect(result.pageCount == 2)
            #expect(result.string?.contains(language == .english ? "Follow the thread" : "顺着思路写下去") == true)
            #expect(result.string?.contains("observations") == true)
            #expect(!app.workspace.diagnostics.contains { $0.severity == 1 })
        }
        #expect(try String(contentsOf: app.document, encoding: .utf8) == "= My own words\n")
        let saved = app.workspace.text
        L10n.setLanguage(.english)
        #expect(app.workspace.text == saved, "Interface language changes never replace writing")
        #expect(try await app.workspace.library.store.list().count == 2)
        let fresh = Workspace(stateDirectory: app.root.appendingPathComponent("Fresh"))
        defer { fresh.shutdown() }
        #expect(fresh.text == WelcomeDocument.source(language: .english))
        #expect(fresh.layout == .split)
        #expect(fresh.text.contains("@preview/cetz:0.5.2"))
        #expect(FileManager.default
            .fileExists(atPath: fresh.stateDirectory.appendingPathComponent(WelcomeDocument.markFilename).path))
        fresh.save()
        let recovered = Workspace(stateDirectory: fresh.stateDirectory)
        defer { recovered.shutdown() }
        #expect(recovered.text == fresh.text)
    }
}
