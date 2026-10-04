import LeftBlankCore
import SwiftUI

struct TabletProjectFiles: View {
    @ObservedObject var workspace: TabletWorkspace

    var body: some View {
        List(workspace.projectSources, id: \.self) { source in
            Button {
                Task {
                    if await workspace.openSource(source) {
                        workspace.panel = nil
                    }
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(workspace.sourceLabel(source))
                            .foregroundStyle(.primary)
                        if source.resolvingSymlinksInPath() == workspace.entryURL?.resolvingSymlinksInPath() {
                            Text(L10n.text("Preview entry")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if source.resolvingSymlinksInPath() == workspace.sourceURL?.resolvingSymlinksInPath() {
                        Image(systemName: "checkmark").foregroundStyle(TabletTheme.accent)
                            .accessibilityLabel(L10n.text("Selected"))
                    }
                }
            }.disabled(workspace.busy).accessibilityIdentifier("project-source-" + source.lastPathComponent)
        }
    }
}

struct TabletProjectEntryPicker: View {
    @ObservedObject var workspace: TabletWorkspace

    var body: some View {
        List {
            Section {
                ForEach(workspace.importSources, id: \.self) { source in
                    Button(workspace.importSourceLabel(source)) {
                        Task { await workspace.finishProjectImport(source) }
                    }.disabled(workspace.busy)
                }
            } header: {
                Text(L10n.text("Choose the file that compiles the complete project."))
            }
        }
        .onDisappear {
            if !workspace.busy {
                workspace.cancelProjectImport()
            }
        }
    }
}
