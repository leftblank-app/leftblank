import LeftBlankCore
import SwiftUI
import UIKit

extension TabletWorkspace {
    func editObjectAtCursor() {
        guard !busy, requireWriting(), let editor, editor.markedTextRange == nil,
              layout != .preview, let sourceURL
        else {
            return
        }
        guard let object = StructuredObject.at(editor.selectedRange, in: text) else {
            message = L10n.text("Place the cursor in a literal table or image. Complex objects use source editing.")
            return
        }
        message = nil
        objectEditSession = ObjectEditSession(source: text, url: sourceURL, revision: version, object: object)
        panel = .objectEditor
    }

    func applyObjectEdit(_ object: StructuredObject, session: ObjectEditSession) {
        guard session.id == objectEditSession?.id, session.url == sourceURL, session.revision == version,
              session.source == text, object.original == session.object.original, object.range == session.object.range,
              let editor, editor.text == text, editor.markedTextRange == nil,
              !busy, layout != .preview, requireWriting()
        else {
            message = L10n.text(ObjectEditError.changed.localizedDescription)
            return
        }
        do {
            let edit = try object.replacement(in: text)
            objectEditSession = nil
            panel = nil
            guard edit.text != object.original else {
                return
            }
            editor.undoManager?.beginUndoGrouping()
            apply(edit)
            editor.undoManager?.endUndoGrouping()
            editor.undoManager?.setActionName(L10n.text("Edit Object"))
            editor.becomeFirstResponder()
        } catch { message = L10n.text(error.localizedDescription) }
    }
}

struct TabletObjectEditor: View {
    @ObservedObject var workspace: TabletWorkspace
    var body: some View {
        if let session = workspace.objectEditSession {
            ObjectEditorForm(
                object: session.object,
                resourceRoot: workspace.resourceRoot,
                sourceURL: session.url,
                failure: workspace.message,
            ) {
                workspace.applyObjectEdit($0, session: session)
            } cancel: {
                workspace.objectEditSession = nil
                workspace.panel = nil
            }
        }
    }
}
