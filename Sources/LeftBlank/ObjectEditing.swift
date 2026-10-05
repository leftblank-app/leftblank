import AppKit
import LeftBlankCore

extension Workspace {
    func editObjectAtCursor() {
        guard let editor, editor.isEditable, !editor.hasMarkedText(), !documentTransitionInProgress,
              layout != .preview, !paletteOpen
        else {
            return
        }
        guard let object = StructuredObject.at(editor.selectedRange(), in: text) else {
            message = L10n.text("Place the cursor in a literal table or image. Complex objects use source editing.")
            return
        }
        dismissAssistance()
        message = nil
        objectEditSession = ObjectEditSession(source: text, url: documentURL, revision: revision, object: object)
    }

    func applyObjectEdit(_ object: StructuredObject, session: ObjectEditSession) {
        guard session.id == objectEditSession?.id, session.url == documentURL, session.revision == revision,
              session.source == text, object.original == session.object.original, object.range == session.object.range,
              let editor, editor.string == text, !editor.hasMarkedText(), editor.isEditable,
              !documentTransitionInProgress, layout != .preview, !paletteOpen
        else {
            message = L10n.text(ObjectEditError.changed.localizedDescription)
            return
        }
        do {
            let edit = try object.replacement(in: text)
            objectEditSession = nil
            guard edit.text != object.original else {
                return
            }
            editor.insertSnippet(Snippet(text: edit.text), replacing: edit.range)
            editor.undoManager?.setActionName(L10n.text("Edit Object"))
        } catch { message = L10n.text(error.localizedDescription) }
    }
}
