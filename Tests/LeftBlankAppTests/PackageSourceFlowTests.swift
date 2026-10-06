import AppKit
import Foundation
@testable import LeftBlankApp
import LeftBlankCore
import Testing

extension WritingFlowTests {
    @Test func diagnosticPackageSourceIsReadOnlyAndCommandWReturnsToDocument() throws {
        let app = try WritingFixture(text: "= Original\n\nBody\n", startService: false)
        defer { app.close() }
        let workspace = app.workspace
        let editor = try #require(workspace.editor)
        let package = workspace.packageCache.appendingPathComponent("preview/test/1.0.0/lib.typ")
        try FileManager.default.createDirectory(
            at: package.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        let source = "#let original = 1\n"
        try Data(source.utf8).write(to: package)
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        workspace.selection = editor.selectedRange()
        workspace.showDiagnostic(DiagnosticItem(
            message: "unresolved import",
            severity: 1,
            position: TextPosition(line: 0, character: 0),
            url: package,
        ))
        #expect(workspace.documentURL == package)
        #expect(workspace.compilationURL == app.document)
        #expect(workspace.isPackageSource)
        #expect(!editor.isEditable)
        #expect(editor.isSelectable)
        workspace.layout = .preview
        workspace.layout = .split
        workspace.togglePalette()
        workspace.closePalette()
        #expect(!editor.isEditable)
        editor.insertText("pasted document", replacementRange: NSRange(location: 0, length: source.utf16.count))
        editor.insertSnippet(Snippet(text: "overwrite"), replacing: NSRange(location: 0, length: source.utf16.count))
        workspace.edited("bypass")
        workspace.editLines(.comment)
        workspace.save()
        #expect(workspace.text == source)
        #expect(editor.string == source)
        #expect(throws: DocumentStorageError.self) { try workspace.save(to: package) }
        #expect(try String(contentsOf: package, encoding: .utf8) == source)

        let delegate = AppDelegate(workspace: workspace)
        let previousMenu = NSApp.mainMenu, previousWindows = NSApp.windowsMenu
        defer { NSApp.mainMenu = previousMenu
            NSApp.windowsMenu = previousWindows
        }
        delegate.installMenu()
        let menu = try #require(NSApp.mainMenu)
        #expect(!delegate.windowShouldClose(app.window))
        #expect(workspace.documentURL == app.document)
        #expect(workspace.mainFileURL == nil)
        #expect(workspace.selection.location == 5)
        #expect(editor.isEditable)
        #expect(editor.string == "= Original\n\nBody\n")
        editor.insertSnippet(Snippet(text: "More"), replacing: NSRange(location: editor.string.utf16.count, length: 0))
        #expect(!delegate.windowShouldClose(app.window))
        #expect(workspace.isLibraryHome)
        #expect(try String(contentsOf: app.document, encoding: .utf8).hasSuffix("More"))
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
        #expect(delegate.windowShouldClose(app.window) == false)
        let documents = try #require(menu.items
            .first { $0.submenu?.items.contains { $0.keyEquivalent == "w" } == true }?.submenu)
        #expect(documents.items.first { $0.keyEquivalent == "w" }?.title == L10n.text("Close Document"))
        #expect(menu.items.first?.submenu?.items.first { $0.keyEquivalent == "q" }?
            .action == #selector(NSApplication.terminate(_:)))
    }

    @Test func nestedDiagnosticsReturnInOrderAndReadOnlySourceCanBeSavedAsCopy() throws {
        let app = try WritingFixture(text: "= Root", startService: false)
        defer { app.close() }
        let workspace = app.workspace
        let chapter = app.root.appendingPathComponent("chapter.typ")
        try Data("Chapter".utf8).write(to: chapter)
        #expect(workspace.open(chapter, preservingMain: true))
        let package = workspace.packageCache.appendingPathComponent("preview/test/1.0.0/lib.typ")
        try FileManager.default.createDirectory(
            at: package.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try Data("#let value = 1".utf8).write(to: package)
        workspace.showDiagnostic(DiagnosticItem(
            message: "error",
            severity: 1,
            position: TextPosition(line: 0, character: 0),
            url: package,
        ))
        workspace.closeDocument()
        #expect(workspace.documentURL == chapter)
        #expect(workspace.compilationURL == app.document)
        workspace.navigateBack()
        #expect(workspace.documentURL == app.document)
        #expect(workspace.mainFileURL == nil)
        #expect(workspace.open(package, preservingMain: true))
        let copy = app.root.appendingPathComponent("copy.typ")
        try workspace.save(to: copy)
        #expect(workspace.canEditSource)
        #expect(workspace.editor?.isEditable == true)
        workspace.edited("My copy")
        workspace.save()
        #expect(try String(contentsOf: copy, encoding: .utf8) == "My copy")
        #expect(try String(contentsOf: package, encoding: .utf8) == "#let value = 1")
    }

    @Test func recoveredPackageSourceClosesBackToItsCompilationEntry() throws {
        let app = try WritingFixture(text: "= Root", startService: false)
        defer { app.close() }
        let package = app.workspace.packageCache.appendingPathComponent("preview/test/1.0.0/lib.typ")
        try FileManager.default.createDirectory(
            at: package.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try Data("#let value = 1".utf8).write(to: package)
        #expect(app.workspace.open(package, preservingMain: true))
        #expect(app.workspace.saveRecovery())
        let restored = Workspace(stateDirectory: app.workspace.stateDirectory)
        defer { restored.shutdown() }
        #expect(restored.isPackageSource)
        #expect(!restored.canEditSource)
        restored.closeDocument()
        #expect(restored.documentURL == app.document)
        #expect(restored.mainFileURL == nil)
        #expect(restored.canEditSource)
        #expect(restored.text == "= Root")
    }

    @Test func packageToolbarShowsFileNameAndReadOnlyBadgeAcrossAppearances() async throws {
        let language = L10n.language
        defer { L10n.setLanguage(language) }
        L10n.setLanguage(.simplifiedChinese)
        let app = try WritingFixture(text: "= Root", startService: false)
        defer { app.close() }
        app.window.orderFront(nil)
        let package = app.workspace.packageCache.appendingPathComponent("preview/test/1.0.0/shapes.typ")
        try FileManager.default.createDirectory(
            at: package.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try Data("#let value = 1".utf8).write(to: package)
        #expect(app.workspace.open(package, preservingMain: true))
        app.workspace.managedTitle = "Original manuscript"
        #expect(app.workspace.title == "shapes.typ")
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let title = try #require(app.window.toolbar?.items.first { $0.itemIdentifier.rawValue == "LeftBlankDocument" }?
            .view)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            app.window.appearance = NSAppearance(named: appearance)
            app.window.setContentSize(NSSize(width: 620, height: 540))
            await app.layout()
            let anchors = descendants(title).compactMap { $0 as? HelpAnchor }
            let badge = try #require(anchors.first { $0.title == L10n.text("Read-only Package") })
            #expect(badge.bounds.width >= 45)
            #expect(badge.bounds.height >= 18)
            #expect(title.fittingSize.width <= app.window.frame.width - 300)
            #expect(
                !descendants(title).contains { $0 is DocumentTitleField },
                "Package names must not rename the main document",
            )
            if let artifacts = ProcessInfo.processInfo.environment["LEFTBLANK_UI_ARTIFACTS"] {
                let directory = URL(fileURLWithPath: artifacts)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                // Supply the opaque window background when capturing just the toolbar item.
                title.wantsLayer = true
                title.effectiveAppearance.performAsCurrentDrawingAppearance {
                    title.layer?.backgroundColor = Theme.nativeEditor.cgColor
                }
                let bitmap = try #require(title.bitmapImageRepForCachingDisplay(in: title.bounds))
                title.cacheDisplay(in: title.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("readonly-toolbar-\(appearance.rawValue).png"))
            }
        }
        app.workspace.closeDocument()
        await app.layout()
        try await app.wait {
            title.layoutSubtreeIfNeeded()
            return descendants(title).contains { $0 is DocumentTitleField }
        }
        #expect(!descendants(title).compactMap { $0 as? HelpAnchor }
            .contains { $0.title == L10n.text("Read-only Package") })
        #expect(descendants(title).contains { $0 is DocumentTitleField })
    }
}
