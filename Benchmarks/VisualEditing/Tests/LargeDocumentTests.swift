import CoreGraphics
import Foundation
import Testing
@testable import VisualEditing
import VisualPresentation
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// Opt-in: LB019_FIXTURE=<book.typ>. Compares TextKit 1 contiguous layout
/// (today's editor) with TextKit 2 viewport layout, with and without the
/// visual layer, in one harness so numbers are comparable with each other.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LB019_FIXTURE"] != nil))
struct LargeDocumentTests {
    enum Engine: String, CaseIterable, Sendable {
        case tk1
        case tk1Visual
        case tk2
        case tk2Visual
    }

    /// LB019_ENGINES=tk2,tk2Visual limits the run (default: all four).
    nonisolated static let engines: [Engine] = ProcessInfo.processInfo.environment["LB019_ENGINES"].map { list in
        list.split(separator: ",").compactMap { Engine(rawValue: String($0)) }
    } ?? Engine.allCases

    static let fractions = [0.1, 0.9, 0.5, 0.99, 0.01, 0.75]

    func load() throws -> (String, String) {
        let path = try #require(ProcessInfo.processInfo.environment["LB019_FIXTURE"])
        let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        return (URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, text)
    }

    /// Where the target really is (TK2: the laid-out fragment, not the view's
    /// possibly stale caret), whether it is visible, and whether a click on
    /// it lands on it.
    func check(_ offset: Int, _ editor: Harness) -> [String: Any] {
        var caret: CGRect = if let manager = editor.manager, let rect = TextKit2Geometry.caretRect(
            at: offset,
            in: manager,
        ) {
            rect
        } else {
            editor.nativeCaret(offset)
        }
        let viewRect = caret.offsetBy(dx: editor.origin.x, dy: editor.origin.y)
        let visible = editor.visibleRect.insetBy(dx: -1, dy: -1).contains(CGPoint(x: viewRect.midX, y: viewRect.midY))
        let hit = editor.nativeHit(CGPoint(x: caret.minX + 1, y: caret.midY))
        let native = editor.nativeCaret(offset)
        return ["offset": offset, "in_viewport": visible, "hit_error": hit - offset,
                "native_caret_error": native.minY - caret.minY, "height": editor.contentHeight]
    }

    func jumps(_ offsets: [Int], _ editor: Harness, session: VisualEditorSession?, precise: Bool) -> [String: Any] {
        var samples: [[String: Any]] = []
        var times: [Double] = []
        for offset in offsets {
            var passes = 1
            let elapsed = milliseconds {
                if precise {
                    passes = editor.revealPrecisely(offset)
                } else {
                    editor.reveal(offset)
                }
                session?.selectionDidChange(editor.selection, hasMarkedText: false)
                editor.layout()
                editor.draw()
            }
            times.append(elapsed)
            // Measure what the user sees after the run loop turns (UIKit
            // scrolls asynchronously); a synchronous check is reported too.
            let immediate = check(offset, editor)
            editor.settle()
            var sample = check(offset, editor)
            sample["immediate_in_viewport"] = immediate["in_viewport"]
            sample["immediate_hit_error"] = immediate["hit_error"]
            sample["ms"] = elapsed
            sample["passes"] = passes
            samples.append(sample)
        }
        let heights = samples.compactMap { $0["height"] as? CGFloat }
        return ["samples": samples, "ms": summary(times),
                "all_visible": samples.allSatisfy { $0["in_viewport"] as? Bool == true },
                "max_hit_error": samples.map { abs($0["hit_error"] as? Int ?? 0) }.max() ?? 0,
                "height_range": [heights.min() ?? 0, heights.max() ?? 0]]
    }

    @Test(arguments: Self.engines)
    func navigationScrollingAndTyping(engine: Engine) throws {
        let (name, text) = try load()
        let ns = text as NSString
        let size = CGSize(width: 900, height: 1300)
        var report: [String: Any] = ["utf16": ns.length, "memory_before_mib": footprintMiB()]
        var concealing: ConcealingLayoutManager?
        var harness: Harness?
        let textKit1 = engine == .tk1 || engine == .tk1Visual
        report["open_ms"] = milliseconds {
            if textKit1 {
                let manager = engine == .tk1Visual ? ConcealingLayoutManager() : NSLayoutManager()
                concealing = manager as? ConcealingLayoutManager
                harness = Harness(text: text, size: size, textKit1: manager)
            } else {
                harness = Harness(text: text, size: size)
            }
        }
        let editor = try #require(harness)
        defer { editor.close() }
        var session: VisualEditorSession?
        if let concealing {
            report["full_plan_ms"] = milliseconds {
                guard let tree = SyntaxTree(text) else {
                    return
                }
                let nodes = tree.nodes()
                var input = PresentationInput(source: ns, nodes: nodes, selection: NSRange(location: 0, length: 0))
                input.signatures = Presentation.signatures(nodes: nodes, source: ns)
                concealing.apply(Presentation.plan(input))
            }
        } else if engine == .tk2Visual {
            let storage = try #require(editor.contentStorage)
            report["session_open_ms"] = milliseconds {
                session = VisualEditorSession(contentStorage: storage)
            }
            let visual = try #require(session)
            report["full_plan_apply_ms"] = milliseconds {
                visual.selectionDidChange(NSRange(location: 0, length: 0), hasMarkedText: false)
            }
            report["full_plan_only_ms"] = visual.lastPlanMilliseconds
            report["full_plan_nodes_ms"] = visual.lastNodeMilliseconds
            report["conceals"] = visual.plan.conceals.count
            report["replacements"] = visual.plan.replacements.count
            visual.observeEdits()
        }
        report["first_draw_ms"] = milliseconds {
            editor.settle()
            editor.draw()
        }
        report["height_initial"] = editor.contentHeight
        report["memory_open_mib"] = footprintMiB()
        let offsets = Self.fractions.map { fraction in
            let paragraph = ns.paragraphRange(for: NSRange(location: Int(Double(ns.length) * fraction), length: 0))
            return min(ns.length - 1, paragraph.location + min(4, max(0, paragraph.length - 2)))
        }
        report["jumps_native"] = jumps(offsets, editor, session: session, precise: false)
        if !textKit1 {
            report["jumps_precise"] = jumps(offsets, editor, session: session, precise: true)
        }

        var frames: [Double] = []
        editor.reveal(offsets[2])
        for index in 0 ..< 60 {
            frames.append(milliseconds {
                editor.scroll(by: index < 30 ? 80 : -80)
                editor.draw()
            })
        }
        report["scroll_draw_ms"] = summary(frames)

        var typing: [Double] = []
        editor.revealPrecisely(offsets[2])
        let before = editor.string
        var replaceOnly: [Double] = [], visualOnly: [Double] = [], layoutOnly: [Double] = []
        for character in String(repeating: "Smooth 中文😀 input", count: 5) {
            typing.append(milliseconds {
                replaceOnly.append(milliseconds { editor.replace(editor.selection, with: String(character)) })
                visualOnly.append(milliseconds {
                    session?.selectionDidChange(editor.selection, hasMarkedText: false)
                })
                layoutOnly.append(milliseconds { editor.layout() })
            })
        }
        report["typing_ms"] = summary(typing)
        report["typing_breakdown_median_ms"] = ["replace": summary(replaceOnly)["median"] ?? 0,
                                                "visual": summary(visualOnly)["median"] ?? 0,
                                                "layout": summary(layoutOnly)["median"] ?? 0]
        report["typing_plan_ms"] = session?.lastPlanMilliseconds ?? 0
        report["typing_shift_ms"] = session?.lastShiftMilliseconds ?? 0
        var reveal: [Double] = []
        if let session {
            let base = editor.selection.location
            for step in 0 ..< 20 {
                reveal.append(milliseconds {
                    editor.selection = NSRange(location: base + (step.isMultiple(of: 2) ? -40 : 0), length: 0)
                    session.selectionDidChange(editor.selection, hasMarkedText: false)
                    editor.layout()
                })
            }
        }
        report["selection_replan_ms"] = summary(reveal)
        report["typing_nodes_ms"] = session?.lastNodeMilliseconds ?? 0
        report["parser_edit_failures"] = session?.editFailures ?? 0
        #expect(session?.editFailures ?? 0 == 0)
        for _ in 0 ..< 80 where editor.view.undoManager?.canUndo == true {
            editor.undo()
        }
        report["undo_restores_source"] = editor.string == before

        // Exact geometry: TK1 lays out everything; TK2 converges in 8 ms
        // run-loop slices (the proposed background pass).
        var slices: [Double] = []
        report["full_layout_ms"] = milliseconds {
            if let manager = editor.manager {
                var cursor: NSTextLocation?
                var more = true
                while more {
                    slices.append(milliseconds {
                        more = TextKit2Geometry.layoutSlice(after: &cursor, in: manager, budget: 0.008)
                    })
                }
            } else if let manager = editor.textStorage.layoutManagers.first,
                      let container = manager.textContainers.first
            {
                manager.ensureLayout(for: container)
            }
            editor.layout()
        }
        report["full_layout_slices"] = slices.count
        report["full_layout_slice_ms"] = summary(slices)
        report["height_full"] = editor.contentHeight
        report["memory_full_layout_mib"] = footprintMiB()
        if !textKit1 {
            report["jumps_native_after_full_layout"] = jumps(offsets, editor, session: session, precise: false)
        }
        Report.record("large.\(name).\(engine.rawValue)", report)
        if !textKit1 {
            let precise = report["jumps_precise"] as? [String: Any]
            #expect(precise?["all_visible"] as? Bool == true)
            #if canImport(AppKit)
                #expect(precise?["max_hit_error"] as? Int == 0)
            #else
                // Known (docs/visual-editing.md, risk 1): after distant jumps,
                // UITextView.closestPosition can disagree with laid-out TK2 geometry.
                withKnownIssue("UITextView hit testing after distant TK2 jumps", isIntermittent: true) {
                    #expect(precise?["max_hit_error"] as? Int == 0)
                }
            #endif
        }
    }
}
