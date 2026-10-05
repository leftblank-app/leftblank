import AppKit
import LeftBlankCore
import PDFKit

@MainActor
final class HoverExamplePreview: ObservableObject {
    @Published var image: NSImage?
    @Published var loading = true
}

/// A separate, bounded compile cannot change the manuscript's LSP or preview task.
@MainActor
final class HoverExampleRenderer {
    private enum Cached { case image(NSImage), unavailable }
    private var cache: [HoverExample: Cached] = [:]

    func image(for example: HoverExample, directory: URL, packageCache: URL) async -> NSImage? {
        if let cached = cache[example] {
            if case let .image(image) = cached {
                return image
            }
            return nil
        }
        guard !Task.isCancelled else {
            return nil
        }
        let image = await compile(example, directory: directory, packageCache: packageCache)
        guard !Task.isCancelled else {
            return nil
        }
        if cache.count >= 16 {
            cache.removeAll()
        }
        cache[example] = image.map(Cached.image) ?? .unavailable
        return image
    }

    private func compile(_ example: HoverExample, directory: URL, packageCache: URL) async -> NSImage? {
        guard let binary = TinymistClient.binaryURL else {
            return nil
        }
        let root = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let input = try example.writePreview(in: root)
            let output = root.appendingPathComponent("example.pdf")
            let process = Process()
            process.executableURL = binary
            process.currentDirectoryURL = root
            process.arguments = ["compile", "--root", root.path, "--pages", "1",
                                 "--package-path", root.appendingPathComponent("local-packages").path,
                                 "--package-cache-path", packageCache.path, input.path, output.path]
            if let font = TinymistClient.bundledFontURL {
                process.arguments?.insert(contentsOf: ["--font-path", font.deletingLastPathComponent().path], at: 1)
            }
            // Examples can use cached packages, but hovering must not start downloads.
            var environment = ProcessInfo.processInfo.environment
            for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] {
                environment[key] = "http://127.0.0.1:9"
            }
            environment["NO_PROXY"] = ""
            environment["no_proxy"] = ""
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard await HoverCompilation(process: process).run(), !Task.isCancelled,
                  let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 5_000_000,
                  let pdf = PDFDocument(url: output), let page = pdf.page(at: 0)
            else {
                return nil
            }
            // Rasterize only a bounded thumbnail, even if the example sets a huge page.
            return page.thumbnail(of: NSSize(width: 660, height: 320), for: .mediaBox)
        } catch { return nil }
    }
}

@MainActor
final class HoverCompilation {
    let process: Process
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeout: Task<Void, Never>?
    private var termination: Task<Void, Never>?
    private var stopped = false

    init(process: Process) {
        self.process = process
    }

    func run() async -> Bool {
        guard !Task.isCancelled else {
            return false
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                process.terminationHandler = { [weak self] process in
                    let status = process.terminationStatus
                    Task { @MainActor [weak self] in self?.finish(status == 0) }
                }
                do { try process.run() } catch { finish(false)
                    return
                }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    self?.stop()
                }
            }
        } onCancel: {
            Task { @MainActor in self.stop() }
        }
    }

    private func stop() {
        guard !stopped else {
            return
        }
        stopped = true
        guard process.isRunning else {
            return
        }
        process.terminate()
        termination = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, process.isRunning else {
                return
            }
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func finish(_ success: Bool) {
        timeout?.cancel()
        termination?.cancel()
        process.terminationHandler = nil
        continuation?.resume(returning: success && !stopped)
        continuation = nil
    }
}
