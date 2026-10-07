import AppKit
import Foundation
@testable import LeftBlankApp
import LeftBlankCore
import LeftBlankTestSupport
import PDFKit
import SwiftUI
import Testing

/// These tests exercise the production window, editor, document controller and
/// actual Tinymist process together. No alternate editor or fake LSP is used.
/// All native UI scenarios share this serialized suite: NSApplication, menus,
/// field editors and sheet presentation are process-wide, even across windows.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LEFTBLANK_INTEGRATION"] == "1"))
@MainActor
struct WritingFlowTests {
    @Test func directShortcutsAndLeaderPathsShareTheSameActions() async throws {
        let app = try WritingFixture(text: "= Shortcuts\n\nBody\n", startService: false)
        defer { app.close() }
        let delegate = AppDelegate(workspace: app.workspace)
        let previousMenu = NSApp.mainMenu, previousWindowsMenu = NSApp.windowsMenu
        defer { NSApp.mainMenu = previousMenu
            NSApp.windowsMenu = previousWindowsMenu
        }
        delegate.installMenu()
        let menu = try #require(NSApp.mainMenu)
        #expect(menu.performKeyEquivalent(with: app.key("4", code: 21, modifiers: .command)))
        #expect(app.workspace.sidePanel == .outline)
        app.window.sendEvent(app.key(app.workspace.commandKey, code: 38, modifiers: .command))
        app.window.sendEvent(app.key("v", code: 9))
        app.window.sendEvent(app.key("o", code: 31))
        #expect(app.workspace.sidePanel == nil)
        #expect(!app.workspace.paletteOpen)
        #expect(menu.performKeyEquivalent(with: app.key("5", code: 23, modifiers: .command)))
        #expect(app.workspace.checksOpen)
        app.window.sendEvent(app.key("\u{1b}", code: 53))
        #expect(app.workspace.sidePanel == nil)
        let editor = try #require(app.workspace.editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(menu.performKeyEquivalent(with: app.key("]", code: 30, modifiers: .command)))
        #expect(editor.string.hasPrefix("  = Shortcuts"))
        #expect(menu.performKeyEquivalent(with: app.key("[", code: 33, modifiers: .command)))
        #expect(editor.string.hasPrefix("= Shortcuts"))
        #expect(menu.performKeyEquivalent(with: app.key("/", code: 44, modifiers: .command)))
        #expect(editor.string.hasPrefix("// = Shortcuts"))
        app.workspace.togglePalette()
        app.workspace.searchMode = true
        app.workspace.query = "撤销"
        try app.workspace.selectCommand(#require(app.workspace.filteredCommands.first))
        #expect(editor.string.hasPrefix("= Shortcuts"))
        try app.workspace.execute(#require(WritingCommand.all.first { $0.id == "redo" }))
        #expect(editor.string.hasPrefix("// = Shortcuts"))
        let outline = try #require(WritingCommand.search("⌘4").first)
        #expect(outline.id == "outline")
        #expect(outline.keyPath == "v o")
        #expect(outline.shortcuts.first?.label == "⌘4")
        #expect(WritingCommand.all.filter { !$0.shortcuts.isEmpty }.count == 31)
        // Control-Command-R repeats the previous call (a chip) at the caret.
        editor.insertSnippet(Snippet(text: "#let item(id) = [#id]\n#item(\"A1\")\n"), replacing: NSRange(
            location: editor.string.utf16.count,
            length: 0,
        ))
        #expect(menu.performKeyEquivalent(with: app.key("r", code: 15, modifiers: [.control, .command])))
        try await app.wait { editor.string.hasSuffix("#item(\"\")") }
    }

    @Test func discoverInsertUndoRedoAndExport() async throws {
        let app = try WritingFixture(text: "= Writing flow\n\nBody\n\n")
        defer { app.close() }
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        app.window.sendEvent(app.key(app.workspace.commandKey, code: 38, modifiers: .command))
        #expect(app.workspace.paletteOpen)
        #expect(!editor.isEditable)
        app.window.sendEvent(app.key("/", code: 44))
        #expect(app.workspace.searchMode)
        app.workspace.query = "表格"
        #expect(app.workspace.filteredCommands.contains { $0.id == "table" })
        let table = try #require(app.workspace.filteredCommands.first { $0.id == "table" })
        app.workspace.selectCommand(table)
        await app.layout()
        #expect(app.workspace.activeCommand?.id == "table")
        app.workspace.fieldValues["columns"] = "2"
        app.workspace.fieldValues["rows"] = "2"
        app.workspace.execute(table)
        try await app.wait { !app.workspace.applyingCommand }
        #expect(!app.workspace.paletteOpen)
        #expect(editor.string.contains("#table("))
        #expect(editor.string == app.workspace.text)
        let inserted = editor.string
        let firstPlaceholder = editor.selectedRange()
        editor.keyDown(with: app.key("\t", code: 48))
        #expect(editor.selectedRange() != firstPlaceholder)
        editor.keyDown(with: app.key("\t", code: 48, modifiers: .shift))
        #expect(editor.selectedRange() == firstPlaceholder)
        editor.keyDown(with: app.key("\u{1b}", code: 53))
        #expect(editor.selectedRange().length == 0)
        let undo = try #require(editor.undoManager)
        #expect(undo.canUndo)
        undo.undo()
        #expect(!editor.string.contains("#table("))
        #expect(app.workspace.text == editor.string)
        undo.redo()
        #expect(editor.string == inserted)
        #expect(app.workspace.text == editor.string)
        let pdf = app.root.appendingPathComponent("writing.pdf")
        try await app.workspace.exportPDF(to: pdf)
        #expect(PDFDocument(url: pdf)?.string?.contains("Writing flow") == true)
        let log = try String(
            contentsOf: app.workspace.stateDirectory.appendingPathComponent("Logs/events.jsonl"),
            encoding: .utf8,
        )
        #expect(log.contains("insertion.finished"))
        #expect(log.contains("TABLE") == false)
        #expect(!log.contains("Writing flow"))
    }

    @Test func invalidParametersAndCodeContextLeaveDocumentUntouched() async throws {
        let app = try WritingFixture(text: "= Safe insertion\n\n$ x + y $\n\n")
        defer { app.close() }
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        let original = editor.string
        let math = (original as NSString).range(of: "x + y")
        editor.setSelectedRange(NSRange(location: math.location + 2, length: 0))
        app.workspace.togglePalette()
        let bold = try #require(WritingCommand.all.first { $0.id == "bold" })
        app.workspace.selectCommand(bold)
        try await app.wait { !app.workspace.applyingCommand }
        #expect(editor.string == original)
        #expect(app.workspace.commandError != nil)
        app.workspace.closePalette()
        editor.setSelectedRange(NSRange(location: original.utf16.count, length: 0))
        app.workspace.togglePalette()
        let table = try #require(WritingCommand.all.first { $0.id == "table" })
        app.workspace.selectCommand(table)
        app.workspace.fieldValues["columns"] = "0"
        app.workspace.execute(table)
        try await app.wait { !app.workspace.applyingCommand }
        #expect(editor.string == original)
        #expect(app.workspace.commandError != nil)
        app.workspace.fieldValues["columns"] = "2"
        app.workspace.execute(table)
        try await app.wait { !app.workspace.applyingCommand }
        #expect(editor.string.contains("#table("))
    }

    @Test func editingBackToSavedContentRestoresSavedStatus() async throws {
        let original = "= Original\nSaved 中文😀\n"
        let app = try WritingFixture(text: original)
        defer { app.close() }
        try await app.ready()
        #expect(!app.workspace.hasUnsavedChanges)
        app.workspace.edited("Temporary replacement")
        #expect(app.workspace.hasUnsavedChanges)
        // Same length, one character different: the literal comparison decides.
        app.workspace.edited(original.replacingOccurrences(of: "中", with: "文"))
        #expect(app.workspace.hasUnsavedChanges)
        app.workspace.edited(original)
        #expect(!app.workspace.hasUnsavedChanges)
        app.workspace.save()
        #expect(app.workspace.saveStatus == "Saved")
        #expect(app.workspace.savedText == original)
        #expect(try String(contentsOf: app.document, encoding: .utf8) == original)
    }

    @Test func documentSaveConflictReloadAndRecovery() async throws {
        let app = try WritingFixture(text: "= Original\n")
        defer { app.close() }
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        editor.insertSnippet(
            Snippet(text: "Chinese 中文😀\n"),
            replacing: NSRange(location: editor.string.utf16.count, length: 0),
        )
        app.workspace.save()
        #expect(try String(contentsOf: app.document, encoding: .utf8).contains("Chinese 中文😀"))
        let renamed = app.root.appendingPathComponent("saved as.typ")
        try app.workspace.save(to: renamed)
        #expect(app.workspace.fileURL == renamed)
        #expect(app.workspace.savedText == editor.string)
        try await app.ready()
        try Data("= External change\n".utf8).write(to: renamed)
        editor.insertSnippet(
            Snippet(text: "Local unsaved\n"),
            replacing: NSRange(location: editor.string.utf16.count, length: 0),
        )
        app.workspace.save()
        #expect(app.workspace.saveStatus == "Save Needs Attention")
        #expect(try String(contentsOf: renamed, encoding: .utf8) == "= External change\n")
        #expect(app.workspace.saveRecovery())
        let recovered = Workspace(stateDirectory: app.workspace.stateDirectory)
        #expect(recovered.text.contains("Local unsaved"))
        #expect(recovered.fileURL == renamed)
        recovered.shutdown()
        app.workspace.reload()
        #expect(app.workspace.text == "= External change\n")
        let archived = try FileManager.default.contentsOfDirectory(
            at: app.workspace.stateDirectory,
            includingPropertiesForKeys: nil,
        ).filter { $0.lastPathComponent.hasPrefix("Before-reload-") }
        #expect(archived.count == 1)
        #expect(try String(contentsOf: archived[0], encoding: .utf8).contains("Local unsaved"))
        #expect(app.workspace.prepareToClose())
        let clean = Workspace(stateDirectory: app.workspace.stateDirectory)
        #expect(clean.text == "= External change\n")
        clean.shutdown()
    }

    @Test func draftSwitchKeepsRecoverableCopyAndMissingFilesDoNotReplaceEditor() async throws {
        let app = try WritingFixture(text: "= Existing file\n")
        defer { app.close() }
        try await app.ready()
        app.workspace.newDocument()
        #expect(app.workspace.discoveryMode == .templates)
        try await app.workspace.library.create(builtIn: .blank)
        try await app.ready()
        let managedURL = try #require(app.workspace.fileURL)
        #expect(app.workspace.title == L10n.text("Untitled"))
        let editor = try #require(app.workspace.editor)
        editor.insertSnippet(
            Snippet(text: "Unsaved draft sentinel"),
            replacing: NSRange(location: editor.string.utf16.count, length: 0),
        )
        let draft = app.workspace.text
        #expect(app.workspace.open(app.document))
        try await app.ready()
        #expect(try String(contentsOf: managedURL, encoding: .utf8) == draft)
        #expect(!app.workspace.open(app.root.appendingPathComponent("missing.typ")))
        #expect(app.workspace.text == "= Existing file\n")
        #expect(app.workspace.message != nil)
        app.workspace.newDocument()
        #expect(app.workspace.discoveryMode == .templates)
        try await app.workspace.library.create(builtIn: .blank)
        try await app.ready()
        app.workspace.edited("Recovered after interruption")
        try await app.wait { app.workspace.saveStatus == "Saved" }
        let recovered = Workspace(stateDirectory: app.workspace.stateDirectory)
        #expect(recovered.text == "Recovered after interruption")
        recovered.shutdown()
    }

    @Test func outlineDiagnosticsNavigationAndInvalidExport() async throws {
        let app = try WritingFixture(text: "= Main heading\n\n== Child heading\n\nBody\n")
        defer { app.close() }
        try await app.ready()
        try await app.wait { app.workspace.outline.count == 2 }
        try app.workspace.execute(#require(WritingCommand.all.first { $0.id == "outline" }))
        await app.layout()
        #expect(app.workspace.sidePanel == .outline)
        app.workspace.jump(to: app.workspace.outline[1].offset)
        #expect(app.workspace.position.line == 2)
        app.workspace.layout = .preview
        #expect(app.workspace.editor?.isEditable == false)
        app.workspace.jump(to: 0)
        #expect(app.workspace.layout == .split)
        let validPDF = app.root.appendingPathComponent("valid.pdf")
        try await app.workspace.exportPDF(to: validPDF)
        let validBytes = try Data(contentsOf: validPDF)
        let editor = try #require(app.workspace.editor)
        editor.insertSnippet(
            Snippet(text: "#unknown-function()"),
            replacing: NSRange(location: editor.string.utf16.count, length: 0),
        )
        try await app.wait { app.workspace.diagnostics.contains { $0.severity == 1 } }
        app.workspace.checksOpen = true
        await app.layout()
        let diagnostic = try #require(app.workspace.diagnostics.first { $0.severity == 1 })
        app.workspace.showDiagnostic(diagnostic)
        #expect(app.workspace.selection.location == diagnostic.position.offset(in: editor.string))
        await #expect(throws: (any Error).self) { try await app.workspace.exportPDF(to: validPDF) }
        #expect(try Data(contentsOf: validPDF) == validBytes)
        #expect(!app.workspace.exporting)
        editor.undoManager?.undo()
        #expect(!editor.string.contains("#unknown-function()"), "Undo must restore the last valid source")
        #expect(app.workspace.text == editor.string)
        try await app.wait { !app.workspace.diagnostics.contains { $0.severity == 1 } }
        app.workspace.revealPreview()
        #expect(app.workspace.layout == .split)
    }

    @Test func includedDocumentNavigationPreservesMainExport() async throws {
        let app = try WritingFixture(text: "= Book\n\n#include \"chapter.typ\"\n", startService: false)
        defer { app.close() }
        let chapter = app.root.appendingPathComponent("chapter.typ")
        try Data("= Chapter\n\nSaved chapter".utf8).write(to: chapter)
        app.workspace.startService()
        try await app.ready()
        let diagnostic = DiagnosticItem(
            message: "Navigate to chapter",
            severity: 2,
            position: TextPosition(line: 2, character: 0),
            url: chapter,
        )
        app.workspace.showDiagnostic(diagnostic)
        #expect(app.workspace.mainFileURL == app.document)
        #expect(app.workspace.compilationURL == app.document)
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        editor.insertSnippet(
            Snippet(text: "Unsaved chapter"),
            replacing: (editor.string as NSString).range(of: "Saved chapter"),
        )
        let output = app.root.appendingPathComponent("book.pdf")
        try await app.workspace.exportPDF(to: output)
        let rendered = try #require(PDFDocument(url: output)?.string)
        #expect(rendered.contains("Book"))
        #expect(rendered.contains("Unsaved chapter"))
        #expect(app.workspace.open(app.document))
        #expect(app.workspace.mainFileURL == nil)
    }

    @Test func printingCompilesCurrentWritingAndRejectsInvalidSource() async throws {
        let app = try WritingFixture(text: "= Print flow\n")
        defer { app.close() }
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        editor.insertSnippet(
            Snippet(text: "\nLatest writing"),
            replacing: NSRange(location: editor.string.utf16.count, length: 0),
        )
        let operation = try await app.workspace.makePrintOperation()
        #expect(operation.jobTitle == app.workspace.title)
        #expect(operation.showsPrintPanel)
        #expect(operation.showsProgressPanel)
        let view = try #require(operation.view)
        let printedData = view.dataWithPDF(inside: view.bounds)
        let printed = try #require(PDFDocument(data: printedData))
        #expect(printed.string?.contains("Latest writing") == true)
        #expect(!app.workspace.exporting)
        editor.insertSnippet(
            Snippet(text: "#unknown-function()"),
            replacing: NSRange(location: 0, length: editor.string.utf16.count),
        )
        try await app.wait { app.workspace.diagnostics.contains { $0.severity == 1 } }
        await #expect(throws: (any Error).self) { try await app.workspace.makePrintOperation() }
        #expect(!app.workspace.exporting)
    }

    @Test func nativeMenusDispatchToTheSameWritingWorkspace() async throws {
        let app = try WritingFixture(text: "= Menu flow\n")
        defer { app.close() }
        try await app.ready()
        let delegate = AppDelegate(workspace: app.workspace)
        let previousMenu = NSApp.mainMenu
        let previousWindowsMenu = NSApp.windowsMenu
        let previousServicesMenu = NSApp.servicesMenu
        defer { NSApp.mainMenu = previousMenu
            NSApp.windowsMenu = previousWindowsMenu
            NSApp.servicesMenu = previousServicesMenu
        }
        delegate.installMenu()
        let menu = try #require(NSApp.mainMenu)
        #expect(menu.items.map(\.title) == [AppDistribution.current.applicationName] + [
            "Documents",
            "Edit",
            "View",
            "Window",
        ].map { L10n.text($0) })
        let entries = menu.items.flatMap { $0.submenu?.items ?? [] }
        let printItem = try #require(entries.first { $0.title == L10n.text("Print…") })
        #expect(printItem.keyEquivalent == "p")
        #expect(printItem.keyEquivalentModifierMask == .command)
        #expect(delegate.validateMenuItem(printItem))
        app.workspace.exporting = true
        #expect(!delegate.validateMenuItem(printItem))
        app.workspace.exporting = false
        #expect(NSApp.servicesMenu?.title == L10n.text("Services"))
        #expect(entries.contains { $0.title == L10n.text("Hide Others") && $0.keyEquivalentModifierMask == [
            .command,
            .option,
        ] })
        #expect(entries.contains { $0.title == L10n.text("Toggle Full Screen") && $0.keyEquivalentModifierMask == [
            .command,
            .control,
        ] })
        func choose(_ title: String) throws {
            let item = try #require(entries.first { $0.title == L10n.text(title) })
            let action = try #require(item.action)
            #expect(NSApp.sendAction(action, to: item.target, from: item))
        }
        try choose("Side-by-side Preview")
        #expect(app.workspace.layout == .split)
        try choose("Read the Preview")
        #expect(app.workspace.layout == .preview)
        try choose("Focus on Writing")
        #expect(app.workspace.layout == .writing)
        let originalFont = app.workspace.fontSize
        try choose("Increase Text Size")
        #expect(app.workspace.fontSize == originalFont + 1)
        try choose("Decrease Text Size")
        #expect(app.workspace.fontSize == originalFont)
        try choose("Discover Commands")
        #expect(app.workspace.paletteOpen)
        app.workspace.closePalette()
        let editor = try #require(app.workspace.editor)
        editor.insertSnippet(
            Snippet(text: "Saved by menu"),
            replacing: NSRange(location: editor.string.utf16.count, length: 0),
        )
        try choose("Save")
        #expect(try String(contentsOf: app.document, encoding: .utf8).contains("Saved by menu"))
        try choose("New Document")
        #expect(app.workspace.libraryOpen)
        #expect(app.workspace.discoveryMode == .templates)
        #expect(app.workspace.fileURL == app.document)
        try await app.workspace.library.create(builtIn: .blank)
        #expect(app.workspace.title == L10n.text("Untitled"))
        try await app.ready()
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    }

    @Test func nativeCommandRoutingAndPanelStates() async throws {
        let app = try WritingFixture(text: "= Routes\n", startService: false)
        defer { app.close() }
        let editor = try #require(app.workspace.editor)
        app.window.sendEvent(app.key(app.workspace.commandKey, code: 38, modifiers: .command))
        #expect(app.workspace.paletteOpen)
        await app.layout()
        app.window.sendEvent(app.key("i", code: 34))
        #expect(app.workspace.paletteGroup == "insert")
        await app.layout()
        app.window.sendEvent(app.key("\u{f701}", code: 125))
        #expect(app.workspace.selectedCommandIndex == 1)
        app.window.sendEvent(app.key("\u{f700}", code: 126))
        #expect(app.workspace.selectedCommandIndex == 0)
        app.window.sendEvent(app.key("\u{1b}", code: 53))
        #expect(app.workspace.paletteGroup == nil)
        app.window.sendEvent(app.key("/", code: 44))
        app.workspace.query = "no-command-will-match-this"
        await app.layout()
        #expect(app.workspace.filteredCommands.isEmpty)
        #expect(!app.workspace.handlePaletteKey(app.key("x", code: 7)))
        #expect(!app.workspace.handlePaletteKey(app.key("c", code: 8, modifiers: .command)))
        app.window.sendEvent(app.key("\u{1b}", code: 53))
        try app.workspace.selectCommand(#require(WritingCommand.all.first { $0.id == "table" }))
        await app.layout()
        #expect(app.workspace.activeCommand?.id == "table")
        app.window.sendEvent(app.key("\u{1b}", code: 53))
        #expect(app.workspace.activeCommand == nil)
        app.window.sendEvent(app.key("\u{1b}", code: 53))
        #expect(!app.workspace.paletteOpen)
        #expect(editor.isEditable)
        for id in ["split", "preview", "writing", "outline", "outline", "diagnostics", "diagnostics"] {
            try app.workspace.execute(#require(WritingCommand.all.first { $0.id == id }))
            await app.layout()
        }
        #expect(app.workspace.layout == .writing)
        #expect(app.workspace.sidePanel == nil)
        app.workspace.togglePalette()
        try app.workspace.selectCommand(#require(WritingCommand.all.first { $0.id == "bold" }))
        #expect(app.workspace.commandError != nil, "Insertion must report unavailable service without changing text")
        #expect(editor.string == "= Routes\n")
        _ = app.window.performKeyEquivalent(with: app.key("z", code: 6, modifiers: .command))
        let logs = try String(
            contentsOf: app.workspace.stateDirectory.appendingPathComponent("Logs/events.jsonl"),
            encoding: .utf8,
        )
        #expect(logs.contains("shortcut"))
        #expect(logs.contains("dispatch"))
    }
}

@MainActor
final class WritingFixture {
    let root: URL
    let document: URL
    let workspace: Workspace
    let window: WritingWindow
    let toolbar: WindowToolbar
    /// Window preferences such as the split ratio. Each fixture gets its own
    /// domain unless a test shares one to observe persistence.
    let defaults: UserDefaults
    private let ownedDefaults: String?
    /// Set by the one test that forces TextKit 1 on purpose.
    var allowsTextKit1 = false

    init(text: String, startService: Bool = true, linkedState: Bool = false, defaults: UserDefaults? = nil) throws {
        if let defaults {
            self.defaults = defaults
            ownedDefaults = nil
        } else {
            let suite = "LeftBlank.writing.test." + UUID().uuidString
            guard let owned = UserDefaults(suiteName: suite) else {
                preconditionFailure("Could not create test defaults")
            }
            self.defaults = owned
            ownedDefaults = suite
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        root = TestPaths.temporaryDirectory.appendingPathComponent("LeftBlank-writing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        document = root.appendingPathComponent("manuscript.typ")
        try Data(text.utf8).write(to: document)
        let state = root.appendingPathComponent("State")
        if linkedState {
            let storage = root.appendingPathComponent("Storage")
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: state, withDestinationURL: storage)
        } else {
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        }
        let snapshot = RecoverySnapshot(fileURL: document, text: text, savedText: text, selection: text.utf16.count)
        try JSONEncoder().encode(snapshot).write(to: state.appendingPathComponent("recovery.json"))
        workspace = Workspace(stateDirectory: state)
        window = WritingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1220, height: 820),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        window.workspace = workspace
        workspace.window = window
        toolbar = WindowToolbar(workspace: workspace)
        window.toolbar = toolbar.makeToolbar()
        window.contentView = NSHostingView(rootView: ContentView(workspace: workspace, defaults: self.defaults))
        window.contentView?.layoutSubtreeIfNeeded()
        if startService {
            workspace.startService()
        }
    }

    func layout() async {
        window.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(60))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func ready() async throws {
        try await wait { workspace.serviceReady && workspace.previewURL != nil }
        await layout()
        #expect(workspace.editor != nil)
    }

    func wait(sourceLocation: Testing.SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        if !condition() {
            let log = workspace.stateDirectory.appendingPathComponent("Logs/events.jsonl")
            let events = (try? String(contentsOf: log, encoding: .utf8)) ?? "No operation log"
            print("Native UI timeout diagnostics:\n" + events.suffix(12000))
        }
        try #require(
            condition(),
            "App feature did not reach its expected state before timeout. Status: \(workspace.serviceStatus), message: \(workspace.message ?? "none")",
            sourceLocation: sourceLocation,
        )
    }

    func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code,
        ) else {
            preconditionFailure("Could not create a test key event")
        }
        return event
    }

    func close() {
        if let editor = workspace.editor, !allowsTextKit1 {
            // A silent switch to TextKit 1 would disable the visual layer.
            #expect(editor.textLayoutManager != nil && !editor.switchedToTextKit1, "The editor fell back to TextKit 1")
        }
        workspace.shutdown()
        window.close()
        try? FileManager.default.removeItem(at: root)
        if let ownedDefaults {
            defaults.removePersistentDomain(forName: ownedDefaults)
        }
    }
}
