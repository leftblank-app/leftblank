import LeftBlankCore
import SwiftUI
import UniformTypeIdentifiers

/// File-picker URLs are copied into the project before they enter the source.
enum TabletResourceSelection: Equatable {
    case existing(DocumentResource)
    case file(URL)

    var name: String {
        switch self {
        case let .existing(resource): resource.relativePath
        case let .file(url): url.lastPathComponent
        }
    }
}

struct TabletResourcePicker: View {
    @ObservedObject var workspace: TabletWorkspace
    let kind: DocumentResourceKind
    @Binding var selection: TabletResourceSelection?
    @State private var resources: [DocumentResource] = []
    @State private var importing = false
    @State private var importerSource: URL?
    @State private var loading = false
    @State private var error: String?

    private var contentTypes: [UTType] {
        kind == .image ? [.image, .pdf] : kind.extensions.compactMap { UTType(filenameExtension: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selection {
                Label {
                    Text(selection.name)
                } icon: {
                    TabletIcon(name: "file", size: 16)
                }
                .font(.subheadline).lineLimit(2)
            }
            Button(L10n.text("Import into Document")) {
                importerSource = workspace.sourceURL
                importing = true
            }
            .accessibilityIdentifier("resource-import")
            if loading {
                ProgressView()
            }
            if !resources.isEmpty {
                Menu {
                    ForEach(resources) { resource in
                        Button(resource.relativePath) { selection = .existing(resource) }
                    }
                } label: {
                    Label {
                        Text(L10n.text("Document Resources"))
                    } icon: {
                        TabletIcon.menuImage("folder-simple", title: L10n.text("Document Resources"))
                    }
                }
                .accessibilityIdentifier("resource-existing")
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .task(id: workspace.sourceURL) {
            selection = nil
            guard let source = workspace.sourceURL, let root = workspace.resourceRoot else {
                return
            }
            loading = true
            defer { loading = false }
            do {
                let result = try await DocumentResourceStore().list(kind: kind, in: root, relativeTo: source)
                guard !Task.isCancelled, workspace.sourceURL == source else {
                    return
                }
                resources = result
                error = nil
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: contentTypes) { result in
            guard workspace.sourceURL == importerSource else {
                return
            }
            switch result {
            case let .success(url): selection = .file(url)
            case let .failure(error): self.error = error.localizedDescription
            }
        }
    }
}

extension TabletWorkspace {
    func insertResourceCommand(
        _ command: WritingCommand,
        values: [String: String],
        resource: TabletResourceSelection,
    ) async throws {
        guard let kind = command.fields.first?.resourceKind else {
            return
        }
        try await insertResourceReferences(command, values: values, kind: kind, resource: resource, inputs: [])
    }

    /// Paste and drop use the same project-owned copies and undo path as the palette.
    func importAndInsertResources(
        _ inputs: [DocumentResourceInput],
        kind: DocumentResourceKind,
        replacing range: NSRange,
    ) async throws {
        guard !inputs.isEmpty, selection == range else {
            return
        }
        let id = switch kind {
        case .image: "image"
        case .bibliography: "bibliography"
        case .document: "include"
        case .module: "import"
        }
        guard let command = WritingCommand.all.first(where: { $0.id == id }) else {
            return
        }
        try await insertResourceReferences(command, values: [:], kind: kind, resource: nil, inputs: inputs)
    }

    private func insertResourceReferences(
        _ command: WritingCommand,
        values: [String: String],
        kind: DocumentResourceKind,
        resource: TabletResourceSelection?,
        inputs: [DocumentResourceInput],
    ) async throws {
        guard requireWriting(), !busy, let source = sourceURL, let root = resourceRoot,
              let editor, editor.isEditable, editor.markedTextRange == nil,
              editor.text == text, editor.selectedRange == selection,
              selection.location >= 0, selection.length >= 0,
              selection.location <= text.utf16.count,
              selection.length <= text.utf16.count - selection.location
        else {
            return
        }
        let session = generation, revision = version, range = selection, presentedPanel = panel
        func stillCurrent() -> Bool {
            !Task.isCancelled && subscription.canWrite && !busy && generation == session && version == revision &&
                sourceURL == source && panel == presentedPanel && self.editor === editor && editor.isEditable &&
                editor.text == text &&
                editor.markedTextRange == nil && selection == range && editor.selectedRange == range
        }
        let store = DocumentResourceStore()
        var imported: [DocumentResource] = []
        do {
            let resources: [DocumentResource]
            switch resource {
            case let .existing(selected):
                let available = try await store.list(kind: kind, in: root, relativeTo: source)
                guard available.contains(selected) else {
                    throw DocumentResourceError.invalidLocation
                }
                resources = [selected]
            case let .file(url):
                imported = try await store.importResources([.file(url)], kind: kind, in: root, relativeTo: source)
                resources = imported
            case nil:
                imported = try await store.importResources(inputs, kind: kind, in: root, relativeTo: source)
                resources = imported
            }
            guard stillCurrent() else {
                try await store.discardImport(imported)
                return
            }
            let snippets = try resources.map { resource in
                var resolved = values
                resolved["path"] = resource.relativePath
                return try TypstInsertion.make(command.id, values: resolved)
            }
            let snippet = snippets
                .count == 1 ? snippets[0] : Snippet(text: snippets.map(\.text).joined(separator: "\n\n"))
            let plan = InsertionPlan(command: command, snippet: snippet, text: text, selection: range)
            apply(TextReplacement(range: plan.range, text: plan.snippet.text))
            if let tabletEditor = editor as? TabletTextView {
                tabletEditor.setSnippet(plan.snippet, at: plan.range.location)
            } else if let placeholder = plan.snippet.selections.first {
                let selected = NSRange(location: plan.range.location + placeholder.location, length: placeholder.length)
                editor.selectedRange = selected
                selection = selected
            }
            panel = nil
            editor.becomeFirstResponder()
        } catch {
            try? await store.discardImport(imported)
            throw error
        }
    }
}
