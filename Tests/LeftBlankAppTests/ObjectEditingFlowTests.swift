import AppKit
@testable import LeftBlankApp
import LeftBlankCore
import PDFKit
import Testing

extension WritingFlowTests {
    @Test func editedTableAndImageCompileWithTheRealEngine() async throws {
        let source = "#table(columns: 2, [A], [B])\n#image(\"mark.svg\", width: 20%)"
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        try Data(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\"><rect width=\"20\" height=\"20\"/></svg>"
                .utf8,
        )
        .write(to: app.root.appendingPathComponent("mark.svg"))
        app.workspace.startService()
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        app.workspace.editObjectAtCursor()
        let table = try #require(app.workspace.objectEditSession)
        var draft = table.object
        try draft.pasteTable("Name\tValue\nEdited table\t42")
        draft.hasHeader = true
        app.workspace.applyObjectEdit(draft, session: table)
        editor.setSelectedRange(NSRange(
            location: (editor.string as NSString).range(of: "#image").location + 3,
            length: 0,
        ))
        app.workspace.editObjectAtCursor()
        let image = try #require(app.workspace.objectEditSession)
        draft = image.object
        draft.width = "40%"
        draft.caption = "Edited image"
        draft.alignment = "center"
        app.workspace.applyObjectEdit(draft, session: image)
        let output = app.root.appendingPathComponent("objects.pdf")
        try await app.workspace.exportPDF(to: output)
        let rendered = try #require(PDFDocument(url: output)?.string)
        #expect(rendered.contains("Edited table"))
        #expect(rendered.contains("Edited image"))
        editor.undoManager?.undo()
        #expect(editor.string.contains("#image(\"mark.svg\", width: 20%)"))
        editor.undoManager?.undo()
        #expect(editor.string == source)
        #expect(app.workspace.text == source)
    }

    @Test func objectEditingChangesOneObjectAndUndoRestoresNativeModel() throws {
        let source = "中文😀\n#table(columns: 2, [A], [B])\nKeep this."
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        let editor = try #require(app.workspace.editor)
        editor.setSelectedRange(NSRange(location: 12, length: 0))
        app.workspace.editObjectAtCursor()
        let session = try #require(app.workspace.objectEditSession)
        var draft = session.object
        draft.rows[0][0] = "New"
        draft.rows.append(["C", "D"])
        app.workspace.applyObjectEdit(draft, session: session)
        #expect(editor.string == app.workspace.text)
        #expect(editor.string.hasSuffix("\nKeep this."))
        #expect(editor.string.contains("[New], [B]"))
        #expect(app.workspace.objectEditSession == nil)
        editor.undoManager?.undo()
        #expect(editor.string == source)
        #expect(app.workspace.text == source)
        editor.undoManager?.redo()
        #expect(app.workspace.text.contains("[New], [B]"))
        #expect(app.workspace.text == editor.string)
    }

    @Test func objectEditingRejectsStaleDraftAndMarkedText() throws {
        let source = "#image(\"a.png\", width: 80%)"
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        let editor = try #require(app.workspace.editor)
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        app.workspace.editObjectAtCursor()
        let session = try #require(app.workspace.objectEditSession)
        var draft = session.object
        draft.width = "40%"
        editor.insertSnippet(Snippet(text: "New "), replacing: NSRange(location: 0, length: 0))
        let current = editor.string
        app.workspace.applyObjectEdit(draft, session: session)
        #expect(editor.string == current)
        #expect(app.workspace.text == current)
        app.workspace.objectEditSession = nil
        editor.setMarkedText(
            "中文",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: editor.selectedRange(),
        )
        app.workspace.editObjectAtCursor()
        #expect(app.workspace.objectEditSession == nil)
        editor.unmarkText()
    }

    @Test func unchangedObjectClosesWithoutCreatingAnUndoStep() throws {
        let source = "#image(\"a.png\", width: 80%)"
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        let editor = try #require(app.workspace.editor)
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        app.workspace.editObjectAtCursor()
        let session = try #require(app.workspace.objectEditSession)
        app.workspace.applyObjectEdit(session.object, session: session)
        #expect(editor.string == source)
        #expect(editor.undoManager?.canUndo != true)
        #expect(app.workspace.objectEditSession == nil)
    }
}
