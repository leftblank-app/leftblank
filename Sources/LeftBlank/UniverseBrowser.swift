import LeftBlankCore
import SwiftUI

/// A spacious discovery surface with separate document and writing-tool intents.
/// Metadata and previews load before selection; package code is requested only
/// when the writer explicitly creates a document or inserts an import.
struct UniverseBrowser: View {
    @ObservedObject private var localization = AppLocalization.shared
    private let onImport: (UniversePackage) throws -> Void
    private let onCreate: ((UniversePackage) async throws -> Void)?
    private let onCreateBuiltIn: ((BuiltInTemplate) async throws -> Void)?
    private let onAddSample: ((SampleBook) async throws -> Void)?
    private let onModeChange: ((UniverseDiscoveryMode) -> Void)?
    private let onClose: (() -> Void)?
    private let onBack: (() -> Void)?
    private let compilerVersion: String
    private let canImport: Bool
    private let size: CGSize
    private let previewCacheURL: URL
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: UniverseBrowserModel
    @State private var actionError: String?
    @State private var isApplying = false
    @State private var compactDetails = false
    @State private var catalogPosition: String?
    @State private var actionTask: Task<Void, Never>?
    @State private var refreshTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    init(
        cacheURL: URL,
        mode: UniverseDiscoveryMode = .packages,
        size: CGSize = CGSize(width: 1040, height: 720),
        compilerVersion: String = "0.15.1",
        canImport: Bool = true,
        onBack: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil,
        onModeChange: ((UniverseDiscoveryMode) -> Void)? = nil,
        onCreate: ((UniversePackage) async throws -> Void)? = nil,
        onCreateBuiltIn: ((BuiltInTemplate) async throws -> Void)? = nil,
        onAddSample: ((SampleBook) async throws -> Void)? = nil,
        onImport: @escaping (UniversePackage) throws -> Void,
    ) {
        self.onClose = onClose
        self.onModeChange = onModeChange
        self.onImport = onImport
        self.onCreateBuiltIn = onCreateBuiltIn
        self.onCreate = onCreate
        self.onAddSample = onAddSample
        self.onBack = onBack
        self.compilerVersion = compilerVersion
        self.canImport = canImport
        self.size = size
        previewCacheURL = cacheURL.deletingLastPathComponent().appendingPathComponent("UniversePreviews")
        _model = StateObject(wrappedValue: UniverseBrowserModel(
            store: UniverseCatalogStore(cacheURL: cacheURL),
            mode: mode,
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchAndFilters.disabled(isApplying)
            Rectangle().fill(Theme.border.opacity(0.45)).frame(height: 1)
            GeometryReader { geometry in
                let wide = geometry.size.width >= 850
                HStack(spacing: 0) {
                    if wide || !compactDetails || model.selected == nil {
                        catalog.disabled(isApplying).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if let package = model.selected, wide || compactDetails {
                        if wide {
                            Rectangle().fill(Theme.border.opacity(0.45)).frame(width: 1)
                        }
                        details(package, compact: !wide)
                            .id(package.reference)
                            .frame(width: wide ? 296 : nil)
                            .frame(maxWidth: wide ? nil : .infinity, maxHeight: .infinity)
                    }
                }
            }
            if let actionError {
                Text(actionError).font(.system(size: 11)).foregroundStyle(Theme.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 8)
            }
            footer
        }
        .frame(width: size.width, height: size.height)
        .background(Theme.background).foregroundStyle(Theme.text)
        .interactiveDismissDisabled(isApplying)
        .task { searchFocused = true
            await model.load()
        }
        .onChange(of: model.mode) { _, mode in onModeChange?(mode) }
        .onChange(of: model.query) { _, _ in compactDetails = false
            actionError = nil
        }
        .onChange(of: model.group) { _, _ in compactDetails = false
            actionError = nil
        }
        .onDisappear { actionTask?.cancel()
            refreshTask?.cancel()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                if let onBack {
                    Button(action: onBack) {
                        HStack(spacing: 5) {
                            PhosphorIcon(name: "arrow-left", size: 12)
                            Text(L10n.text("Your writing")).font(.system(size: 11))
                        }.foregroundStyle(Theme.secondary)
                    }.buttonStyle(.plain).disabled(isApplying)
                        .accessibilityIdentifier("universe.back-library")
                }
                Text(L10n
                    .text(model
                        .mode == .templates ? "A starting point for your ideas" : "More ways to express an idea"))
                    .font(.system(size: size.width < 760 ? 23 : 27, weight: .medium, design: .serif))
                Text(L10n
                    .text(model
                        .mode == .templates ? "Start with a complete document, then make it yours." :
                        "Find a tool by what you want to make."))
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
            QuietButton(icon: "x", help: L10n.text("Close discovery"), shortcut: "Esc") {
                close()
            }
            .keyboardShortcut(.cancelAction).disabled(isApplying)
        }.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 22)
    }

    private var searchAndFilters: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 22) {
                HStack(spacing: 4) {
                    intentButton(.templates, title: "Templates", icon: "file-text")
                    intentButton(.packages, title: "Packages", icon: "package")
                }.padding(3).background(Theme.editor, in: RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 9) {
                    PhosphorIcon(name: "magnifying-glass", size: 16).foregroundStyle(Theme.muted)
                    TextField(
                        L10n
                            .text(model
                                .mode == .templates ? "Find a resume, paper, presentation…" :
                                "Try diagrams, plots, code blocks…"),
                        text: $model.query,
                    )
                    .textFieldStyle(.plain).focused($searchFocused).accessibilityIdentifier("universe.search")
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: {
                            PhosphorIcon(name: "x", size: 12).foregroundStyle(Theme.secondary)
                        }
                        .buttonStyle(.plain).accessibilityLabel(L10n.text("Clear search"))
                    }
                }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 36)
                    .background(Theme.editor, in: RoundedRectangle(cornerRadius: 7))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(UniverseDiscoveryGroup.groups(for: model.mode)) { group in
                        Button { model.group = group.id
                            model.selectedID = nil
                        } label: {
                            HStack(spacing: 6) {
                                PhosphorIcon(name: group.symbolName, size: 14)
                                Text(group.title).font(.system(
                                    size: 11,
                                    weight: model.group == group.id ? .medium : .regular,
                                ))
                            }.foregroundStyle(model.group == group.id ? Theme.text : Theme.secondary)
                                .padding(.horizontal, 11).frame(height: 30)
                                .background(model.group == group.id ? Theme.border.opacity(0.7) : .clear, in: Capsule())
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("universe.group.\(group.id)")
                    }
                }
            }
        }.padding(.horizontal, 28).padding(.bottom, 18)
    }

    private func intentButton(_ mode: UniverseDiscoveryMode, title: String, icon: String) -> some View {
        Button { model.changeMode(mode)
            compactDetails = false
            actionError = nil
        } label: {
            HStack(spacing: 6) {
                PhosphorIcon(name: icon, size: 14)
                Text(L10n.text(title)).font(.system(size: 12, weight: .medium))
            }.foregroundStyle(model.mode == mode ? Theme.text : Theme.muted)
                .padding(.horizontal, 12).frame(height: 30)
                .background(
                    model.mode == mode ? Theme.border.opacity(0.6) : .clear,
                    in: RoundedRectangle(cornerRadius: 6),
                )
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("universe.mode.\(mode == .templates ? "templates" : "packages")")
    }

    private var catalog: some View {
        let results = model.results
        let showSample = onAddSample != nil && model.mode == .templates && model.group.isEmpty && SampleBook.sicp
            .matches(model.query)
        let builtIns = onCreateBuiltIn != nil && model.mode == .templates && model.group.isEmpty
            ? BuiltInTemplate.allCases.filter { $0.matches(model.query) } : []
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !builtIns.isEmpty || showSample {
                    HStack {
                        Text(L10n.text("From LeftBlank")).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.secondary)
                        Spacer()
                        if builtIns.contains(.blank) {
                            Button { apply(.blank) } label: {
                                HStack(spacing: 6) {
                                    PhosphorIcon(name: "file-plus", size: 14)
                                    Text(BuiltInTemplate.blank.title).font(.system(size: 11, weight: .medium))
                                    PhosphorIcon(name: "arrow-right", size: 12)
                                }.foregroundStyle(Theme.secondary).padding(.horizontal, 12).frame(height: 30)
                                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("universe.builtin.blank")
                                .learningHelp(L10n.text("Start with a blank page"))
                        }
                    }
                    if size.width >= 920, model.selected == nil {
                        HStack(alignment: .top, spacing: 16) {
                            starterCards(builtIns: builtIns, showSample: showSample, compact: true)
                        }
                    } else {
                        VStack(spacing: 12) { starterCards(builtIns: builtIns, showSample: showSample, compact: false) }
                    }
                }
                if !results.isEmpty, !builtIns.isEmpty || showSample {
                    Text(L10n.text("From the community")).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 174, maximum: 260), spacing: 18)],
                    alignment: .leading,
                    spacing: 22,
                ) {
                    ForEach(results) { package in
                        Button {
                            catalogPosition = package.id
                            model.selectedID = package.id
                            compactDetails = true
                            actionError = nil
                        } label: { card(package) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(package.name + ", " + package.description)
                            .accessibilityIdentifier("universe.result.\(package.name)")
                    }
                }.scrollTargetLayout()
            }.padding(24)
        }
        // Track a card, not a pixel offset: opening details changes both the
        // grid columns and starter height. The chosen card must stay in view.
        .scrollPosition(id: $catalogPosition)
        .overlay {
            if results.isEmpty, !showSample, builtIns.isEmpty {
                VStack(spacing: 12) {
                    if model.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        PhosphorIcon(name: "magnifying-glass", size: 26).foregroundStyle(Theme.muted)
                    }
                    Text(L10n.text(model.isLoading ? "Finding possibilities…" : "No matches yet"))
                        .font(.system(size: 17, design: .serif)).foregroundStyle(Theme.secondary)
                    if !model.isLoading {
                        Text(L10n.text("Try a shorter phrase or another collection."))
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                }.multilineTextAlignment(.center).padding(24)
            }
        }
    }

    @ViewBuilder
    private func starterCards(builtIns: [BuiltInTemplate], showSample: Bool, compact: Bool) -> some View {
        if builtIns.contains(.welcome) {
            BuiltInTemplateCard(template: .welcome, isCreating: isApplying, compact: compact) { apply(.welcome) }
                .frame(maxWidth: .infinity)
        }
        if showSample {
            SampleBookCard(isAdding: isApplying, compact: compact) {
                guard !isApplying, let onAddSample else {
                    return
                }
                isApplying = true
                actionError = nil
                actionTask = Task {
                    defer { isApplying = false }
                    do { try await onAddSample(.sicp)
                        close()
                    } catch where Task.isCancelled {}
                    catch is CancellationError {}
                    catch { actionError = error.localizedDescription }
                }
            }.frame(maxWidth: .infinity)
        }
    }

    private func card(_ package: UniversePackage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if package.isTemplate {
                UniversePreview(package: package, cacheURL: previewCacheURL)
                    .id(model.previewGeneration)
                    .frame(height: 180).frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(
                        model.selected?.id == package.id ? Theme.accent.opacity(0.75) : Theme.border.opacity(0.5),
                        lineWidth: 1,
                    ))
            } else {
                HStack(alignment: .top) {
                    PhosphorIcon(name: packageIcon(package), size: 22)
                        .foregroundStyle(model.selected?.id == package.id ? Theme.accent : Theme.secondary)
                    Spacer()
                    PhosphorIcon(name: "arrow-up-right", size: 13).foregroundStyle(Theme.muted)
                }.padding(.bottom, 7)
            }
            Text(package.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
            Text(package.description).font(.system(size: 11)).lineSpacing(3).foregroundStyle(Theme.secondary)
                .lineLimit(2).frame(height: 33, alignment: .topLeading)
        }.padding(package.isTemplate ? 0 : 16).frame(maxWidth: .infinity, alignment: .leading)
            .background(
                package.isTemplate ? .clear : (model.selected?.id == package.id ? Theme.panel : Theme.editor),
                in: RoundedRectangle(cornerRadius: 8),
            )
            .overlay {
                if !package.isTemplate {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(
                        model.selected?.id == package.id ? Theme.accent.opacity(0.6) : .clear,
                        lineWidth: 1,
                    )
                }
            }
            .contentShape(Rectangle())
    }

    private func details(_ package: UniversePackage, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { compactDetails = false
                    model.selectedID = nil
                } label: {
                    HStack(spacing: 6) {
                        PhosphorIcon(name: "arrow-left", size: 14)
                        Text(L10n.text("Back to results")).font(.system(size: 12))
                    }.foregroundStyle(Theme.secondary)
                }.buttonStyle(.plain).accessibilityIdentifier("universe.back-results")
                Spacer()
            }.padding(.horizontal, 24).padding(.top, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    if package.isTemplate {
                        UniversePreview(package: package, cacheURL: previewCacheURL)
                            .id(model.previewGeneration)
                            .frame(height: compact ? 240 : 175).frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text(package.name).font(.system(size: 25, weight: .medium, design: .serif))
                            .textSelection(.enabled)
                        Text(L10n.format("Version %@", package.version)).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.muted)
                    }
                    Text(package.description).font(.system(size: 12)).lineSpacing(5).foregroundStyle(Theme.secondary)
                        .textSelection(.enabled)
                    if !package.isTemplate {
                        Text("#import \"\(package.reference)\"")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.accent)
                            .textSelection(.enabled)
                            .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.editor, in: RoundedRectangle(cornerRadius: 6))
                    }
                    Text(L10n
                        .text(package
                            .isTemplate ?
                            "Includes the document and its assets. First use may download packages. Your copy is independent." :
                            "Adds a pinned import to your document. Open the documentation for examples and setup."))
                        .font(.system(size: 11)).lineSpacing(4).foregroundStyle(Theme.muted)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.format("License  %@", package.license))
                        if !package.authors.isEmpty {
                            Text(package.authors.joined(separator: " · ")).lineLimit(3)
                        }
                    }.font(.system(size: 10)).foregroundStyle(Theme.muted)
                    if !package.isCompatible(with: compilerVersion) {
                        Text(L10n.format(
                            "The current engine is Typst %@. This package requires a newer version.",
                            compilerVersion,
                        ))
                        .font(.system(size: 11)).foregroundStyle(Theme.accent)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
            VStack(alignment: .leading, spacing: 13) {
                if !package.isTemplate, !canImport {
                    Text(L10n.text("Open a document to add packages.")).font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                }
                Button { apply(package) } label: {
                    HStack(spacing: 8) {
                        if isApplying {
                            ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 14, height: 14)
                        } else {
                            PhosphorIcon(name: package.isTemplate ? "file-plus" : "plus-circle", size: 16)
                        }
                        Text(L10n
                            .text(isApplying ? "Preparing your document…" :
                                (package.isTemplate ? "Create document" : "Insert import")))
                            .font(.system(size: 12, weight: .medium))
                    }.frame(maxWidth: .infinity).frame(height: 37)
                        .background(Theme.text, in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(Theme.background)
                }.buttonStyle(.plain)
                    .disabled(isApplying || !package
                        .isCompatible(with: compilerVersion) || (package.isTemplate && onCreate == nil) ||
                        (!package.isTemplate && !canImport))
                    .accessibilityIdentifier(package.isTemplate ? "universe.create" : "universe.import")
                Link(destination: package.documentationURL) {
                    HStack(spacing: 5) {
                        Text(L10n.text("Documentation"))
                        PhosphorIcon(name: "arrow-up-right", size: 11)
                    }.font(.system(size: 11)).foregroundStyle(Theme.secondary).frame(maxWidth: .infinity)
                }
            }.padding(24).padding(.top, -4)
        }.background(Theme.editor.opacity(0.35))
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.border.opacity(0.45)).frame(height: 1)
            HStack(spacing: 10) {
                if model.isLoading {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
                }
                Text(model.statusText).font(.system(size: 10))
                    .foregroundStyle(model.error == nil || model.snapshot != nil ? Theme.muted : Theme.red)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                if isApplying {
                    Button(L10n.text("Cancel")) { actionTask?.cancel() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        .accessibilityIdentifier("universe.cancel-download")
                }
                Text("Typst Universe").font(.system(size: 10)).foregroundStyle(Theme.muted)
                QuietButton(icon: "arrow-clockwise", help: L10n.text("Refresh Index"), shortcut: "⌘R") {
                    refreshTask = Task { await model.load(forceRefresh: true) }
                }.keyboardShortcut("r", modifiers: .command).disabled(model.isLoading || isApplying)
            }.padding(.horizontal, 24).frame(height: 44)
        }
    }

    private static let featuredPackageIcons = [
        "cetz": "pencil-simple", "fletcher": "tree-structure", "lilaq": "wave-sine",
        "codly": "code", "tablex": "table", "glossarium": "book-open-text", "physica": "function",
    ]

    private func packageIcon(_ package: UniversePackage) -> String {
        if let icon = Self.featuredPackageIcons[package.name] {
            return icon
        }
        if package.categories.contains("visualization") {
            return "bounding-box"
        }
        if package.categories.contains("text") || package.categories.contains("languages") {
            return "text-aa"
        }
        if package.categories.contains("layout") {
            return "layout"
        }
        if package.categories.contains("scripting") || package.categories.contains("integration") {
            return "code"
        }
        if package.categories.contains("model") {
            return "tree-structure"
        }
        return "package"
    }

    private func close() {
        // Inline discovery lives in the main window; dismissing that window
        // would close the document that the action just opened.
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private func apply(_ template: BuiltInTemplate) {
        guard !isApplying, let onCreateBuiltIn else {
            return
        }
        isApplying = true
        actionError = nil
        actionTask = Task {
            defer { isApplying = false }
            do { try await onCreateBuiltIn(template)
                close()
            } catch where Task.isCancelled {}
            catch is CancellationError {}
            catch { actionError = error.localizedDescription }
        }
    }

    private func apply(_ package: UniversePackage) {
        guard !isApplying else {
            return
        }
        actionError = nil
        if package.isTemplate {
            guard let onCreate else {
                return
            }
            isApplying = true
            actionTask = Task { @MainActor in
                defer { isApplying = false }
                do { try await onCreate(package)
                    close()
                } catch where Task.isCancelled {}
                catch is CancellationError {}
                catch { actionError = error.localizedDescription }
            }
        } else {
            do { try onImport(package)
                close()
            } catch { actionError = error.localizedDescription }
        }
    }
}

/// Sheets fit inside smaller writing windows while giving visual discovery room
/// on larger displays. The catalog changes to a single-pane route below 850 pt.
@MainActor
enum DiscoveryLayout {
    static func size(for window: NSWindow?, gallery: Bool = true) -> CGSize {
        let available = window?.contentLayoutRect.size ?? CGSize(width: 1200, height: 820)
        return CGSize(
            width: min(gallery ? 1040 : 980, max(620, available.width - 48)),
            height: min(gallery ? 720 : 680, max(510, available.height - 52)),
        )
    }
}
