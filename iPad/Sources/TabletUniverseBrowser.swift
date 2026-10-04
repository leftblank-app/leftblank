import ImageIO
import LeftBlankCore
import SwiftUI

/// The platform supplies layout and image decoding; discovery and caching are shared with Mac.
struct TabletUniverseBrowser: View {
    @ObservedObject var workspace: TabletWorkspace
    @StateObject private var model = UniverseBrowserModel(
        store: UniverseCatalogStore(cacheURL: AppDistribution.defaultStateDirectory
            .appendingPathComponent("Universe.json")),
        mode: .templates,
    )
    @FocusState private var searchFocused: Bool
    private let previewCache = AppDistribution.defaultStateDirectory.appendingPathComponent("UniversePreviews")

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 1000 && geometry.size.width > geometry.size.height
            HStack(spacing: 0) {
                if wide || model.selected == nil {
                    VStack(spacing: 0) {
                        header(width: geometry.size.width - (model.selected == nil ? 0 : 360))
                        collections
                        catalog
                        footer
                    }.frame(maxWidth: .infinity)
                }
                if let package = model.selected {
                    if wide {
                        Rectangle().fill(TabletTheme.border).frame(width: 0.5)
                    }
                    details(package, compact: !wide)
                        .frame(width: wide ? 360 : nil)
                }
            }
        }.background(TabletTheme.background).disabled(workspace.busy)
            .task { await model.load() }
    }

    private func header(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n
                    .text(model
                        .mode == .templates ? "A starting point for your ideas" : "More ways to express an idea"))
                    .font(.system(size: 23, weight: .medium, design: .serif))
                Text(L10n.text(model.mode == .templates ? "Start with a complete document, then make it yours." :
                        "Find a tool by what you want to make."))
                    .font(.system(size: 12)).foregroundStyle(TabletTheme.secondary)
            }
            if width >= 720 {
                HStack(spacing: 20) {
                    modePicker.frame(width: 300)
                    search
                }
            } else {
                VStack(spacing: 10) {
                    modePicker
                    search
                }
            }
        }.padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)
    }

    private var modePicker: some View {
        Picker(L10n.text("Templates & Packages"), selection: Binding(
            get: { model.mode }, set: { model.changeMode($0) },
        )) {
            Text(L10n.text("New document")).tag(UniverseDiscoveryMode.templates)
            Text(L10n.text("Writing tools")).tag(UniverseDiscoveryMode.packages)
        }.pickerStyle(.segmented).frame(minHeight: 44).accessibilityIdentifier("universe-mode")
    }

    private var search: some View {
        HStack(spacing: 10) {
            TabletIcon(name: "magnifying-glass", size: 16).foregroundStyle(TabletTheme.secondary)
            TextField(L10n.text(model.mode == .templates ? "Find a resume, paper, presentation…" :
                    "Try diagrams, plots, code blocks…"), text: $model.query)
                .font(.system(size: 14)).textFieldStyle(.plain)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .focused($searchFocused).submitLabel(.search).onSubmit { searchFocused = false }
                .accessibilityIdentifier("universe.search")
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    TabletIcon(name: "x", size: 14).frame(width: 44, height: 44)
                }.buttonStyle(.plain).foregroundStyle(TabletTheme.secondary)
                    .accessibilityLabel(L10n.text("Clear search"))
                    .accessibilityIdentifier("universe.clear-search")
            }
        }.padding(.leading, 14).padding(.trailing, model.query.isEmpty ? 14 : 0).frame(minHeight: 44)
            .background(Color(uiColor: TabletTheme.nativeEditor), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(TabletTheme.border, lineWidth: 0.5) }
    }

    private var collections: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(UniverseDiscoveryGroup.groups(for: model.mode)) { group in
                    Button { model.group = group.id } label: {
                        HStack(spacing: 6) {
                            TabletIcon(name: group.symbolName, size: 14)
                            Text(group.title).font(.system(size: 12, weight: .medium))
                        }.padding(.horizontal, 12).frame(minHeight: 44)
                            .background(
                                model.group == group.id ? TabletTheme.accent.opacity(0.1) : .clear,
                                in: RoundedRectangle(cornerRadius: 8),
                            )
                    }.buttonStyle(.plain)
                        .foregroundStyle(model.group == group.id ? TabletTheme.accent : TabletTheme.secondary)
                }
            }.padding(.horizontal, 24)
        }
    }

    private var catalog: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                let builtIn = model.group.isEmpty ? BuiltInTemplate.allCases.filter { $0.matches(model.query) } : []
                let showSample = model.group.isEmpty && SampleBook.sicp.matches(model.query)
                if model.mode == .templates, !builtIn.isEmpty || showSample {
                    Text(L10n.text("From LeftBlank")).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                        ForEach(builtIn) { template in
                            Button { Task { await workspace.create(template) } } label: {
                                HStack(spacing: 10) {
                                    TabletIcon(name: template == .blank ? "file-plus" : "book-open-text")
                                    Text(template.title).font(.system(size: 13, weight: .medium))
                                    Spacer(minLength: 0)
                                    TabletIcon(name: "arrow-right", size: 14)
                                }.padding(14).frame(minHeight: 72).background(
                                    Color(uiColor: TabletTheme.nativeEditor),
                                    in: RoundedRectangle(cornerRadius: 10),
                                )
                            }.buttonStyle(.plain)
                                .disabled(workspace.subscription.access == .checking)
                                .accessibilityIdentifier("universe.builtin." + template.rawValue)
                        }
                        if showSample {
                            Button { Task {
                                await workspace.addSampleBook()
                            } } label: {
                                HStack(spacing: 10) {
                                    TabletIcon(name: "books")
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("SICP").font(.system(size: 13, weight: .medium))
                                        Text(SampleBook.sicp.title).font(.system(size: 11))
                                            .foregroundStyle(TabletTheme.secondary).lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                    TabletIcon(name: "arrow-right", size: 14)
                                }.padding(14).frame(minHeight: 72)
                                    .background(
                                        Color(uiColor: TabletTheme.nativeEditor),
                                        in: RoundedRectangle(cornerRadius: 10),
                                    )
                            }.buttonStyle(.plain).accessibilityIdentifier("universe.builtin.sicp")
                        }
                    }
                }
                Text(L10n.text("From the community")).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: model.mode == .templates ? 190 : 240), spacing: 16)],
                    alignment: .leading,
                    spacing: 20,
                ) {
                    ForEach(model.results) { package in
                        Button {
                            searchFocused = false
                            model.selectedID = package.id
                        } label: {
                            card(package)
                        }.buttonStyle(.plain).accessibilityIdentifier("universe.result." + package.name)
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(
                                        model.selectedID == package.id ? TabletTheme.accent : .clear,
                                        lineWidth: 1.5,
                                    )
                            }
                    }
                }
                if model.results.isEmpty, !model.isLoading {
                    TabletEmptyState(title: L10n.text("No matches yet"), icon: "magnifying-glass")
                        .frame(minHeight: 160)
                }
            }.padding(24)
        }.scrollDismissesKeyboard(.interactively).refreshable { await model.load(forceRefresh: true) }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
            Text(model.statusText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
            Button { Task { await model.load(forceRefresh: true) } } label: {
                TabletIcon(name: "arrow-clockwise", size: 16).frame(width: 44, height: 44)
            }.disabled(model.isLoading).accessibilityLabel(L10n.text("Refresh Index"))
                .accessibilityIdentifier("universe-refresh")
        }.padding(.horizontal, 16)
            .overlay(alignment: .top) { Rectangle().fill(TabletTheme.border).frame(height: 0.5) }
    }

    private func card(_ package: UniversePackage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if package.isTemplate {
                TabletUniverseThumbnail(package: package, cacheURL: previewCache)
                    .id("\(package.reference)-\(model.previewGeneration)")
                    .aspectRatio(0.75, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                HStack {
                    TabletIcon(name: "package", size: 24).foregroundStyle(TabletTheme.accent)
                    Spacer()
                    TabletIcon(name: "arrow-up-right", size: 14).foregroundStyle(TabletTheme.secondary)
                }.padding(.bottom, 4)
            }
            Text(package.name).font(.system(size: 14, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
            Text(package.description).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                .frame(height: 34, alignment: .topLeading)
            Text(package.version).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }.padding(package.isTemplate ? 0 : 14).frame(maxWidth: .infinity, alignment: .leading)
            .background(
                package.isTemplate ? .clear : Color(uiColor: TabletTheme.nativeEditor),
                in: RoundedRectangle(cornerRadius: 10),
            )
            .accessibilityElement(children: .combine)
    }

    private func details(_ package: UniversePackage, compact: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.selectedID = nil } label: {
                    HStack(spacing: 8) {
                        TabletIcon(name: compact ? "arrow-left" : "x", size: 16)
                        Text(L10n.text("Back to results")).font(.system(size: 12, weight: .medium))
                    }.frame(minHeight: 44)
                }.buttonStyle(.plain).foregroundStyle(TabletTheme.secondary)
                    .accessibilityIdentifier("universe.back-results")
                Spacer()
            }.padding(.horizontal, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if package.isTemplate {
                        detailPreview(package).frame(height: compact ? 280 : 220)
                            .frame(maxWidth: .infinity)
                    }
                    metadata(package)
                }.padding(24).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
            }
            actions(package)
        }.background(TabletTheme.background)
    }

    private func detailPreview(_ package: UniversePackage) -> some View {
        TabletUniverseThumbnail(package: package, cacheURL: previewCache)
            .aspectRatio(0.75, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("universe.detail-preview")
    }

    private func metadata(_ package: UniversePackage) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(package.name).font(.system(size: 28, weight: .medium, design: .serif))
                Text(L10n.format("Version %@", package.version)).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(TabletTheme.secondary)
            }
            Text(package.description).font(.system(size: 14)).lineSpacing(4).foregroundStyle(TabletTheme.secondary)
            Text(package.isTemplate ? package.reference : "#import \"\(package.reference)\"")
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(TabletTheme.accent)
                .textSelection(.enabled).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: TabletTheme.nativeEditor), in: RoundedRectangle(cornerRadius: 8))
            Text(L10n.text(package.isTemplate ?
                    "Includes the document and its assets. First use may download packages. Your copy is independent." :
                    "Adds a pinned import to your document. Open the documentation for examples and setup."))
                .font(.system(size: 12)).lineSpacing(4).foregroundStyle(TabletTheme.secondary)
            LabeledContent(L10n.text("Authors"), value: package.authors.joined(separator: ", "))
            LabeledContent(L10n.text("License"), value: package.license)
            if !package.isCompatible(with: "0.15.1"), let compiler = package.compiler {
                Text(L10n.format("Requires Typst %@ or later", compiler)).foregroundStyle(.orange)
            }
        }.font(.system(size: 12)).accessibilityIdentifier("universe.detail-metadata")
    }

    private func actions(_ package: UniversePackage) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(TabletTheme.border).frame(height: 0.5)
            VStack(spacing: 8) {
                applyButton(package)
                documentation(package)
            }.font(.system(size: 13, weight: .medium)).padding(.horizontal, 24).padding(.vertical, 14)
        }.background(TabletTheme.background)
    }

    private func documentation(_ package: UniversePackage) -> some View {
        Link(destination: package.documentationURL) {
            HStack(spacing: 6) {
                Text(L10n.text("Documentation"))
                TabletIcon(name: "arrow-up-right", size: 14)
            }.frame(minHeight: 44)
        }.foregroundStyle(TabletTheme.secondary)
    }

    private func applyButton(_ package: UniversePackage) -> some View {
        Button {
            if package.isTemplate {
                Task { await workspace.createTemplate(package) }
            } else {
                workspace.addPackage(package)
            }
        } label: {
            HStack(spacing: 8) {
                TabletIcon(name: package.isTemplate ? "file-plus" : "plus-circle", size: 16)
                Text(L10n.text(package.isTemplate ? "Use Template" : "Insert Import"))
            }.padding(.horizontal, 18).frame(maxWidth: .infinity, minHeight: 44)
                .background(TabletTheme.accent, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(Color(uiColor: TabletTheme.nativeBackground))
        }.buttonStyle(.plain)
            .disabled(workspace.busy || !package.isCompatible(with: "0.15.1") ||
                (!package.isTemplate && workspace.document == nil))
            .accessibilityIdentifier("universe.apply")
    }
}

private struct TabletUniverseThumbnail: View {
    let package: UniversePackage
    let cacheURL: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(8)
            } else {
                VStack(spacing: 10) {
                    TabletIcon(name: "file-text", size: 28).foregroundStyle(TabletTheme.secondary)
                    Text(L10n.text("Preview unavailable")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }.accessibilityHidden(true).task(id: package.thumbnailURL) {
            guard let url = package.thumbnailURL else {
                return
            }
            if let cached = TabletUniverseImages.cache.object(forKey: url as NSURL) {
                image = cached
                return
            }
            guard let data = await UniversePreviewLoader.shared.data(for: url, cacheURL: cacheURL),
                  !Task.isCancelled
            else {
                return
            }
            let thumbnail = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                    return nil
                }
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                kCGImageSourceThumbnailMaxPixelSize: 600,
                                                kCGImageSourceCreateThumbnailWithTransform: true,
                                                kCGImageSourceShouldCacheImmediately: true]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }.value
            guard let thumbnail, !Task.isCancelled else {
                return
            }
            let result = UIImage(cgImage: thumbnail)
            TabletUniverseImages.cache.setObject(
                result,
                forKey: url as NSURL,
                cost: thumbnail.bytesPerRow * thumbnail.height,
            )
            image = result
        }
    }
}

@MainActor private enum TabletUniverseImages {
    static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 40
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()
}
