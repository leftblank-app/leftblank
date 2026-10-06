import LeftBlankCore
import SwiftUI

struct DocumentHistoryView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var history: DocumentHistoryController
    @State private var confirmingRestore = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("Document History")).font(.system(size: 20, weight: .semibold))
                    Text(workspace.title).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer()
                QuietButton(icon: "x", help: L10n.text("Close")) { workspace.historyOpen = false }
                    .keyboardShortcut(.cancelAction)
            }.padding(24)
            Rectangle().fill(Theme.border.opacity(0.6)).frame(height: 1)
            HStack(spacing: 0) {
                revisionList.frame(width: 210)
                Rectangle().fill(Theme.border.opacity(0.6)).frame(width: 1)
                comparison.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Rectangle().fill(Theme.border.opacity(0.6)).frame(height: 1)
            HStack(spacing: 16) {
                Text(L10n.text("Latest 7 snapshots · This Mac · Current source only"))
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Spacer()
                Button(L10n.text("Restore Snapshot")) { confirmingRestore = true }
                    .disabled(history.busy || history.comparison?.identical != false)
            }.padding(18)
        }
        .frame(width: 940, height: 600)
        .background(Theme.editor).foregroundStyle(Theme.text)
        .task { await history.load() }
        .onDisappear { history.cancelPresentation() }
        .confirmationDialog(L10n.text("Restore this snapshot?"), isPresented: $confirmingRestore) {
            Button(L10n.text("Restore Snapshot")) {
                guard let revision = history.revisions.first(where: { $0.id == history.selectedID }) else {
                    return
                }
                Task { await history.restore(revision) }
            }
        } message: {
            Text(L10n
                .text("Your current writing will be saved in history before restoring. You can also undo the change."))
        }
    }

    private var revisionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 5) {
                ForEach(history.revisions) { revision in
                    Button {
                        Task { await history.select(revision) }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(revision.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 12, weight: .medium))
                            Text(L10n
                                .text(revision.reason == .beforeRestore ? "Before restore" : revision
                                    .reason == .beforeAgentEdit ? "Before agent edit" : "Automatic snapshot"))
                                .font(.system(size: 10)).foregroundStyle(Theme.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(
                                history.selectedID == revision.id ? Theme.panel : .clear,
                                in: RoundedRectangle(cornerRadius: 7),
                            )
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(history.busy)
                }
            }.padding(10)
        }
    }

    @ViewBuilder private var comparison: some View {
        if let error = history.error {
            Text(error).font(.system(size: 13)).foregroundStyle(Theme.red).padding(32)
        } else if history.busy {
            ProgressView().controlSize(.small)
        } else if let comparison = history.comparison {
            if comparison.identical {
                Text(L10n.text("This snapshot matches your current writing.")).foregroundStyle(Theme.secondary)
                    .padding(32)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.format("Changes near line %d", comparison.firstLine)).font(.system(
                        size: 12,
                        weight: .medium,
                    ))
                    if comparison.abbreviated {
                        Text(L10n
                            .text(
                                "Showing the changed area with nearby context. Long changes are abbreviated; restoring uses the complete snapshot.",
                            ))
                            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        sourceColumn(
                            L10n.text("Snapshot"),
                            source: comparison.before,
                            ranges: comparison.removedRanges,
                            removed: true,
                        )
                        sourceColumn(
                            L10n.text("Current writing"),
                            source: comparison.after,
                            ranges: comparison.addedRanges,
                            removed: false,
                        )
                    }.frame(maxHeight: .infinity)
                }.padding(20)
            }
        } else {
            VStack(spacing: 12) {
                Text(L10n.text("Room to change your mind")).font(.system(size: 18, weight: .medium))
                Text(L10n
                    .text(
                        "A snapshot is kept before your first edit, then hourly or daily when you make changes. Unchanged documents create no snapshots.",
                    ))
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            }.frame(maxWidth: 400).padding(32)
        }
    }

    private func highlighted(_ source: String, ranges: [NSRange], removed: Bool) -> AttributedString {
        var text = AttributedString(source)
        for range in ranges {
            guard let sourceRange = Range(range, in: source),
                  let start = AttributedString.Index(sourceRange.lowerBound, within: text),
                  let end = AttributedString.Index(sourceRange.upperBound, within: text)
            else {
                continue
            }
            text[start ..< end].backgroundColor = (removed ? Theme.red : Theme.green).opacity(0.18)
            if removed {
                text[start ..< end].strikethroughStyle = .single
            }
        }
        return text
    }

    private func sourceColumn(_ title: String, source: String, ranges: [NSRange], removed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                Spacer()
                Text(L10n.text(removed ? "Removed" : "Added"))
                    .font(.system(size: 10)).foregroundStyle(removed ? Theme.red : Theme.green)
            }
            ScrollView {
                Text(highlighted(source, ranges: ranges, removed: removed)).font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
            }.background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
