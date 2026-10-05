import LeftBlankCore
import SwiftUI

struct TabletPanel: View {
    @ObservedObject var workspace: TabletWorkspace
    let panel: TabletWorkspace.Panel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var command: WritingCommand?
    @State private var values: [String: String] = [:]
    @State private var language = L10n.language
    @State private var resource: TabletResourceSelection?
    @State private var insertingResource = false
    @State private var trashSnapshot: LibraryTrashSnapshot?
    @State private var confirmingEmptyTrash = false
    @AppStorage("iPadAppearance") private var appearance = AppAppearance.system
    @AppStorage("iPadPreviewDark") private var previewDark = false

    var body: some View {
        NavigationStack {
            Group {
                switch panel {
                case .commands: commands
                case .outline: outline
                case .checks: checks
                case .history: history
                case .settings: settings
                case .universe: TabletUniverseBrowser(workspace: workspace)
                case .trash: trash
                case .subscription: TabletSubscriptionView(subscription: workspace.subscription)
                case .files: TabletProjectFiles(workspace: workspace)
                case .projectEntry: TabletProjectEntryPicker(workspace: workspace)
                case .assistance: TabletAssistanceView(workspace: workspace)
                case .objectEditor: TabletObjectEditor(workspace: workspace)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } } }
        }.tint(TabletTheme.accent)
    }

    private var title: String {
        switch panel {
        case .commands: L10n.text("Discover Commands")
        case .outline: L10n.text("Outline")
        case .checks: L10n.text("Check Source")
        case .history: L10n.text("Document History")
        case .settings: L10n.text("Settings")
        case .universe: L10n.text("Templates & Packages")
        case .trash: L10n.text("Trash")
        case .subscription: subscriptionText("Subscription", "订阅")
        case .files: L10n.text("Project Files")
        case .projectEntry: L10n.text("Choose Main File")
        case .assistance: L10n.text("Writing Assistance")
        case .objectEditor: L10n.text("Edit Table or Image…")
        }
    }

    private var commands: some View {
        List {
            if let command {
                Section(command.title) {
                    Text(command.detail).foregroundStyle(.secondary)
                    ForEach(command.fields) { field in
                        if let kind = field.resourceKind {
                            TabletResourcePicker(workspace: workspace, kind: kind, selection: $resource)
                                .id(command.id)
                        } else {
                            TextField(
                                field.title,
                                text: Binding(
                                    get: { values[field.id] ?? field.initial },
                                    set: { values[field.id] = $0 },
                                ),
                            )
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                        }
                    }
                    Button(L10n.text("Insert")) {
                        if command.fields.contains(where: { $0.resourceKind != nil }) {
                            guard let resource else {
                                return
                            }
                            insertingResource = true
                            Task {
                                defer { insertingResource = false }
                                do { try await workspace.insertResourceCommand(
                                    command,
                                    values: values,
                                    resource: resource,
                                ) } catch { workspace.message = error.localizedDescription }
                            }
                        } else {
                            workspace.insert(command, values: values)
                        }
                    }
                    .disabled(insertingResource || !workspace.canWrite || workspace.busy ||
                        (command.fields.contains(where: { $0.resourceKind != nil }) && resource == nil))
                    Button(L10n.text("Back")) { self.command = nil
                        resource = nil
                    }
                    .disabled(insertingResource)
                }
            } else {
                Section {
                    Button(L10n.text("Undo")) {
                        if workspace.canWrite {
                            workspace.editor?.undoManager?.undo()
                        }
                        dismiss()
                    }
                    Button(L10n.text("Redo")) {
                        if workspace.canWrite {
                            workspace.editor?.undoManager?.redo()
                        }
                        dismiss()
                    }
                    Button(L10n.text("Indent")) { workspace.lineAction(.indent)
                        dismiss()
                    }
                    Button(L10n.text("Outdent")) { workspace.lineAction(.outdent)
                        dismiss()
                    }
                    Button(L10n.text("Toggle Comment")) { workspace.lineAction(.comment)
                        dismiss()
                    }
                    Button(L10n.text("Format Document")) { Task { await workspace.format() } }
                        .disabled(!workspace.serviceReady)
                }
                ForEach(CommandGroup.all) { group in
                    let choices = WritingCommand.search(query).filter { $0.isInsertion && $0.group == group.id }
                    if !choices.isEmpty {
                        Section(group.title) {
                            ForEach(choices) { item in
                                Button { command = item
                                    resource = nil
                                    values = Dictionary(uniqueKeysWithValues: item.fields.map { ($0.id, $0.initial) })
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.title)
                                        Text(item.detail).font(.subheadline).foregroundStyle(.secondary)
                                    }.padding(.vertical, 4)
                                }.accessibilityIdentifier("command-" + item.id)
                            }
                        }
                    }
                }
            }
        }.searchable(text: $query, prompt: L10n.text("Search Commands"))
    }

    private var outline: some View {
        List {
            ForEach(Array(headings(workspace.outline).enumerated()), id: \.offset) { _, item in
                Button(item["name"].string ?? "") {
                    let position = item["selectionRange"]["start"]
                    workspace.jump(TextPosition(
                        line: position["line"].int ?? 0,
                        character: position["character"].int ?? 0,
                    ))
                }.frame(minHeight: 44)
            }
        }.overlay {
            if workspace.outline.isEmpty {
                TabletEmptyState(title: L10n.text("Outline"), icon: "list-bullets")
            }
        }
    }

    private func headings(_ nodes: [JSONValue]) -> [JSONValue] {
        nodes.flatMap { node in
            (node["kind"].int == 3 ? [node] : []) + headings(node["children"].array)
        }
    }

    private var checks: some View {
        List {
            Text(L10n.text(workspace.serviceStatus)).foregroundStyle(.secondary)
            ForEach(Array(workspace.diagnostics.enumerated()), id: \.offset) { _, item in
                Button {
                    let position = item["range"]["start"]
                    workspace.jump(TextPosition(
                        line: position["line"].int ?? 0,
                        character: position["character"].int ?? 0,
                    ))
                } label: {
                    Label { Text(item["message"].string ?? "") } icon: { TabletIcon(name: "warning-circle") }
                        .foregroundStyle(.primary)
                }
                .accessibilityValue(item["severity"].int == 1 ? "error" : "warning")
            }
            if workspace.diagnostics.isEmpty {
                Label { Text(L10n.text("No issues found")) } icon: { TabletIcon(name: "check") }
            }
        }
    }

    private var history: some View {
        List(workspace.revisions) { revision in
            NavigationLink {
                TabletRevision(workspace: workspace, revision: revision)
            } label: {
                VStack(alignment: .leading) {
                    Text(revision.createdAt, format: .dateTime.month().day().hour().minute())
                    Text(ByteCountFormatter.string(fromByteCount: Int64(revision.bytes), countStyle: .file))
                        .font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            }.accessibilityIdentifier("history-revision")
        }.overlay {
            if workspace.revisions.isEmpty {
                TabletEmptyState(title: L10n.text("No history yet"), icon: "clock-counter-clockwise")
            }
        }
    }

    private var trash: some View {
        List {
            ForEach(workspace.trashedDocuments) { item in
                HStack {
                    Text(item.title)
                    Spacer()
                    Button(L10n.text("Restore")) { Task { await workspace.restoreDocument(item) } }
                        .buttonStyle(.bordered).disabled(workspace.busy)
                }
            }
            if !workspace.trashedDocuments.isEmpty {
                Button(L10n.text("Empty Trash…"), role: .destructive) {
                    Task {
                        do {
                            let snapshot = try await workspace.library.trashSnapshot()
                            guard workspace.panel == .trash, !snapshot.isEmpty else {
                                return
                            }
                            trashSnapshot = snapshot
                            confirmingEmptyTrash = true
                        } catch { workspace.message = error.localizedDescription }
                    }
                }.disabled(workspace.busy)
            }
        }
        .confirmationDialog(L10n.text("Empty Trash?"), isPresented: $confirmingEmptyTrash) {
            Button(L10n.text("Empty Trash"), role: .destructive) {
                guard let trashSnapshot else {
                    return
                }
                Task { await workspace.emptyTrash(trashSnapshot) }
            }
        } message: {
            Text(L10n.format(
                "Permanently delete %d documents and their attachments? This cannot be undone.",
                trashSnapshot?.count ?? 0,
            ))
        }
    }

    private var settings: some View {
        Form {
            Section(subscriptionText("Subscription", "订阅")) {
                Button(subscriptionText("Subscription & purchases", "订阅与购买")) { workspace.panel = .subscription }
                    .accessibilityIdentifier("subscription-settings")
            }
            Section(L10n.text("Appearance")) {
                Picker(L10n.text("Appearance"), selection: $appearance) {
                    Text(L10n.text("Follow System")).tag(AppAppearance.system)
                    Text(L10n.text("Light")).tag(AppAppearance.light)
                    Text(L10n.text("Dark")).tag(AppAppearance.dark)
                }
                Toggle(L10n.text("Dark preview"), isOn: $previewDark)
            }
            Section(L10n.text("Writing")) {
                Stepper(
                    L10n.format("Text size: %@", String(Int(workspace.fontSize))),
                    value: $workspace.fontSize,
                    in: 12 ... 28,
                )
                Picker(L10n.text("Language"), selection: $language) {
                    Text(L10n.text("Follow System")).tag(AppLanguage.system)
                    Text("English").tag(AppLanguage.english)
                    Text("简体中文").tag(AppLanguage.simplifiedChinese)
                }.onChange(of: language) { _, language in L10n.setLanguage(language) }
            }
            Section(L10n.text("Document History")) {
                Picker(L10n.text("Keep edited versions"), selection: $workspace.historyInterval) {
                    Text(L10n.text("Every hour")).tag(HistoryInterval.hourly)
                    Text(L10n.text("Every day")).tag(HistoryInterval.daily)
                }
                Text(L10n.text("Latest 7 snapshots · This iPad · Current source only"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("iCloud") {
                Toggle(
                    L10n.text("iCloud Sync"),
                    isOn: Binding(
                        get: { workspace.cloudEnabled },
                        set: { enabled in Task { await workspace.setCloud(enabled) } },
                    ),
                )
                .disabled(workspace.busy)
            }
        }
    }
}
