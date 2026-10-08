import AppKit
import Darwin
@testable import LeftBlankApp
import LeftBlankCore
import PDFKit
import Testing

extension WritingFlowTests {
    /// Opt-in: fetch the real fixture with scripts/prepare-large-document.py.
    /// This drives the production text view, native layout and real Tinymist.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LEFTBLANK_LARGE_FIXTURE"] != nil))
    func realMultiMegabyteDocumentNavigationScrollingAndTyping() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["LEFTBLANK_LARGE_FIXTURE"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let source = try #require(String(data: data, encoding: .utf8))
        #expect(data.count > 1_000_000)
        let initialMemory = physicalFootprint()
        // On macOS 15 every edit walks each text element TextKit has built
        // after it; a step that builds the whole book makes typing slow.
        let builtBefore = VisualEditorSession.paragraphsBuilt
        var built: [String: Int] = [:]
        func record(_ phase: String) {
            built[phase] = VisualEditorSession.paragraphsBuilt - builtBefore
        }
        let opened = ContinuousClock.now
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        let openTime = seconds(opened.duration(to: .now))
        for name in ["fig", "styles"] {
            let dependency = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dependency.path) {
                try FileManager.default.copyItem(at: dependency, to: app.root.appendingPathComponent(name))
            }
        }
        print("LEFTBLANK LARGE open: \(openTime)s, \(data.count) bytes")
        let editor = try #require(app.workspace.editor)
        let scroll = try #require(editor.enclosingScrollView)
        let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.visibleRect))
        let textSystem = editor.textLayoutManager == nil ? "textkit1" : "textkit2"
        var report: [String: Any] = ["bytes": data.count, "utf16": source.utf16.count, "open_seconds": openTime,
                                     "text_system": textSystem, "memory_before_mib": initialMemory,
                                     "memory_open_mib": physicalFootprint()]
        record("open")
        let serviceStarted = ContinuousClock.now
        app.workspace.startService()
        let deadline = ContinuousClock.now + .seconds(120)
        while app.workspace.syntaxSnapshot?.source != source, deadline > .now {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(app.workspace.syntaxSnapshot?.source == source, "Real semantic highlighting must finish")
        report["semantic_ready_seconds"] = seconds(serviceStarted.duration(to: .now))
        report["syntax_tokens"] = app.workspace.syntaxSnapshot?.tokens.count ?? 0
        report["memory_highlighted_mib"] = physicalFootprint()
        let codeWord = ProcessInfo.processInfo.environment["LEFTBLANK_CODE_WORD"] ?? "sum(range"
        let sum = (source as NSString).range(of: codeWord)
        #expect(sum.location != NSNotFound)
        if sum.location != NSNotFound {
            #expect(editorColor(editor, at: sum.location) == Theme.sourceFunction)
        }
        // Publishing semantic tokens precedes SwiftUI's next native layout.
        // Finish and report that initial presentation before timing navigation,
        // just as we settle the window between every subsequent jump below.
        record("highlighted")
        let presentationStart = ContinuousClock.now
        await app.layout()
        editor.prepareForPointerInteraction()
        editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
        report["initial_presentation_ms"] = seconds(presentationStart.duration(to: .now)) * 1000
        report["editor_ready_seconds"] = seconds(opened.duration(to: .now))
        var navigation: [Double] = [], hitTesting: [Double] = [], search: [Double] = []
        var jumpTimes: [Double] = [], highlightTimes: [Double] = [], layoutTimes: [Double] = []
        var navigationSamples: [[String: Double]] = []
        var jumpsOnTarget = 0, maximumHitError = 0
        let ns = source as NSString
        let offsets = [0.1, 0.9, 0.5, 0.99, 0.01, 0.75].map { fraction in
            let start = Int(Double(ns.length) * fraction)
            let range = ns.paragraphRange(for: NSRange(location: start, length: 0))
            return min(ns.length - 1, range.location + min(4, max(0, range.length - 2)))
        }
        let sampler = MainThreadSampler()
        for offset in offsets {
            let paragraphsBefore = VisualEditorSession.paragraphsBuilt
            sampler.start()
            let start = ContinuousClock.now
            app.workspace.jump(to: offset)
            jumpTimes.append(seconds(start.duration(to: .now)))
            let highlightStart = ContinuousClock.now
            editor.highlight()
            highlightTimes.append(seconds(highlightStart.duration(to: .now)))
            let layoutStart = ContinuousClock.now
            editor.prepareForPointerInteraction()
            editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
            layoutTimes.append(seconds(layoutStart.duration(to: .now)))
            navigation.append(seconds(start.duration(to: .now)))
            let profile = sampler.stop()
            let total = Int((navigation.last ?? 0) * 1000)
            let count = VisualEditorSession.paragraphsBuilt - paragraphsBefore
            print("LEFTBLANK SAMPLE jump \(offset) \(total) ms, paragraphs \(count)\n\(profile)")
            try navigationSamples.append(["offset": Double(offset), "total_ms": #require(navigation.last) * 1000,
                                          "jump_ms": #require(jumpTimes.last) * 1000,
                                          "highlight_ms": #require(highlightTimes.last) * 1000,
                                          "draw_ms": #require(layoutTimes.last) * 1000])
            #expect(editor.selectedRange().location == offset)
            await app.layout()
            let hitStart = ContinuousClock.now
            // Independently map a rendered glyph back to an insertion point,
            // and check the jump really brought it into the viewport.
            let glyph = try #require(editor.characterRect(at: offset))
            let point = NSPoint(x: glyph.minX + 1, y: glyph.midY)
            let hit = editor.characterIndexForInsertion(at: point)
            let visible = editor.visibleRect.contains(point)
            jumpsOnTarget += visible ? 1 : 0
            maximumHitError = max(maximumHitError, abs(hit - offset))
            #expect(visible, "Jump to \(offset) left \(glyph) outside \(editor.visibleRect)")
            #expect(hit == offset, "Hit \(hit), wanted \(offset), point \(point)")
            navigationSamples[navigationSamples.count - 1]["hit_error"] = Double(hit - offset)
            hitTesting.append(seconds(hitStart.duration(to: .now)))
            let searchStart = ContinuousClock.now
            let found = ns.range(
                of: ProcessInfo.processInfo.environment["LEFTBLANK_SEARCH_WORD"] ?? "Prince Andrew",
                options: [],
                range: NSRange(location: offset, length: ns.length - offset),
            )
            _ = found.location
            search.append(seconds(searchStart.duration(to: .now)))
        }
        record("jumped")
        report["jumps_on_target"] = jumpsOnTarget
        report["max_hit_error"] = maximumHitError
        report["navigation_ms"] = milliseconds(navigation)
        report["navigation_samples"] = navigationSamples
        report["jump_ms"] = milliseconds(jumpTimes)
        report["highlight_ms"] = milliseconds(highlightTimes)
        report["layout_ms"] = milliseconds(layoutTimes)
        report["hit_testing_ms"] = milliseconds(hitTesting)
        report["search_ms"] = milliseconds(search)
        var scrolling: [Double] = [], drawing: [Double] = []
        // Scrolling three screens down and back must show every line where it
        // was. TextKit 2 replaces estimated heights above the viewport while
        // scrolling and moves the clip origin with them, so compare positions
        // within the viewport; the document-coordinate shift is reported.
        let scrollStart = scroll.contentView.bounds.origin
        let anchor = try #require(editor.visibleCharacterRange()).location
        let anchorRect = try #require(editor.characterRect(at: anchor))
        let anchorInViewport = anchorRect.minY - editor.visibleRect.minY
        for index in 0 ..< 60 {
            let start = ContinuousClock.now
            let y = max(0, scroll.contentView.bounds.origin.y + (index < 30 ? 80 : -80))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            editor.prepareForPointerInteraction()
            #expect((editor.visibleCharacterRange()?.length ?? 0) > 0)
            scrolling.append(seconds(start.duration(to: .now)))
            editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
            drawing.append(seconds(start.duration(to: .now)))
        }
        let finalRect = try #require(editor.characterRect(at: anchor))
        let drift = finalRect.minY - editor.visibleRect.minY - anchorInViewport
        report["scroll_drift_pt"] = drift
        report["scroll_reestimated_pt"] = finalRect.minY - anchorRect.minY
        report["scroll_origin_shift_pt"] = scroll.contentView.bounds.origin.y - scrollStart.y
        #expect(abs(drift) < 0.5, "A line moved by \(drift) pt in the viewport after scrolling away and back")
        report["scroll_layout_ms"] = milliseconds(scrolling)
        report["scroll_draw_ms"] = milliseconds(drawing)
        record("scrolled")
        app.workspace.jump(to: offsets[2])
        editor.highlight()
        var typing: [Double] = [], typingCPU: [Double] = [], insertTimes: [Double] = [], metricTimes: [Double] = []
        var typingSamples: [[String: Any]] = []
        editor.breakUndoCoalescing()
        editor.undoManager?.beginUndoGrouping()
        // Retain the first keystroke: no warm-up samples are discarded. Eighty
        // inputs give p95 a meaningful tail instead of equating it with max.
        for character in String(repeating: "Smooth 中文😀 input", count: 5) {
            let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let start = ContinuousClock.now
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            insertTimes.append(seconds(start.duration(to: .now)))
            let metricsStart = ContinuousClock.now
            _ = app.workspace.position
            _ = app.workspace.wordCount
            metricTimes.append(seconds(metricsStart.duration(to: .now)))
            typing.append(seconds(start.duration(to: .now)))
            typingCPU.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1e9)
            try typingSamples.append([
                "index": typing.count - 1,
                "character": String(character),
                "wall_ms": #require(typing.last) * 1000,
                "thread_cpu_ms": #require(typingCPU.last) * 1000,
                "insert_ms": #require(insertTimes.last) * 1000,
                "metrics_ms": #require(metricTimes.last) * 1000,
            ])
            try await Task.sleep(for: .milliseconds(25))
        }
        record("typed")
        report["paragraphs_built"] = built
        editor.undoManager?.endUndoGrouping()
        report["typing_ms"] = milliseconds(typing)
        report["typing_samples"] = typingSamples
        report["typing_thread_cpu_ms"] = milliseconds(typingCPU)
        let budgetFailures = typingBudgetFailures(wall: typing, cpu: typingCPU)
        report["typing_budget_failures"] = budgetFailures
        #expect(budgetFailures.isEmpty, "\(budgetFailures.joined(separator: "; "))")
        #expect(try #require(navigation.max()) < 0.2, "Distant navigation including drawing must stay below 200 ms")
        #expect(built["typed", default: 0] < 5000, "TextKit built \(built) paragraphs; a step builds the whole book")
        report["insert_ms"] = milliseconds(insertTimes)
        report["metrics_ms"] = milliseconds(metricTimes)
        editor.undoManager?.undo()
        #expect(editor.string == source)
        #expect(app.workspace.text == source)
        report["memory_after_mib"] = physicalFootprint()
        report["preview_status"] = app.workspace.serviceStatus
        if ProcessInfo.processInfo.environment["LEFTBLANK_BENCH_EXPORT"] == "1" {
            let started = ContinuousClock.now
            let pdfURL = app.root.appendingPathComponent("complete-book.pdf")
            try await app.workspace.exportPDF(to: pdfURL)
            report["export_seconds"] = seconds(started.duration(to: .now))
            let pdf = try #require(PDFDocument(url: pdfURL))
            report["export_pages"] = pdf.pageCount
            #expect(pdf.pageCount > 400)
        }
        // From engine start to Tinymist's first successful compile ("Checking…" in the
        // app). Read from the operation log so measuring it does not change the run.
        report["first_compile_seconds"] = firstCompileSeconds(in: app.workspace.stateDirectory) ?? NSNull()
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let output = ProcessInfo.processInfo.environment["LEFTBLANK_PERFORMANCE_REPORT"] {
            try json.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        print("LEFTBLANK LARGE REPORT\n" + String(decoding: json, as: UTF8.self))
    }
}

private func firstCompileSeconds(in state: URL) -> Double? {
    let log = (try? String(contentsOf: state.appendingPathComponent("Logs/events.jsonl"), encoding: .utf8)) ?? ""
    for line in log.split(separator: "\n") where line.contains("service.firstCompile") {
        if let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
           let fields = entry["fields"] as? [String: String],
           let milliseconds = fields["milliseconds"].flatMap(Double.init)
        {
            return milliseconds / 1000
        }
    }
    return nil
}

private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

private func milliseconds(_ values: [Double]) -> [String: Double] {
    let sorted = values.sorted()
    guard let maximum = sorted.last else {
        return [:]
    }
    return ["median": sorted[sorted.count / 2] * 1000, "p95": p95(sorted) * 1000, "max": maximum * 1000]
}

private func p95(_ sorted: [Double]) -> Double {
    sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
}

private func typingBudgetFailures(wall: [Double], cpu: [Double]) -> [String] {
    guard wall.count >= 80, cpu.count == wall.count else {
        return ["Expected at least 80 paired typing samples"]
    }
    var failures: [String] = []
    if p95(wall.sorted()) >= 0.1 {
        failures.append("Typing wall-time p95 must stay below 100 ms")
    }
    if wall.contains(where: { $0 >= 0.25 }) {
        failures.append("Every input must finish within 250 ms wall time")
    }
    if cpu.contains(where: { $0 >= 0.1 }) {
        failures.append("Every input must stay below 100 ms of main-thread CPU work")
    }
    return failures
}

@Test func bookTypingBudgetDistinguishesSchedulingNoiseFromSustainedSlowInput() {
    let fast = Array(repeating: 0.012, count: 80)
    // A lone scheduling delay is visible in the report without hiding slow
    // editor work, a sustained latency regression, or a severe individual stall.
    #expect(typingBudgetFailures(wall: [0.1025] + fast.dropFirst(), cpu: fast).isEmpty)
    #expect(!typingBudgetFailures(wall: [0.1025] + fast.dropFirst(), cpu: [0.101] + fast.dropFirst()).isEmpty)
    #expect(!typingBudgetFailures(wall: Array(repeating: 0.11, count: 5) + fast.dropFirst(5), cpu: fast).isEmpty)
    #expect(!typingBudgetFailures(wall: [0.3] + fast.dropFirst(), cpu: fast).isEmpty)
    #expect(!typingBudgetFailures(wall: Array(fast.prefix(16)), cpu: Array(fast.prefix(16))).isEmpty)
}

private func physicalFootprint() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}
