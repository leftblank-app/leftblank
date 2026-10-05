import LeftBlankCore
import SwiftUI
import UniformTypeIdentifiers

struct TabletRoot: View {
    @ObservedObject var workspace: TabletWorkspace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @AppStorage("iPadAppearance") private var appearance = AppAppearance.system.rawValue
    @State private var searchResults: [LibraryDocument] = []
    @State private var column: NavigationSplitViewColumn = .sidebar
    @State private var visibility: NavigationSplitViewVisibility = .all
    @State private var detailWidth: CGFloat = 0
    @State private var windowSize: CGSize = .zero
    @State private var query = ""
    @State private var importing = false
    @State private var importingProject = false
    @State private var renaming = false
    @State private var title = ""
    @State private var presentedPanel: TabletWorkspace.Panel?
    @State private var dismissingPanel = false

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility, preferredCompactColumn: $column) {
            List {
                ForEach(query.isEmpty ? workspace.documents : searchResults) { item in
                    Button {
                        Task { await workspace.open(item)
                            if workspace.document?.id == item.id {
                                column = .detail
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.system(size: 15, weight: .medium)).foregroundStyle(.primary)
                            Text(item.snippet).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }.padding(.vertical, 3)
                    }.disabled(workspace.busy)
                        .swipeActions(allowsFullSwipe: false) {
                            Button(L10n.text("Move to Trash"), role: .destructive) {
                                Task { await workspace.trash(item) }
                            }
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(TabletTheme.background)
            .safeAreaInset(edge: .top, spacing: 0) { libraryHeader }
            .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
            .toolbar(removing: .sidebarToggle)
            .toolbar(.hidden, for: .navigationBar)
        } detail: {
            Group {
                if workspace.document != nil {
                    writing
                } else {
                    TabletEmptyState(
                        title: L10n.text("Your writing"),
                        icon: "book-open-text",
                        detail: L10n.text("Choose a document to begin writing."),
                    )
                    .toolbar { ToolbarItem(placement: .topBarLeading) { sidebarToggle } }
                }
            }.toolbar(removing: .sidebarToggle)
        }
        .tint(TabletTheme.accent)
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        .task(id: query) { await searchLibrary() }
        .onChange(of: workspace.documents) { _, _ in Task { await searchLibrary() } }
        .onChange(of: workspace.document?.id) { _, id in
            if id != nil {
                visibility = .detailOnly
                column = .detail
            }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.plainText, UTType(filenameExtension: "typ") ?? .plainText],
        ) { result in
            switch result {
            case let .success(url): Task { await workspace.importDocument(url)
                    column = .detail
                }
            case let .failure(error): workspace.message = error.localizedDescription
            }
        }
        .environment(\.locale, L10n.locale)
        .onReceive(NotificationCenter.default.publisher(for: .leftblankLanguageChanged)) { _ in
            workspace.objectWillChange.send()
        }
        .fileImporter(isPresented: $importingProject, allowedContentTypes: [.folder]) { result in
            switch result {
            case let .success(url): Task { await workspace.importProject(url)
                    column = .detail
                }
            case let .failure(error): workspace.message = error.localizedDescription
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear.onChange(of: geometry.size, initial: true) { _, size in windowSize = size }
            }
        }
        .onChange(of: workspace.panel, initial: true) { _, _ in updatePanelPresentation() }
        .sheet(item: panelBinding, onDismiss: panelDismissed) { panel in
            TabletPanel(workspace: workspace, panel: panel)
                .presentationDetents(panel == .commands ? [.large] : [.medium, .large])
        }
        .fullScreenCover(isPresented: universeBinding, onDismiss: panelDismissed) {
            TabletPanel(workspace: workspace, panel: .universe)
        }
        .sheet(isPresented: Binding(get: { workspace.shareURL != nil }, set: {
            if !$0 {
                workspace.shareURL = nil
            }
        })) {
            if let url = workspace.shareURL {
                TabletShare(url: url)
            }
        }
        .alert(
            L10n.text("LeftBlank"),
            isPresented: Binding(get: { workspace.message != nil }, set: {
                if !$0 {
                    workspace.message = nil
                }
            }),
        ) {
            Button(L10n.text("OK")) { workspace.message = nil }
        } message: { Text(workspace.message ?? "") }
        .alert(L10n.text("Rename"), isPresented: $renaming) {
            TextField(L10n.text("Title"), text: $title)
            Button(L10n.text("Save")) { Task { await workspace.rename(title) } }
            Button(L10n.text("Cancel"), role: .cancel) {}
        }
    }

    private func searchLibrary() async {
        let requested = query
        guard !requested.isEmpty else {
            searchResults = []
            return
        }
        do {
            let result = try await workspace.library.list(query: requested)
            guard query == requested, !Task.isCancelled else {
                return
            }
            searchResults = result
        } catch { workspace.message = error.localizedDescription }
    }

    private var libraryHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !workspace.canWrite {
                Button(subscriptionText(
                    "Subscribe to write · Reading and exports remain available",
                    "订阅以写作 · 阅读和导出仍可使用",
                )) {
                    workspace.panel = .subscription
                }.font(.footnote).accessibilityIdentifier("subscription-banner")
            }
            Text(L10n.text("Your writing")).font(.system(size: 23, weight: .medium, design: .serif))
                .foregroundStyle(Color(uiColor: TabletTheme.nativeText))
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("library-title")
            HStack(spacing: 4) {
                HStack(spacing: 8) {
                    TabletIcon(name: "magnifying-glass", size: 15).foregroundStyle(TabletTheme.secondary)
                    TextField(L10n.text("Search"), text: $query).font(.system(size: 13))
                        .textFieldStyle(.plain).autocorrectionDisabled()
                        .accessibilityIdentifier("library-search")
                }.padding(.horizontal, 10).frame(height: 44)
                    .background(Color(uiColor: TabletTheme.nativeEditor), in: RoundedRectangle(cornerRadius: 8))
                Button { workspace.showUniverse() } label: {
                    TabletIcon(name: "grid-four").frame(width: 44, height: 44)
                }.buttonStyle(.plain).disabled(workspace.busy)
                    .accessibilityLabel(L10n.text("Browse templates")).accessibilityIdentifier("new-document")
                TabletLibraryMenu(actions: [
                    .init(title: L10n.text("Import a document…"), icon: "file-text") { importing = true },
                    .init(title: L10n.text("Import Project…"), icon: "folder-open") { importingProject = true },
                    .init(title: L10n.text("Settings"), icon: "gear") { workspace.panel = .settings },
                    .init(title: L10n.text("Trash"), icon: "trash") { Task { await workspace.showTrash() } },
                ] + (supportsMultipleWindows ? [
                    .init(title: L10n.text("New Window"), icon: "copy") { openWindow(id: "writing") },
                ] : [])).frame(width: 44, height: 44)
            }
        }.padding(16).foregroundStyle(TabletTheme.secondary).background(TabletTheme.background)
            .overlay(alignment: .bottom) { Rectangle().fill(TabletTheme.border).frame(height: 0.5) }
    }

    private var sidebarToggle: some View {
        Button {
            withAnimation {
                if windowSize.width < 700 {
                    column = .sidebar
                    visibility = .all
                } else {
                    visibility = visibility == .all ? .detailOnly : .all
                }
            }
        } label: {
            TabletIcon(name: "sidebar-simple").frame(width: 44, height: 44)
        }.buttonStyle(.plain).foregroundStyle(TabletTheme.secondary)
            .accessibilityLabel(L10n.text("Browse Library")).accessibilityIdentifier("sidebar-toggle")
    }

    private var panelBinding: Binding<TabletWorkspace.Panel?> {
        Binding(get: {
            presentedPanel == .universe ? nil : presentedPanel
        }, set: { _ in dismissPanel() })
    }

    private var universeBinding: Binding<Bool> {
        Binding(get: {
            presentedPanel == .universe
        }, set: { presented in
            if !presented {
                dismissPanel()
            }
        })
    }

    private func updatePanelPresentation() {
        guard !dismissingPanel else {
            return
        }
        if presentedPanel != nil,
           workspace.panel == nil || (presentedPanel == .universe) != (workspace.panel == .universe)
        {
            // UIKit must finish dismissing one presentation before changing
            // between a sheet and a full-screen cover. Keep the requested panel
            // in the workspace until onDismiss delivers the next presentation.
            dismissingPanel = true
            presentedPanel = nil
        } else {
            presentedPanel = workspace.panel
        }
    }

    private func dismissPanel() {
        if !dismissingPanel {
            workspace.panel = nil
            dismissingPanel = true
        }
        presentedPanel = nil
    }

    private func panelDismissed() {
        dismissingPanel = false
        presentedPanel = workspace.panel
    }

    private var writing: some View {
        GeometryReader { geometry in
            let sideBySide = geometry.size.width >= 800 && workspace.layout == .split
            let reading = workspace.layout == .preview
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    TabletEditor(workspace: workspace)
                        .frame(width: reading ? 0 : sideBySide ? geometry.size.width / 2 : geometry.size.width)
                        .clipped().opacity(reading ? 0 : 1).accessibilityHidden(reading)
                        .allowsHitTesting(!reading)
                    ZStack {
                        TabletPreview(workspace: workspace)
                        if !workspace.previewReady {
                            TabletEmptyState(
                                title: L10n.text("Your words are becoming pages"),
                                icon: "file-text",
                                detail: workspace.previewIssue ?? L10n.text(workspace.serviceStatus),
                            )
                        }
                    }.overlay(alignment: .bottomTrailing) {
                        if reading || sideBySide {
                            HStack(spacing: 10) {
                                TabletPreviewReadingControls(session: workspace.previewReading) {
                                    workspace.layout = workspace.previewReturnLayout == .split && detailWidth >= 800
                                        ? .split : .preview
                                }
                                Button { workspace.previewZoom = max(0.5, workspace.previewZoom - 0.1) } label: {
                                    TabletIcon(name: "magnifying-glass-minus")
                                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                                }.accessibilityLabel(L10n.text("Zoom Out")).accessibilityIdentifier("preview-zoom-out")
                                    .disabled(workspace.previewZoom <= 0.5)
                                Text("\(Int((workspace.previewZoom * 100).rounded()))%")
                                    .font(.caption.monospacedDigit())
                                Button { workspace.previewZoom = min(2, workspace.previewZoom + 0.1) } label: {
                                    TabletIcon(name: "magnifying-glass-plus")
                                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                                }.accessibilityLabel(L10n.text("Zoom In")).accessibilityIdentifier("preview-zoom-in")
                                    .disabled(workspace.previewZoom >= 2)
                            }.padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                                .padding(8)
                        }
                    }.overlay(alignment: .top) {
                        if workspace.serviceStatus == "Document Needs Attention" {
                            Button { workspace.panel = .checks } label: {
                                HStack(spacing: 8) {
                                    TabletIcon(name: "warning-circle", size: 16)
                                    Text(workspace.diagnostics.first(where: { $0["severity"].int == 1 })?["message"]
                                        .string ?? L10n.text("Document Needs Attention"))
                                        .font(.system(size: 12)).lineLimit(2)
                                    Spacer()
                                    Text(L10n.text("Check Source")).font(.system(size: 12, weight: .medium))
                                }.padding(12).frame(maxWidth: .infinity).background(TabletTheme.background)
                            }.buttonStyle(.plain).accessibilityIdentifier("preview-error")
                        }
                    }.overlay(alignment: .leading) {
                        if sideBySide {
                            Rectangle().fill(TabletTheme.border).frame(width: 0.5)
                        }
                    }.frame(width: reading ? geometry.size.width : sideBySide ? geometry.size.width / 2 : 0)
                        .clipped().opacity(reading || sideBySide ? 1 : 0).accessibilityHidden(!reading && !sideBySide)
                        .allowsHitTesting(reading || sideBySide)
                }
                HStack {
                    Text(L10n.text(workspace.saveStatus)).accessibilityIdentifier("save-status")
                    Text(L10n.text(workspace.serviceStatus)).accessibilityIdentifier("engine-status")
                        .accessibilityValue(workspace.previewReady ? L10n.text(workspace.serviceStatus) : L10n
                            .text("Waiting for Typesetting"))
                    Spacer()
                    if !reading, !sideBySide {
                        TabletPreviewReadingControls(session: workspace.previewReading, showFollow: false) {
                            workspace.layout = .preview
                        }
                    }
                    let position = workspace.metrics.position(at: workspace.selection.location)
                    Text("\(position.line + 1):\(position.character + 1)")
                        .accessibilityIdentifier("source-position")
                        .accessibilityValue("\(position.line):\(position.character)")
                    Text(L10n.format("%@ words", String(workspace.metrics.wordCount)))
                    Button { workspace.panel = .checks } label: {
                        TabletIcon(name: workspace.diagnostics.isEmpty ? "check" : "warning-circle", size: 14)
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel(L10n.text("Check Source"))
                    .accessibilityIdentifier("check-source")
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 14)
                    .background(TabletTheme.background)
                    .overlay(alignment: .top) { Rectangle().fill(TabletTheme.border).frame(height: 0.5) }
            }
            .overlay {
                if workspace.busy {
                    ProgressView().accessibilityIdentifier("document-loading")
                }
            }
            .onChange(of: geometry.size.width) { _, width in
                detailWidth = width
                if width < 800, workspace.layout == .split {
                    workspace.layout = .writing
                }
            }
            .onAppear {
                detailWidth = geometry.size.width
                if geometry.size.width < 800, workspace.layout == .split {
                    workspace.layout = .writing
                }
            }
        }
        .navigationTitle(workspace.document?.title ?? L10n.text("Untitled"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbarBackground(TabletTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { sidebarToggle }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(workspace.document?.title ?? L10n.text("Untitled")).font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                    if workspace.isPackageSource {
                        HStack(spacing: 4) {
                            TabletIcon(name: "lock-simple").frame(width: 12, height: 12)
                            Text(L10n.text("Read-only Package")).font(.caption)
                        }.foregroundStyle(.secondary).accessibilityIdentifier("readonly-package")
                    }
                    if let source = workspace.sourceURL, source != workspace.entryURL {
                        Text(workspace.sourceLabel(source)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .accessibilityIdentifier("active-source")
                    }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                layoutButton(.writing, icon: "pencil-simple", title: "Writing", key: "1")
                if detailWidth >= 800 {
                    layoutButton(.split, icon: "columns", title: "Side-by-side Preview", key: "2")
                }
                layoutButton(.preview, icon: "eye", title: "Preview", key: "3")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { workspace.panel = .commands } label: {
                    TabletIcon(name: "command").frame(width: 44, height: 44)
                }
                .accessibilityLabel(L10n.text("Discover Commands"))
                .keyboardShortcut("j").accessibilityIdentifier("commands")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { workspace.showUniverse() } label: {
                        Label { Text(L10n.text("New Document")) } icon: { TabletIcon.menuImage(
                            "grid-four",
                            title: L10n.text("New Document"),
                        ) }
                    }.accessibilityIdentifier("new-document")
                    Button(L10n.text("Outline")) { workspace.panel = .outline }.keyboardShortcut("4")
                    Button(L10n.text("Project Files")) { workspace.showProjectFiles() }
                        .accessibilityIdentifier("project-files")
                    Button(L10n.text("Edit Table or Image…")) { workspace.editObjectAtCursor() }
                        .disabled(!workspace.canWrite || workspace.busy)
                        .accessibilityIdentifier("edit-object")
                    Menu(L10n.text("Writing Assistance")) {
                        Button(L10n.text("Complete at Cursor")) { workspace.requestAssistance(.completion) }
                        Button(L10n.text("Explain at Cursor")) { workspace.requestAssistance(.help) }
                        Button(L10n.text("Actions at Cursor")) { workspace.requestAssistance(.actions) }
                        Button(L10n.text("Go to Definition")) { workspace.goToDefinition() }
                        Button(L10n.text("Go Back")) { workspace.navigateBack() }
                        Button(L10n.text("Reveal in Preview")) { workspace.revealPreview() }
                    }.disabled(!workspace.serviceReady)
                    Button(L10n.text("Check Source")) { workspace.panel = .checks }.keyboardShortcut("5")
                    Button(L10n.text("Document History…")) { Task { await workspace.showHistory() } }
                    Button(L10n.text("Rename")) { title = workspace.document?.title ?? ""
                        renaming = true
                    }
                    Button(L10n.text("Save")) { Task { await workspace.save() } }.keyboardShortcut("s")
                    Button(L10n.text("Export Source…")) { workspace.exportSource() }
                        .accessibilityIdentifier("export-source")
                    Button(L10n.text("Print…")) { Task { await workspace.printDocument() } }
                        .keyboardShortcut("p").disabled(!workspace.serviceReady)
                        .accessibilityIdentifier("print-document")
                    if supportsMultipleWindows {
                        Button(L10n.text("New Window")) { openWindow(id: "writing") }
                            .keyboardShortcut("n", modifiers: [.command, .shift])
                    }
                    Button(subscriptionText("Export Project…", "导出项目…")) { Task { await workspace.exportProject() } }
                        .accessibilityIdentifier("export-project")
                    Button(L10n.text("Export PDF…")) { Task { await workspace.exportPDF() } }
                        .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!workspace.serviceReady)
                    Button(L10n.text("Templates & Packages")) { workspace.showUniverse() }
                    Button(L10n.text("Reconnect")) { Task { await workspace.connect() } }
                } label: {
                    TabletIcon(name: "dots-three-vertical").frame(width: 44, height: 44)
                        .accessibilityLabel(L10n.text("Documents"))
                }
                .accessibilityIdentifier("document-actions")
            }
        }
        .onChange(of: workspace.layout) { _, layout in
            if layout == .preview {
                workspace.editor?.resignFirstResponder()
            }
        }
    }

    private func layoutButton(
        _ layout: TabletWorkspace.Layout,
        icon: String,
        title: String,
        key: KeyEquivalent,
    ) -> some View {
        Button { workspace.layout = layout } label: {
            TabletIcon(name: icon).frame(width: 44, height: 44)
                .foregroundStyle(workspace.layout == layout ? TabletTheme.accent : TabletTheme.secondary)
                .overlay(alignment: .bottom) {
                    if workspace
                        .layout == layout
                    {
                        Capsule().fill(TabletTheme.accent).frame(width: 10, height: 1.5).padding(
                            .bottom,
                            4,
                        )
                    }
                }
        }.buttonStyle(.plain).accessibilityLabel(L10n.text(title)).accessibilityIdentifier("layout-" + layout.rawValue)
            .accessibilityAddTraits(workspace.layout == layout ? .isSelected : [])
            .keyboardShortcut(key)
    }
}
