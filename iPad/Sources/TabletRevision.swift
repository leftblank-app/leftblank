import LeftBlankCore
import SwiftUI

struct TabletRevision: View {
    @ObservedObject var workspace: TabletWorkspace
    let revision: DocumentRevision
    @State private var confirming = false
    @State private var comparison: HistoryComparison?
    @State private var loading = true
    @State private var error: String?
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(revision.createdAt, format: .dateTime)
                if loading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if let error {
                    Text(error).foregroundStyle(.red)
                } else if let comparison {
                    if comparison.identical {
                        Text(L10n.text("This snapshot matches your current writing."))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L10n.format("Changes near line %d", comparison.firstLine)).font(.headline)
                        if comparison.abbreviated {
                            Text(L10n
                                .text(
                                    "Showing the changed area with nearby context. Long changes are abbreviated; restoring uses the complete snapshot.",
                                ))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        let layout = sizeClass == .regular
                            ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                            : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                        layout {
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
                        }
                    }
                }
                Text(L10n
                    .text(
                        "Your current writing will be saved in history before restoring. You can also undo the change.",
                    ))
                    .font(.footnote).foregroundStyle(.secondary)
                Button(L10n.text("Restore Snapshot")) { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(loading || error != nil || comparison?.identical != false || workspace.busy || !workspace
                        .canWrite)
                    .accessibilityIdentifier("history-restore")
            }.padding()
        }
        .task(id: revision.id) { await compare() }
        .onChange(of: workspace.text) { _, _ in
            comparison = nil
            error = HistoryError.changed.localizedDescription
        }
        .onChange(of: workspace.sourceURL) { _, _ in
            comparison = nil
            error = HistoryError.changed.localizedDescription
        }
        .confirmationDialog(L10n.text("Restore this snapshot?"), isPresented: $confirming) {
            Button(L10n.text("Restore Snapshot")) { Task { await workspace.restore(revision) } }
        }
        .navigationBarBackButtonHidden()
        .toolbar { ToolbarItem(placement: .topBarLeading) { TabletBackButton(title: L10n.text("Back")) } }
    }

    private func compare() async {
        loading = true
        defer { loading = false }
        let source = workspace.sourceURL, current = workspace.text
        do {
            let before = try await workspace.revisionSource(revision)
            let result = await Task.detached(priority: .userInitiated) {
                HistoryComparison(before: before, after: current)
            }.value
            guard !Task.isCancelled else {
                return
            }
            guard workspace.sourceURL == source, workspace.text == current else {
                throw HistoryError.changed
            }
            comparison = result
            error = nil
        } catch {
            if !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }
    }

    private func sourceColumn(_ title: String, source: String, ranges: [NSRange], removed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(L10n.text(removed ? "Removed" : "Added"))
                    .font(.caption).foregroundStyle(removed ? .red : .green)
            }
            Text(highlighted(source, ranges: ranges, removed: removed))
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(12)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func highlighted(_ source: String, ranges: [NSRange], removed: Bool) -> AttributedString {
        var result = AttributedString(source)
        for range in ranges {
            guard let range = Range(range, in: source),
                  let start = AttributedString.Index(range.lowerBound, within: result),
                  let end = AttributedString.Index(range.upperBound, within: result)
            else {
                continue
            }
            result[start ..< end].backgroundColor = (removed ? Color.red : Color.green).opacity(0.18)
            if removed {
                result[start ..< end].strikethroughStyle = .single
            }
        }
        return result
    }
}
