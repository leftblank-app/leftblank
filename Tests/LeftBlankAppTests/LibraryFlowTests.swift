import AppKit
@testable import LeftBlankApp
import LeftBlankCore
import PDFKit
import SwiftUI
import Testing

extension WritingFlowTests {
    @Test func cloudDefaultsOnPreservesOptOutAndResumesWithoutReimporting() async throws {
        let app = try WritingFixture(text: "Local draft", startService: false)
        defer { app.close() }
        let cloud = app.root.appendingPathComponent("Cloud")
        let library = LibraryController(workspace: app.workspace, cloudResolver: { cloud })
        let original = try await library.store.create(title: "Original", text: "Local original")
        await library.start()
        #expect(library.cloudEnabled)
        #expect(library.documents.contains { $0.id == original.id })
        let cloudSource = try #require(library.documents.first { $0.id == original.id }?.sourceURL)
        try Data("Remote edit".utf8).write(to: cloudSource)
        let resumed = LibraryController(workspace: app.workspace, cloudResolver: { cloud })
        await resumed.start()
        #expect(resumed.cloudEnabled)
        #expect(try await resumed.store.read(original.id).text == "Remote edit")
        try await resumed.setCloudEnabled(false)
        let disabled = LibraryController(
            workspace: app.workspace,
            cloudResolver: { throw LibraryError.cloudUnavailable },
        )
        await disabled.start()
        #expect(!disabled.cloudEnabled)
        #expect(disabled.syncMessage.isEmpty)
    }

    @Test func turningOffUnavailableDefaultSyncPersistsOptOut() async throws {
        let app = try WritingFixture(text: "Local draft", startService: false)
        defer { app.close() }
        let library = LibraryController(
            workspace: app.workspace,
            cloudResolver: { throw LibraryError.cloudUnavailable },
        )
        await library.start()
        try await library.setCloudEnabled(false)
        let cloud = app.root.appendingPathComponent("Cloud")
        let restarted = LibraryController(workspace: app.workspace, cloudResolver: { cloud })
        await restarted.start()
        #expect(!restarted.cloudEnabled)
        #expect(restarted.syncMessage.isEmpty)
    }

    @Test func unavailableDefaultSyncKeepsLocalWritingAndRetriesNextLaunch() async throws {
        let app = try WritingFixture(text: "Local draft", startService: false)
        defer { app.close() }
        let unavailable = LibraryController(
            workspace: app.workspace,
            cloudResolver: { throw LibraryError.cloudAccountUnavailable },
        )
        let original = try await unavailable.store.create(title: "Original", text: "Offline writing")
        await unavailable.start()
        #expect(!unavailable.cloudEnabled)
        #expect(!unavailable.syncMessage.isEmpty)
        #expect(try await unavailable.store.read(original.id).text == "Offline writing")
        let cloud = app.root.appendingPathComponent("Cloud")
        let retry = LibraryController(workspace: app.workspace, cloudResolver: { cloud })
        await retry.start()
        #expect(retry.cloudEnabled)
        #expect(try await retry.store.read(original.id).text == "Offline writing")
    }

    @Test func emptyTrashConfirmationCancelsThenDeletesWithoutTouchingOpenWriting() async throws {
        let app = try WritingFixture(text: "= Current writing\n", startService: false)
        defer { app.close() }
        let library = app.workspace.library
        let old = try await library.store.create(title: "Private title", text: "Private writing")
        _ = try await library.store.trash(old.id)
        await library.refresh()
        let original = app.workspace.text
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        library.confirmEmptyTrash()
        try await app.wait { app.window.attachedSheet != nil && !library.busy }
        var sheet = try #require(app.window.attachedSheet?.contentView)
        let cancel = try #require(buttons(sheet).first { $0.title == L10n.text("Cancel") })
        cancel.performClick(nil)
        try await app.wait { app.window.attachedSheet == nil }
        #expect(try await library.store.trashSnapshot().count == 1)
        library.confirmEmptyTrash()
        try await app.wait { app.window.attachedSheet != nil && !library.busy }
        sheet = try #require(app.window.attachedSheet?.contentView)
        let confirm = try #require(buttons(sheet).first { $0.title == L10n.text("Empty Trash") })
        #expect(confirm.hasDestructiveAction)
        confirm.performClick(nil)
        try await app.wait { app.window.attachedSheet == nil && !library.busy && library.documents.isEmpty }
        #expect(!FileManager.default.fileExists(atPath: old.folderURL.path))
        #expect(app.workspace.text == original)
        #expect(app.workspace.editor?.string == original)
        #expect(!app.workspace.isLibraryHome)
        let log = try String(
            contentsOf: app.workspace.stateDirectory.appendingPathComponent("Logs/events.jsonl"),
            encoding: .utf8,
        )
        #expect(log.contains("library.emptyTrash"))
        #expect(!log.contains("Private title"))
        #expect(!log.contains("Private writing"))
    }

    @Test func trashActiveDocumentSelectsRemainingWritingAndEmptyLibrarySurvivesRestart() async throws {
        let app = try WritingFixture(text: "= External\n", startService: false)
        defer { app.close() }
        let library = app.workspace.library
        await library.start()
        try await library.create(title: "Untitled", text: "= First\n")
        let first = try #require(app.workspace.managedDocumentID)
        try await library.create(title: "Untitled", text: "= Second\n")
        let second = try #require(app.workspace.managedDocumentID)
        try await library.moveToTrash(second)
        #expect(try await library.store.list().map(\.id) == [first])
        #expect(library.documents.count == 2, "Trashing must not create a replacement document")
        #expect(app.workspace.managedDocumentID == first)
        #expect(app.workspace.libraryOpen)
        app.workspace.libraryOpen = false

        let editor = try #require(app.workspace.editor)
        editor.insertSnippet(
            Snippet(text: "Preserve this before trashing.\n"),
            replacing: NSRange(location: editor.string.utf16.count, length: 0),
        )
        let preserved = editor.string
        try await library.moveToTrash(first)
        #expect(try await library.store.list().isEmpty)
        #expect(library.documents.count == 2)
        #expect(app.workspace.isLibraryHome)
        #expect(app.workspace.fileURL == nil)
        #expect(app.workspace.text.isEmpty)
        #expect(!app.workspace.serviceReady)
        #expect(app.workspace.previewURL == nil)
        #expect(try await library.store.read(first).text == preserved)
        app.workspace.openLibrary()
        app.workspace.save()
        #expect(!app.workspace.libraryOpen, "An empty library is already the main view")
        #expect(app.workspace.prepareToClose())
        library.stop()

        let recovered = Workspace(stateDirectory: app.workspace.stateDirectory)
        defer { recovered.shutdown() }
        await recovered.library.start()
        #expect(recovered.isLibraryHome)
        #expect(try await recovered.library.store.list().isEmpty)
        #expect(recovered.library.documents.count == 2)
        await app.layout()
        #expect(app.workspace.window === app.window, "Import dialogs must retain a parent without an editor")
        try await library.restore(first)
        try await library.open(first)
        await app.layout()
        #expect(!app.workspace.isLibraryHome)
        #expect(app.workspace.managedDocumentID == first)
        #expect(app.workspace.editor?.string == preserved)
        #expect(app.workspace.editor?.isEditable == true)
        let log = try String(
            contentsOf: app.workspace.stateDirectory.appendingPathComponent("Logs/events.jsonl"),
            encoding: .utf8,
        )
        #expect(log.contains("library.trash"))
        #expect(log.contains("library.restore"))
        #expect(!log.contains("Preserve this before trashing"))
    }

    @Test func titleClickRenamesAndDoubleClickOpensLibraryWithoutChangingWriting() async throws {
        let app = try WritingFixture(text: "= Keep the manuscript\n", startService: false)
        defer { app.close() }
        try await app.workspace.library.create(title: "Notebook", text: "= Keep the manuscript\n")
        await app.layout()
        func fields(_ view: NSView) -> [DocumentTitleField] {
            (view as? DocumentTitleField).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        let field = try #require(app.window.toolbar?.items.compactMap(\.view).flatMap(fields).first)
        let editor = try #require(app.workspace.editor)
        editor.insertSnippet(
            Snippet(text: "Unsaved thought 👋\n"),
            replacing: NSRange(location: editor.string.utf16.count, length: 0),
        )
        let text = editor.string, selection = editor.selectedRange(), source = app.workspace.fileURL
        let id = try #require(app.workspace.managedDocumentID)
        func click(_ count: Int) throws {
            try field.mouseDown(with: #require(NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: app.window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: count,
                pressure: 1,
            )))
        }
        try click(1)
        try await app.wait { field.renaming }
        let input = try #require(field.currentEditor() as? NSTextView)
        input.insertText("Field notes 中文", replacementRange: NSRange(location: 0, length: input.string.utf16.count))
        app.window.sendEvent(app.key("\r", code: 36))
        try await app.wait { app.workspace.title == "Field notes 中文" && !app.workspace.library.busy }
        #expect(!field.renaming)
        #expect(editor.string == text)
        #expect(editor.selectedRange() == selection)
        #expect(app.workspace.fileURL == source)
        #expect(try await app.workspace.library.store.read(id).document.title == "Field notes 中文")

        try click(1)
        try await app.wait { field.renaming }
        let cancelled = try #require(field.currentEditor() as? NSTextView)
        cancelled.insertText(
            "Discard this title",
            replacementRange: NSRange(location: 0, length: cancelled.string.utf16.count),
        )
        app.workspace.sidePanel = .outline
        app.window.sendEvent(app.key("\u{1b}", code: 53))
        #expect(!field.renaming)
        #expect(field.stringValue == "Field notes 中文")
        #expect(app.workspace.sidePanel == .outline)

        try click(1)
        try click(2)
        #expect(app.workspace.libraryOpen)
        // Let the cancelled single-click deadline pass; it must not steal focus.
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.05))
        #expect(!field.renaming)
        #expect(app.workspace.title == "Field notes 中文")
        #expect(editor.string == text)
    }

    @Test func libraryCreateRenameSearchTrashRestoreAndExportPreserveWriting() async throws {
        let app = try WritingFixture(text: "= External\n", startService: false)
        defer { app.close() }
        let library = app.workspace.library
        await library.start()
        try await library.create(title: "Notebook", text: "= Notebook\n\nAn unusual narwhal.\n")
        let id = try #require(app.workspace.managedDocumentID)
        let source = try #require(app.workspace.fileURL)
        let editor = try #require(app.workspace.editor)
        editor.insertSnippet(
            Snippet(text: "One more thought.\n"),
            replacing: NSRange(location: editor.string.utf16.count, length: 0),
        )
        try await library.rename(id, title: "Field notes")
        #expect(app.workspace.title == "Field notes")
        #expect(app.workspace.fileURL == source)
        app.workspace.save()
        #expect(try await library.store.list(query: "narwhal").map(\.id) == [id])
        let export = app.root.appendingPathComponent("Exported")
        try await library.exportProject(id, to: export)
        #expect(try String(contentsOf: export.appendingPathComponent("main.typ"), encoding: .utf8)
            .contains("One more thought"))
        try await library.moveToTrash(id)
        #expect(app.workspace.managedDocumentID != id)
        #expect(library.documents.first { $0.id == id }?.trashedAt != nil)
        await #expect(throws: (any Error).self) { try await library.open(id) }
        try await library.restore(id)
        try await library.open(id)
        #expect(editor.string.contains("One more thought"))
        #expect(library.documents.first { $0.id == id }?.trashedAt == nil)
        let view = NSHostingView(rootView: LibraryBrowser(workspace: app.workspace, library: library))
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width >= 600)
    }

    @Test func liveRemoteMergePreservesFocusSelectionAndUndoAndRejectsConflicts() async throws {
        let base = "= Shared\n\nFirst paragraph\n\nSecond paragraph\n"
        let app = try WritingFixture(text: base, startService: false)
        defer { app.close() }
        try await app.workspace.library.create(title: "Shared", text: base)
        // Explicitly drive delivery so no timer can race the scenario.
        app.workspace.library.stop()
        let editor = try #require(app.workspace.editor)
        editor.insertSnippet(Snippet(text: "My second"), replacing: (editor.string as NSString).range(of: "Second"))
        let local = editor.string
        let remote = base.replacingOccurrences(of: "First", with: "Their first")
        try Data(remote.utf8).write(to: #require(app.workspace.fileURL), options: .atomic)
        let search = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        app.window.contentView?.addSubview(search)
        app.window.makeFirstResponder(search)
        let responder = app.window.firstResponder
        editor.setSelectedRange(NSRange(location: local.utf16.count, length: 0))
        await app.workspace.refreshFromLibrary()
        #expect(editor.string.contains("Their first"))
        #expect(editor.string.contains("My second"))
        #expect(editor.selectedRange().location == editor.string.utf16.count)
        #expect(app.window.firstResponder === responder)
        #expect(app.workspace.savedText == remote)
        editor.undoManager?.undo()
        #expect(editor.string == local)
        app.workspace.save()
        let saved = editor.string
        editor.insertSnippet(
            Snippet(text: "Local replacement"),
            replacing: (editor.string as NSString).range(of: "First"),
        )
        let conflict = saved.replacingOccurrences(of: "First", with: "Remote replacement")
        let url = try #require(app.workspace.fileURL)
        try Data(conflict.utf8).write(to: url, options: .atomic)
        await app.workspace.refreshFromLibrary()
        #expect(editor.string.contains("Local replacement"))
        #expect(app.workspace.message != nil)
        app.workspace.save()
        #expect(app.workspace.saveStatus == "Save Needs Attention")
        #expect(try String(contentsOf: url, encoding: .utf8) == conflict)
        let recovered = Workspace(stateDirectory: app.workspace.stateDirectory)
        #expect(recovered.text == editor.string)
        recovered.shutdown()
    }

    @Test func codeNotesTemplateCompilesWithBundledPackages() async throws {
        let app = try WritingFixture(text: "", startService: false)
        defer { app.close() }
        try await app.workspace.library.create(template: .codeNotes)
        try await app.ready()
        let output = app.root.appendingPathComponent("code-notes.pdf")
        try await app.workspace.exportPDF(to: output)
        let text = try #require(PDFDocument(url: output)?.string)
        #expect(text.contains("total"))
        #expect(app.workspace.text.contains("@preview/codly:1.3.0"))
        #expect(!app.workspace.diagnostics.contains { $0.severity == 1 })
        let cache = app.workspace.stateDirectory.appendingPathComponent("PackageCache/preview/codly/1.3.0/typst.toml")
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func writingPreferencesPersistWithoutReplacingTheEditor() async throws {
        let app = try WritingFixture(text: "= Keep me\n", startService: false)
        defer { app.close() }
        let suite = "LeftBlank.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let oldLanguage = L10n.language
        defer { defaults.removePersistentDomain(forName: suite)
            L10n.setLanguage(oldLanguage)
        }
        let settings = WorkspaceSettings(workspace: app.workspace, defaults: defaults)
        defer { settings.stop() }
        let editor = try #require(app.workspace.editor)
        app.workspace.fontSize = 20
        app.workspace.previewDark = true
        app.workspace.commandKey = "k"
        app.workspace.documentTemplate = .codeNotes
        try await app.wait { settings.preferences.values.documentTemplate == "codeNotes" }
        #expect(settings.preferences.values.fontSize == 20)
        #expect(settings.preferences.values.previewDark)
        #expect(settings.preferences.values.commandKey == "k")
        #expect(app.workspace.editor === editor)
        #expect(editor.string == "= Keep me\n")
        let saved = LibraryPreferences(defaults: defaults)
        #expect(saved.values == settings.preferences.values)
        let view = NSHostingView(rootView: WritingSettingsView(
            workspace: app.workspace,
            library: app.workspace.library,
        ))
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize == WritingSettingsView.windowSize)
        await #expect(throws: (any Error).self) { try await app.workspace.library.setCloudEnabled(true) }
        #expect(!app.workspace.library.cloudEnabled)
        #expect(app.workspace.editor?.isEditable == true)
    }
}
