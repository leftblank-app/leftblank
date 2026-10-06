import LeftBlankCore
import SwiftUI

/// Healthy, pending and disconnected states remain distinct: an empty diagnostic
/// list alone is not evidence that the document compiled successfully.
extension Workspace {
    var checkErrors: Int {
        diagnostics.filter { $0.severity == 1 }.count
    }

    var checkWarnings: Int {
        diagnostics.filter { $0.severity == 2 }.count
    }

    var checksPassed: Bool {
        serviceReady && hasSuccessfulPreview && !previewStale && diagnostics.isEmpty
    }

    /// The first typesetting attempt failed, so no page will paint until the source is fixed.
    var previewNeedsAttention: Bool {
        serviceReady && !hasSuccessfulPreview
            && (checkErrors > 0 || serviceStatus == "Document Needs Attention")
    }

    var checkLabel: String {
        if !serviceReady {
            return L10n.text(serviceStatus)
        }
        if checkErrors > 0 {
            return checkErrors == 1 ? L10n.text("1 error") : L10n.format(
                "%@ errors",
                String(checkErrors),
            )
        }
        if checkWarnings > 0 {
            return checkWarnings == 1 ? L10n.text("1 warning") : L10n.format(
                "%@ warnings",
                String(checkWarnings),
            )
        }
        if !diagnostics.isEmpty {
            return L10n.format("%@ suggestions", String(diagnostics.count))
        }
        if checksPassed {
            return L10n.text("Up to date")
        }
        return L10n.text(serviceStatus == "Typesetting" ? "Checking…" : "Waiting for Typesetting")
    }

    var checkColor: Color {
        if !serviceReady {
            return Theme.muted
        }
        if checkErrors > 0 {
            return Theme.red
        }
        if !diagnostics.isEmpty {
            return Theme.accent
        }
        return checksPassed ? Theme.green.opacity(0.8) : Theme.muted
    }

    var checkIcon: String {
        if !serviceReady {
            return "plugs-connected"
        }
        if checkErrors > 0 {
            return "warning-circle"
        }
        if !diagnostics.isEmpty {
            return "info"
        }
        return checksPassed ? "check" : "clock-counter-clockwise"
    }
}

struct DocumentCheckButton: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        Button { workspace.checksOpen.toggle() } label: {
            HStack(spacing: 5) {
                PhosphorIcon(name: workspace.checkIcon, size: 13).foregroundStyle(workspace.checkColor)
                Text(workspace.checkLabel).font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }.padding(.horizontal, 6).frame(height: 26).contentShape(Rectangle())
        }.buttonStyle(QuietControlStyle()).accessibilityIdentifier("checks.toggle")
            .accessibilityLabel(L10n.text("Document Checks") + ": " + workspace.checkLabel)
            .learningHelp(L10n.text("Document Checks"), shortcut: "⌘5")
    }
}

struct DocumentChecksPopup: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.text("Document Checks")).font(.system(size: 12, weight: .medium))
                Spacer()
                Text("esc").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
            }.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
            if workspace.diagnostics.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    PhosphorIcon(name: workspace.checkIcon, size: 18).foregroundStyle(workspace.checkColor)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(workspace.checksPassed ? L10n.text("Everything looks good") : workspace.checkLabel)
                            .font(.system(size: 12, weight: .medium))
                        Text(workspace.checksPassed ? L10n.text("Your latest changes are in the preview.") : L10n
                            .text("You can keep writing while checks run."))
                            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        if !workspace.serviceReady {
                            Button(L10n.text("Reconnect")) { workspace.startService() }
                                .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Theme.accent).padding(
                                    .top,
                                    4,
                                )
                        }
                    }
                }.padding(.horizontal, 18).padding(.bottom, 18)
            } else {
                HStack(spacing: 10) {
                    Text(workspace.checkLabel).foregroundStyle(workspace.checkColor)
                    if workspace.checkErrors > 0, workspace.checkWarnings > 0 {
                        Text(L10n.format("%@ warnings", String(workspace.checkWarnings)))
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    if workspace.previewStale {
                        Text(L10n.text("Preview pending")).foregroundStyle(Theme.muted)
                    }
                }.font(.system(size: 10)).padding(.horizontal, 18).padding(.bottom, 10)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(workspace.diagnostics.sorted { $0.severity < $1.severity }) { diagnostic in
                            DiagnosticRow(workspace: workspace, diagnostic: diagnostic)
                        }
                    }.padding(.horizontal, 8).padding(.bottom, 8)
                }.frame(height: min(292, CGFloat(workspace.diagnostics.count) * 82))
            }
        }
        .foregroundStyle(Theme.text).background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border.opacity(0.6)))
        .accessibilityIdentifier("checks.popup")
    }
}

private struct DiagnosticRow: View {
    @ObservedObject var workspace: Workspace
    let diagnostic: DiagnosticItem
    @State private var hovering = false
    var body: some View {
        Button { workspace.showDiagnostic(diagnostic) } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(diagnostic.severity == 1 ? Theme.red : Theme.accent).frame(width: 5, height: 5).padding(
                    .top,
                    5,
                )
                VStack(alignment: .leading, spacing: 5) {
                    Text(diagnostic.message).font(.system(size: 12)).foregroundStyle(Theme.text)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    Text(
                        "\(diagnostic.url.lastPathComponent) · \(diagnostic.position.line + 1):\(diagnostic.position.character + 1)",
                    )
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
                PhosphorIcon(name: "arrow-up-right", size: 12)
                    .foregroundStyle(hovering ? Theme.secondary : Theme.muted.opacity(0.4))
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering ? Theme.border.opacity(0.4) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
}
