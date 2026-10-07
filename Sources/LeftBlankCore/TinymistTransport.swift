import Foundation

/// Both native platforms speak the same framed LSP. Only engine startup differs.
@MainActor
public protocol TinymistTransport: AnyObject {
    var input: FileHandle { get }
    var output: FileHandle { get }
    var errorOutput: FileHandle? { get }
    var isRunning: Bool { get }
    var onExit: (@MainActor (Int32) -> Void)? { get set }
    func start(root: URL) throws
    func stop()
}

#if os(macOS)
    @MainActor
    final class ProcessTinymistTransport: TinymistTransport {
        private let process = Process()
        private let stdin = Pipe()
        private let stdout = Pipe()
        private let stderr = Pipe()
        private let executable: URL?
        private let arguments: [String]
        private let killGracePeriod: Duration
        var onExit: (@MainActor (Int32) -> Void)?

        /// Tests substitute a stand-in executable; the app always launches `tinymist lsp`.
        init(executable: URL? = nil, arguments: [String] = ["lsp"], killGracePeriod: Duration = .seconds(2)) {
            self.executable = executable
            self.arguments = arguments
            self.killGracePeriod = killGracePeriod
        }

        var input: FileHandle {
            stdin.fileHandleForWriting
        }

        var output: FileHandle {
            stdout.fileHandleForReading
        }

        var errorOutput: FileHandle? {
            stderr.fileHandleForReading
        }

        var isRunning: Bool {
            process.isRunning
        }

        static var binaryURL: URL? {
            if let override = ProcessInfo.processInfo.environment["LEFTBLANK_TINYMIST"],
               FileManager.default.isExecutableFile(atPath: override)
            {
                return URL(fileURLWithPath: override)
            }
            let candidates = [
                Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tinymist"),
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(".tools/tinymist"),
                URL(fileURLWithPath: "/opt/homebrew/bin/tinymist"), URL(fileURLWithPath: "/usr/local/bin/tinymist"),
            ]
            return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }

        func start(root: URL) throws {
            guard let binary = executable ?? Self.binaryURL else {
                throw ServiceError.unavailable
            }
            process.executableURL = binary
            process.arguments = arguments
            process.currentDirectoryURL = root
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { [weak self] process in
                let status = process.terminationStatus
                Task { @MainActor [weak self] in self?.onExit?(status) }
            }
            try process.run()
        }

        /// A replaced engine must not keep compiling in the background and compete
        /// with its successor for CPU. Ask politely, then force it after a grace period.
        func stop() {
            process.terminationHandler = nil
            guard process.isRunning else {
                return
            }
            process.terminate()
            let process = process, grace = killGracePeriod
            Task { @MainActor in
                try? await Task.sleep(for: grace)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
    }
#endif
