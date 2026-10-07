import Darwin
import Foundation
import LeftBlankCore
@testable import LeftBlankTablet
import SwiftUI
import Testing
import UIKit

/// Opt-in book benchmark for a physical iPad: copy `.typ` books into the app's
/// `Documents/Books` folder (for example with `xcrun devicectl device copy
/// to`). Drives the production editor: open, six distant jumps with hit
/// tests, and 80 mixed Latin/CJK/emoji keystrokes. Reports go to
/// `Documents/Benchmarks`. Gates: every jump shows its target, taps hit it,
/// and typing p95 stays below 100 ms in books up to 2 MB.
@Suite(.serialized, .enabled(if: !benchmarkBooks.isEmpty))
@MainActor
struct TabletLargeDocumentTests {
    @Test(arguments: benchmarkBooks)
    func bookOpensJumpsAndTypesWithinBudget(_ book: URL) async throws {
        let source = try String(contentsOf: book, encoding: .utf8)
        let name = book.deletingPathExtension().lastPathComponent
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("book-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let subscription = TabletSubscription(service: BookPurchaseService())
        await subscription.refresh()
        let workspace = TabletWorkspace(subscription: subscription, stateDirectory: root)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: TabletEditor(workspace: workspace))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            workspace.client.stop()
            window.isHidden = true
            previous?.makeKey()
            try? FileManager.default.removeItem(at: root)
        }
        var report: [String: Any] = ["book": name, "utf16": source.utf16.count, "memory_before_mib": footprint()]
        let opened = ContinuousClock.now
        let document = try await workspace.library.create(title: name, text: source)
        await workspace.open(document)
        workspace.layout = .writing
        try await waitFor { (workspace.editor as? TabletTextView)?.text.utf16.count == source.utf16.count }
        let editor = try #require(workspace.editor as? TabletTextView)
        controller.view.layoutIfNeeded()
        await editor.session?.settled()
        report["open_seconds"] = seconds(opened.duration(to: .now))
        report["memory_open_mib"] = footprint()
        let manager = try #require(editor.textLayoutManager)
        let text = source as NSString

        var jumps: [Double] = [], onTarget = 0, maximumHitError = 0
        var samples: [[String: Any]] = []
        for fraction in [0.1, 0.9, 0.5, 0.99, 0.01, 0.75] {
            let paragraph = text.paragraphRange(for: NSRange(location: Int(Double(text.length) * fraction), length: 0))
            let offset = paragraph.location + min(4, max(0, paragraph.length - 2))
            let start = ContinuousClock.now
            workspace.jump(workspace.metrics.position(at: offset))
            window.layoutIfNeeded()
            jumps.append(seconds(start.duration(to: .now)))
            try await Task.sleep(for: .milliseconds(50))
            let caret = try #require(TextKit2Geometry.caretRect(at: offset, in: manager))
            let point = CGPoint(
                x: caret.minX + 1 + editor.textContainerInset.left,
                y: caret.midY + editor.textContainerInset.top,
            )
            // What the viewport really shows, not the target's own frame.
            let shown = TextKit2Geometry.displayedRange(in: editor.containerVisibleRect(), manager: manager)
            if let shown, NSLocationInRange(offset, shown) {
                onTarget += 1
            }
            let hit = editor.closestPosition(to: point).map { editor.offset(from: editor.beginningOfDocument, to: $0) }
            maximumHitError = max(maximumHitError, abs((hit ?? -1) - offset))
            samples.append(["offset": offset, "hit": hit ?? -1, "caret_y": caret.minY,
                            "visible_y": editor.containerVisibleRect().minY,
                            "displayed": TextKit2Geometry.viewportInsertionOffset(
                                at: editor.containerVisibleRect().origin, in: manager,
                            ) ?? -1,
                            "ms": jumps.last.map { $0 * 1000 } ?? 0])
        }
        report["jump_ms"] = milliseconds(jumps)
        report["jumps_on_target"] = onTarget
        report["jump_samples"] = samples
        report["max_hit_error"] = maximumHitError

        workspace.jump(workspace.metrics.position(at: text.length / 2))
        try #require(editor.becomeFirstResponder())
        var typing: [Double] = [], cpu: [Double] = []
        for character in String(repeating: "Smooth 中文😀 input", count: 5) {
            let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let start = ContinuousClock.now
            editor.insertText(String(character))
            // The delegate hears about the insertion; then the layout pass a
            // keystroke ends with, including SwiftUI's update.
            window.layoutIfNeeded()
            typing.append(seconds(start.duration(to: .now)))
            cpu.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1e9)
            try await Task.sleep(for: .milliseconds(25))
        }
        report["typing_ms"] = milliseconds(typing)
        report["typing_thread_cpu_ms"] = milliseconds(cpu)
        report["memory_after_mib"] = footprint()
        #expect(workspace.canEditSource)
        report["inserted_editor"] = editor.text.utf16.count - source.utf16.count
        report["inserted_workspace"] = workspace.text.utf16.count - source.utf16.count
        #expect(TextIdentity.equal(workspace.text, editor.text))
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Benchmarks")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try json.write(to: output.appendingPathComponent(name + ".json"))
        print("LEFTBLANK IPAD REPORT\n" + String(decoding: json, as: UTF8.self))
        #expect(onTarget == 6)
        #expect(maximumHitError == 0)
        // The plan's gate is the 1.4 MB book (docs/visual-editing.md); larger
        // books are recorded. UIKit's own TextKit 2 viewport walk sets the floor.
        if source.utf16.count <= 2_000_000 {
            #expect(percentile(typing, 0.95) < 0.1, "Typing p95 must stay below 100 ms on iPad")
        }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(condition())
    }
}

/// A subscribed writer, so the editor accepts input.
private final class BookPurchaseService: TabletPurchaseService {
    func offering() -> SubscriptionOffering {
        .init(displayPrice: "$1", trialWeeks: nil)
    }

    func entitlement() -> SubscriptionAccess {
        .subscribed(until: Date().addingTimeInterval(3600))
    }

    func purchase() -> SubscriptionPurchaseResult {
        .cancelled
    }

    func restore() {}
    func manage(in _: UIWindowScene) {}
    func updates() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

private let benchmarkBooks: [URL] = {
    let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Books")
    return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "typ" }.sorted { $0.path < $1.path }
        // LEFTBLANK_IPAD_BOOK (TEST_RUNNER_LEFTBLANK_IPAD_BOOK for xcodebuild) picks one.
        .filter { book in
            ProcessInfo.processInfo.environment["LEFTBLANK_IPAD_BOOK"]
                .map { book.deletingPathExtension().lastPathComponent == $0 } ?? true
        }
}()

private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

private func percentile(_ values: [Double], _ quantile: Double) -> Double {
    let sorted = values.sorted()
    return sorted.isEmpty ? 0 : sorted[max(0, Int(ceil(Double(sorted.count) * quantile)) - 1)]
}

private func milliseconds(_ values: [Double]) -> [String: Double] {
    ["median": percentile(values, 0.5) * 1000, "p95": percentile(values, 0.95) * 1000,
     "max": (values.max() ?? 0) * 1000]
}

private func footprint() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}
