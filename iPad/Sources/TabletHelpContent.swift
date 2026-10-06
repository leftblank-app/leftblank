import LeftBlankCore
import PDFKit
import SwiftUI
import UIKit

/// iPad uses a separate embedded LSP session, never a subprocess or the manuscript's session.
@MainActor
final class TabletExampleRenderer {
    private var cache: [HoverExample: UIImage] = [:]

    func image(for example: HoverExample, directory: URL, packageCache: URL) async -> UIImage? {
        if let image = cache[example] {
            return image
        }
        guard !Task.isCancelled else {
            return nil
        }
        let root = directory.appendingPathComponent(UUID().uuidString)
        let client = TinymistClient(makeTransport: { EmbeddedTinymist() })
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            client.stop()
        }
        defer {
            timeout.cancel()
            client.stop()
            try? FileManager.default.removeItem(at: root)
        }
        return await withTaskCancellationHandler {
            do {
                let input = try example.writePreview(in: root)
                let exports = root.appendingPathComponent("Exports")
                try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
                try await client.start(
                    root: root,
                    outputDirectory: exports,
                    fontPaths: [EmbeddedTinymist.fontCacheURL],
                    packageCache: packageCache,
                )
                try Task.checkCancellation()
                try client.open(input, text: String(contentsOf: input, encoding: .utf8), version: 1)
                let result = try await client.command("tinymist.exportPdf", arguments: [input.path])
                try Task.checkCancellation()
                guard let path = result["path"].string else {
                    return nil
                }
                let output = URL(fileURLWithPath: path)
                guard output.standardizedFileURL.path.hasPrefix(exports.standardizedFileURL.path + "/"),
                      let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 5_000_000,
                      let pdf = PDFDocument(url: output), let page = pdf.page(at: 0)
                else {
                    return nil
                }
                let image = withExtendedLifetime(pdf) {
                    page.thumbnail(of: CGSize(width: 660, height: 320), for: .mediaBox)
                }
                if cache.count >= 16 {
                    cache.removeAll()
                }
                cache[example] = image
                return image
            } catch { return nil }
        } onCancel: {
            Task { @MainActor in client.stop() }
        }
    }
}

struct TabletHelpContent: View {
    let help: LanguageHover
    let workspace: TabletWorkspace
    @State private var showExample = true
    @State private var image: UIImage?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if help.example != nil {
                Picker(L10n.text("Writing Assistance"), selection: $showExample) {
                    Text(L10n.text("Explanation")).tag(false)
                    Text(L10n.text("Example")).tag(true)
                }.pickerStyle(.segmented)
            }
            if showExample, let example = help.example {
                Text(example.displaySource).font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(TabletTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 180)
                        .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel(L10n.text("Rendered example"))
                        .accessibilityIdentifier("help-example-preview")
                } else if loading {
                    ProgressView(L10n.text("Rendering example…"))
                } else {
                    Text(L10n.text("This example cannot be previewed on its own. See its documentation."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                if let signature = help.signature {
                    Text(signature).font(.system(.caption, design: .monospaced)).foregroundStyle(TabletTheme.accent)
                }
                if !help.documentation.isEmpty {
                    Text(help.documentation).font(.callout)
                }
            }
            if let url = help.documentationURL {
                Link(L10n.text("View Typst documentation"), destination: url).font(.caption)
            }
        }
        .task(id: help.example) {
            image = nil
            loading = true
            if let example = help.example {
                let rendered = await workspace.exampleRenderer.image(
                    for: example, directory: workspace.stateDirectory.appendingPathComponent("HoverExamples"),
                    packageCache: workspace.packageCache,
                )
                guard !Task.isCancelled else {
                    return
                }
                image = rendered
            }
            loading = false
        }
    }
}
