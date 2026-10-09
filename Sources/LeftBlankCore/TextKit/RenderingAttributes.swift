import Foundation
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// Drawing-only colours for a TextKit 2 view. NSTextLayoutManager rendering
/// attributes are slow to read back and pay for every run after a changed
/// one, so a mirror of the whole document answers the styler's reads and
/// only changed spans are pushed. The mirror follows each character edit the
/// way TextKit moves rendering attributes: inserted text has none.
@MainActor
public final class RenderingAttributes {
    private static let drawn: [NSAttributedString.Key] = [.foregroundColor, .backgroundColor]
    /// More separate changes than this are cheaper as one ordered rebuild.
    private static let rebuildThreshold = 256
    private let manager: NSTextLayoutManager
    private var mirror = NSMutableAttributedString()
    private var changes: [NSRange] = []
    private var rebuild = false

    public init(manager: NSTextLayoutManager, length: Int) {
        self.manager = manager
        mirror = NSMutableAttributedString(string: String(repeating: " ", count: length))
    }

    public func value(_ key: NSAttributedString.Key, at index: Int, effectiveRange: inout NSRange) -> Any? {
        guard index < mirror.length else {
            effectiveRange = NSRange(location: index, length: 0)
            return nil
        }
        return mirror.attribute(key, at: index, effectiveRange: &effectiveRange)
    }

    public func set(_ key: NSAttributedString.Key, value: Any?, range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= mirror.length else {
            return
        }
        if let value {
            mirror.addAttribute(key, value: value, range: range)
        } else {
            mirror.removeAttribute(key, range: range)
        }
        if Self.drawn.contains(key) {
            changes.append(range)
            rebuild = rebuild || changes.count > Self.rebuildThreshold
        }
    }

    /// Replaces the drawn syntax colours with `runs`, which may nest (later
    /// runs win). Only spans that differ from what is drawn are written, so an
    /// identical reply writes nothing.
    public func setColors(_ runs: [(range: NSRange, color: PlatformColor)]) {
        let whole = NSRange(location: 0, length: mirror.length)
        let desired = NSMutableAttributedString(string: String(repeating: " ", count: whole.length))
        for run in runs where run.range.location >= 0 && run.range.length > 0 && NSMaxRange(run.range) <= whole.length {
            desired.addAttribute(.foregroundColor, value: run.color, range: run.range)
        }
        var changes: [(NSRange, Any?)] = []
        desired.enumerateAttribute(.foregroundColor, in: whole) { value, span, _ in
            var cursor = span.location
            while cursor < NSMaxRange(span) {
                var current = NSRange()
                let drawn = mirror.attribute(.foregroundColor, at: cursor, effectiveRange: &current)
                let next = min(NSMaxRange(span), NSMaxRange(current))
                guard next > cursor else {
                    break
                }
                if (drawn as? NSObject)?.isEqual(value) != true, drawn != nil || value != nil {
                    changes.append((NSRange(location: cursor, length: next - cursor), value))
                }
                cursor = next
            }
        }
        for (range, value) in changes {
            set(.foregroundColor, value: value, range: range)
        }
        commit()
    }

    /// Number of UTF-16 units the mirror covers (the text length).
    public var length: Int {
        mirror.length
    }

    public func removeAll() {
        mirror = NSMutableAttributedString(string: String(repeating: " ", count: mirror.length))
        changes = []
        rebuild = false
        manager.setRenderingAttributes([:], for: manager.documentRange)
    }

    public func replaceCharacters(in range: NSRange, length: Int) {
        guard NSMaxRange(range) <= mirror.length else {
            return
        }
        mirror.replaceCharacters(in: range, with: NSAttributedString(string: String(repeating: " ", count: length)))
    }

    public func commit() {
        defer { changes = []
            rebuild = false
        }
        if rebuild {
            // Clearing is one operation; appending runs in order never shifts
            // existing ones. Deleting or inserting runs one by one in a book
            // costs O(runs) each (3 s for 100,000 removals in War and Peace).
            manager.setRenderingAttributes([:], for: manager.documentRange)
            push(NSRange(location: 0, length: mirror.length), clear: false)
            return
        }
        // Later spans first, so earlier writes never shift runs still to come.
        for range in merged(changes).reversed() {
            push(range, clear: true)
        }
    }

    private func push(_ range: NSRange, clear: Bool) {
        guard range.length > 0, let start = TextKit2Geometry.location(range.location, in: manager),
              let whole = TextKit2Geometry.textRange(range, in: manager)
        else {
            return
        }
        if clear {
            for key in Self.drawn {
                manager.removeRenderingAttribute(key, for: whole)
            }
        }
        var cursor = start, cursorOffset = range.location
        mirror.enumerateAttributes(in: range) { attributes, span, _ in
            let values = Self.drawn.compactMap { key in attributes[key].map { (key, $0) } }
            guard !values.isEmpty,
                  let from = manager.location(cursor, offsetBy: span.location - cursorOffset),
                  let to = manager.location(from, offsetBy: span.length),
                  let textRange = NSTextRange(location: from, end: to)
            else {
                return
            }
            for (key, value) in values {
                manager.addRenderingAttribute(key, value: value, for: textRange)
            }
            cursor = to
            cursorOffset = NSMaxRange(span)
        }
    }

    private func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = result.last, NSMaxRange(last) >= range.location {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
