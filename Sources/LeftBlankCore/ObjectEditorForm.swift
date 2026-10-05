import Foundation
import SwiftUI

public struct ObjectEditSession: Identifiable {
    public let id = UUID()
    public let source: String
    public let url: URL
    public let revision: Int
    public let object: StructuredObject
    public init(source: String, url: URL, revision: Int, object: StructuredObject) {
        self.source = source
        self.url = url
        self.revision = revision
        self.object = object
    }
}

/// Both platforms use the same draft form and validation. Apply commits one source edit.
public struct ObjectEditorForm: View {
    @State private var object: StructuredObject
    @State private var pasted = ""
    @State private var error: String?
    @State private var resources: [DocumentResource] = []
    private let resourceRoot: URL?
    private let sourceURL: URL?
    private let failure: String?
    private let apply: (StructuredObject) -> Void
    private let cancel: () -> Void
    public init(
        object: StructuredObject,
        resourceRoot: URL? = nil,
        sourceURL: URL? = nil,
        failure: String? = nil,
        apply: @escaping (StructuredObject) -> Void,
        cancel: @escaping () -> Void,
    ) {
        self.resourceRoot = resourceRoot
        self.sourceURL = sourceURL
        self.failure = failure
        _object = State(initialValue: object)
        self.apply = apply
        self.cancel = cancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text(object.kind == .table ? "Edit Table" : "Edit Image")).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if object.kind == .table {
                        table
                    } else {
                        image
                    }
                    Picker(L10n.text("Alignment"), selection: $object.alignment) {
                        Text(L10n.text("Default")).tag("")
                        Text(L10n.text("Left")).tag("left")
                        Text(L10n.text("Center")).tag("center")
                        Text(L10n.text("Right")).tag("right")
                    }.pickerStyle(.segmented)
                    Text(L10n.text("Complex objects stay in source editing. Apply creates one undo step."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = error ?? failure {
                Text(L10n.text(error)).foregroundStyle(.red).font(.caption)
            }
            HStack {
                Button(L10n.text("Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("Apply")) {
                    do {
                        // Check the edited draft before invoking a platform mutation.
                        let padding = String(repeating: " ", count: object.range.location)
                        _ = try object.replacement(in: padding + object.original)
                        apply(object)
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("object-apply")
            }
        }.task {
            guard object.kind == .image, let resourceRoot, let sourceURL else {
                return
            }
            do { resources = try await DocumentResourceStore().list(
                kind: .image,
                in: resourceRoot,
                relativeTo: sourceURL,
            ) } catch { self.error = error.localizedDescription }
        }.padding(20).frame(minWidth: 360, idealWidth: 640, maxWidth: 760, minHeight: 340, idealHeight: 520)
    }

    private var image: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("Image path", text: $object.path).accessibilityIdentifier("object-image-path")
            if !resources.isEmpty {
                Menu(L10n.text("Document Resources")) {
                    ForEach(resources) { resource in
                        Button(resource.relativePath) { object.path = resource.relativePath }
                    }
                }.accessibilityIdentifier("object-image-resource")
            }
            field("Width", text: $object.width).accessibilityIdentifier("object-image-width")
            Toggle(L10n.text("Include Caption"), isOn: Binding(
                get: { object.caption != nil },
                set: { object.caption = $0 ? object.caption ?? "" : nil },
            ))
            if object.caption != nil {
                field("Caption", text: Binding(get: { object.caption ?? "" }, set: { object.caption = $0 }))
            }
        }
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(L10n.text("First row is a header"), isOn: $object.hasHeader)
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ForEach(0 ..< (object.rows.first?.count ?? 0), id: \.self) { column in
                            Button { for row in object.rows.indices {
                                object.rows[row].remove(at: column)
                            } } label: {
                                Label(L10n.format("Column %d", column + 1), systemImage: "minus.circle")
                            }.frame(width: 130).disabled(object.rows.first?.count == 1)
                        }
                    }
                    ForEach(object.rows.indices, id: \.self) { row in
                        HStack {
                            ForEach(object.rows[row].indices, id: \.self) { column in
                                TextField("", text: Binding(get: {
                                    guard object.rows.indices.contains(row),
                                          object.rows[row].indices.contains(column)
                                    else {
                                        return ""
                                    }
                                    return object.rows[row][column]
                                }, set: {
                                    guard object.rows.indices.contains(row),
                                          object.rows[row].indices.contains(column)
                                    else {
                                        return
                                    }
                                    object.rows[row][column] = $0
                                }))
                                .textFieldStyle(.roundedBorder).frame(width: 130)
                                .accessibilityLabel(L10n.format("Cell %d, %d", row + 1, column + 1))
                                .accessibilityIdentifier("object-cell-\(row)-\(column)")
                            }
                            Button { object.rows.remove(at: row) } label: { Image(systemName: "minus.circle") }
                                .disabled(object.rows.count == 1).accessibilityLabel(L10n.text("Delete Row"))
                        }
                    }
                }
            }
            HStack {
                Button(L10n.text("Add Row")) { object.rows.append(Array(repeating: "", count: object.rows[0].count)) }
                    .disabled(object.rows.count >= 100).accessibilityIdentifier("object-add-row")
                Button(L10n.text("Add Column")) { for row in object.rows.indices {
                    object.rows[row].append("")
                } }
                .disabled((object.rows.first?.count ?? 0) >= 20).accessibilityIdentifier("object-add-column")
            }
            Text(L10n.text("Cells contain Typst content. Paste TSV below to replace all rows."))
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $pasted).frame(height: 70).border(.secondary.opacity(0.3))
                .accessibilityLabel(L10n.text("Tab-separated data")).accessibilityIdentifier("object-tsv")
            Button(L10n.text("Use Pasted Data")) {
                do { try object.pasteTable(pasted)
                    error = nil
                } catch { self.error = error.localizedDescription }
            }.disabled(pasted.isEmpty).accessibilityIdentifier("object-paste-table")
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading) {
            Text(L10n.text(label)).font(.caption)
            TextField(L10n.text(label), text: text).textFieldStyle(.roundedBorder)
        }
    }
}
