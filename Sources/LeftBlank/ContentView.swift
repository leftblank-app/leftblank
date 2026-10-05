import LeftBlankCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var localization = AppLocalization.shared
    @State private var splitFraction: CGFloat = 0.5

    var body: some View {
        Group {
            if workspace.isLibraryHome {
                LibraryBrowser(workspace: workspace, library: workspace.library)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.editor)
            } else {
                writing
            }
        }
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .sheet(item: $workspace.objectEditSession) { session in
            ObjectEditorForm(
                object: session.object,
                resourceRoot: workspace.resourceRoot,
                sourceURL: session.url,
                failure: workspace.message,
                apply: { object in
                    workspace.applyObjectEdit(object, session: session)
                },
                cancel: { workspace.objectEditSession = nil },
            )
        }
        .sheet(isPresented: $workspace.historyOpen) {
            DocumentHistoryView(workspace: workspace, history: workspace.history)
        }
        .sheet(isPresented: $workspace.libraryOpen) {
            LibraryBrowser(workspace: workspace, library: workspace.library)
        }
    }

    private var writing: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let editorWidth = workspace.layout == .writing ? width : (workspace.layout == .preview ? 0 : max(
                        280,
                        min(width - 280, width * splitFraction),
                    ))
                    HStack(spacing: 0) {
                        manuscript.frame(width: editorWidth).clipped()
                            .overlay(alignment: .topLeading) {
                                if workspace.layout != .preview {
                                    FloatingOutline(
                                        workspace: workspace,
                                        availableMargin: ManuscriptLayout.horizontalInset(for: editorWidth),
                                    )
                                    .padding(.leading, 6).padding(.top, 64)
                                }
                            }
                            .opacity(workspace.layout == .preview ? 0 : 1)
                            .accessibilityHidden(workspace.layout == .preview)
                        Rectangle().fill(Theme.border).frame(width: workspace.layout == .split ? 1 : 0)
                            .overlay(Color.clear.frame(width: 9).contentShape(Rectangle())
                                .gesture(DragGesture(coordinateSpace: .named("writingArea")).onChanged { value in
                                    splitFraction = min(
                                        0.75,
                                        max(0.25, value.location.x / width),
                                    )
                                }))
                        preview.frame(width: max(0, width - editorWidth - (workspace.layout == .split ? 1 : 0)))
                            .clipped()
                            .opacity(workspace.layout == .writing ? 0 : 1)
                            .accessibilityHidden(workspace.layout == .writing)
                    }.coordinateSpace(name: "writingArea")
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let message = workspace.message {
                messageBar(message)
            }
            if workspace.paletteOpen {
                Rectangle().fill(Theme.accent.opacity(0.4)).frame(height: 1)
                CommandPalette(workspace: workspace)
            }
            Rectangle().fill(Theme.border.opacity(0.55)).frame(height: 1)
            footer
        }
        .overlay {
            if workspace.checksOpen {
                GeometryReader { geometry in
                    ZStack(alignment: .bottomTrailing) {
                        Color.clear.contentShape(Rectangle()).onTapGesture { workspace.checksOpen = false }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel(L10n.text("Close"))
                        DocumentChecksPopup(workspace: workspace)
                            .frame(width: min(380, max(260, geometry.size.width - 32)))
                            .padding(.trailing, 18).padding(.bottom, 42)
                    }
                }
            }
        }
    }

    private var manuscript: some View {
        ManuscriptView(workspace: workspace).clipped().background(Theme.editor)
    }

    private var preview: some View {
        Group {
            if let url = workspace.previewURL {
                PreviewView(
                    url: url,
                    zoom: workspace.previewZoom,
                    dark: workspace.previewDark,
                    readingSession: workspace.previewReading,
                    onLoading: { workspace.previewWillLoad(at: url) },
                    onReady: { workspace.previewDidBecomeReady(at: url) },
                ) { workspace.showMessage(
                    $0,
                    persistent: true,
                ) }
            } else {
                VStack(spacing: 16) {
                    PhosphorIcon(name: "file-text", size: 32).foregroundStyle(Theme.accent.opacity(0.8))
                    Text(L10n.text("Your words are becoming pages")).font(.system(size: 16, weight: .medium))
                    Text(L10n.text(workspace.serviceStatus)).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    if !workspace.serviceReady {
                        Button(L10n.text("Reconnect")) { workspace.startService() }.buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(Theme.panel)
            .overlay(alignment: .topTrailing) {
                FloatingPaneControls(title: L10n.text("Preview"), icon: "eye") {
                    PreviewReadingControls(session: workspace.previewReading) {
                        workspace.layout = workspace.previewReturnLayout ?? .preview
                    }

                    Button { workspace.previewDark.toggle() } label: {
                        Text(workspace.previewDark ? L10n.text("Dark") : L10n.text("Light"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(workspace.previewDark ? Theme.accent : Theme.secondary)
                            .frame(width: 68, height: 28).contentShape(Rectangle())
                    }.buttonStyle(QuietControlStyle()).accessibilityIdentifier("preview-colors")
                        .learningHelp(
                            L10n.text("Preview Colors"),
                            shortcut: "⌘\(workspace.commandKey.uppercased()) → v n",
                            detail: L10n.text("Only changes preview colors. Exported PDFs are unchanged."),
                        )
                    QuietButton(icon: "minus", help: L10n.text("Zoom Out"), iconSize: 14, hitSize: 28) {
                        workspace.previewZoom = max(0.5, workspace.previewZoom - 0.1)
                    }.disabled(workspace.previewZoom <= 0.5)
                    Text("\(Int((workspace.previewZoom * 100).rounded()))%")
                        .font(.system(size: 10, design: .monospaced)).frame(width: 32)
                    QuietButton(icon: "plus", help: L10n.text("Zoom In"), iconSize: 14, hitSize: 28) {
                        workspace.previewZoom = min(2, workspace.previewZoom + 0.1)
                    }.disabled(workspace.previewZoom >= 2)
                }.padding(8)
            }
            .overlay(alignment: .bottomLeading) {
                if let main = workspace.mainFileURL {
                    Button { workspace.open(main) } label: {
                        Label(L10n.text("Return to Main Document"), systemImage: "arrow.uturn.backward")
                    }.buttonStyle(.plain).font(.system(size: 10))
                        .foregroundStyle(Theme.secondary).padding(8)
                        .background(Theme.panel.opacity(0.94), in: RoundedRectangle(cornerRadius: 7)).padding(8)
                }
            }
    }

    private func messageBar(_ message: String) -> some View {
        HStack(spacing: 10) {
            PhosphorIcon(name: "warning-circle", size: 15).foregroundStyle(Theme.accent)
            Text(message).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(3)
            Spacer()
            QuietButton(icon: "x", help: L10n.text("Dismiss Message")) { workspace.message = nil }
        }.padding(.horizontal, 20).padding(.vertical, 3).background(Theme.panel)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button { workspace.togglePalette() } label: {
                HStack(spacing: 8) {
                    PhosphorIcon(name: "command", size: 14)
                    Text(L10n.text("Discover Commands")).font(.system(size: 11))
                    Text("⌘ \(workspace.commandKey.uppercased())").font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                }.foregroundStyle(workspace.paletteOpen ? Theme.accent : Theme.secondary)
            }.buttonStyle(.plain).accessibilityLabel(L10n.format(
                "Discover Commands %@",
                "⌘\(workspace.commandKey.uppercased())",
            )).learningHelp(
                L10n.text("Discover Commands"),
                shortcut: "⌘\(workspace.commandKey.uppercased())",
                detail: L10n.text("Explore with letter keys, or press / to search all commands."),
            )
            Spacer()
            if workspace.layout == .writing {
                PreviewReadingControls(session: workspace.previewReading, showFollow: false) {
                    workspace.layout = workspace.previewReturnLayout ?? .preview
                }
            }
            Text(L10n.text(workspace.saveStatus)).font(.system(size: 10)).foregroundStyle(Theme.muted)
            Rectangle().fill(Theme.border).frame(width: 1, height: 10)
            Text(L10n.format("%@ words", String(workspace.wordCount))).font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.muted)
            Text("\(workspace.position.line + 1):\(workspace.position.character + 1)").font(.system(
                size: 10,
                design: .monospaced,
            )).foregroundStyle(Theme.muted).frame(minWidth: 35, alignment: .trailing)
            DocumentCheckButton(workspace: workspace)
        }.padding(.horizontal, 24).frame(height: 34)
    }
}
