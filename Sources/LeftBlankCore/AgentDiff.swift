import Foundation

/// Bounded unified-diff summary returned by write tools so an agent can confirm what changed.
///
/// Lines are compared exactly (a final line without a newline differs from the same line
/// with one). A bounded Myers search finds the edit script; when a file changes too much,
/// the whole changed span is reported as one replacement instead of spending quadratic time.
public enum AgentDiff {
    public struct Hunk: Equatable, Sendable {
        /// 1-based. When a count is 0 the start is the line after which the change applies.
        public let beforeStart: Int
        public let beforeCount: Int
        public let afterStart: Int
        public let afterCount: Int
        /// Unified-diff body: each line is prefixed with " ", "-" or "+".
        public let text: String
    }

    public struct Summary: Equatable, Sendable {
        public let hunks: [Hunk]
        public let omittedHunks: Int
        public let abbreviated: Bool
    }

    static let contextLines = 3
    static let maximumHunks = 8
    static let maximumCharacters = 4000
    static let maximumLineCharacters = 240
    static let maximumEdits = 512

    private enum Operation: Equatable {
        case equal
        case delete
        case insert
    }

    private struct Side {
        let lines: [String]
        /// False when the file has content but no final newline.
        let terminated: Bool
        init(_ text: String) {
            var lines = text.components(separatedBy: "\n")
            terminated = text.isEmpty || text.utf8.last == 10
            if terminated {
                lines.removeLast()
            }
            self.lines = lines
        }

        func key(_ index: Int) -> String {
            index == lines.count - 1 && !terminated ? lines[index] : lines[index] + "\n"
        }
    }

    public static func summary(before: String?, after: String?) -> Summary {
        let old = Side(before ?? ""), new = Side(after ?? "")
        var ids: [String: Int] = [:]
        let a = lineIDs(old, ids: &ids), b = lineIDs(new, ids: &ids)
        return render(script(old: a, new: b), old: old, new: new)
    }

    public static func json(before: String?, after: String?) -> JSONValue {
        let summary = summary(before: before, after: after)
        return .object([
            "format": .string("unified"),
            "hunks": .array(summary.hunks.map { hunk in .object([
                "before_start_line": .number(Double(hunk.beforeStart)),
                "before_line_count": .number(Double(hunk.beforeCount)),
                "after_start_line": .number(Double(hunk.afterStart)),
                "after_line_count": .number(Double(hunk.afterCount)),
                "text": .string(hunk.text),
            ]) }),
            "omitted_hunks": .number(Double(summary.omittedHunks)),
            "abbreviated": .bool(summary.abbreviated),
        ])
    }

    private static func lineIDs(_ side: Side, ids: inout [String: Int]) -> [Int] {
        side.lines.indices.map { index in
            let key = side.key(index)
            if let id = ids[key] {
                return id
            }
            ids[key] = ids.count
            return ids.count - 1
        }
    }

    /// Full edit script: common prefix and suffix are trimmed in linear time first.
    private static func script(old a: [Int], new b: [Int]) -> [Operation] {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix]
        {
            suffix += 1
        }
        let x = Array(a[prefix ..< (a.count - suffix)]), y = Array(b[prefix ..< (b.count - suffix)])
        let middle = myers(x, y) ??
            Array(repeating: .delete, count: x.count) + Array(repeating: .insert, count: y.count)
        return Array(repeating: .equal, count: prefix) + middle + Array(repeating: .equal, count: suffix)
    }

    /// Myers O((N+M)·D) with D capped; nil when the files differ by more edits than the cap.
    private static func myers(_ a: [Int], _ b: [Int]) -> [Operation]? {
        let n = a.count, m = b.count
        guard n > 0 || m > 0 else {
            return []
        }
        guard n > 0, m > 0 else {
            return Array(repeating: .delete, count: n) + Array(repeating: .insert, count: m)
        }
        let limit = min(n + m, maximumEdits)
        let offset = limit + 1
        var v = [Int](repeating: 0, count: 2 * limit + 3)
        // trace[d] holds v[-d...d] as it was before step d, enough to walk back.
        var trace: [[Int]] = []
        for d in 0 ... limit {
            trace.append(Array(v[(offset - d) ... (offset + d)]))
            for k in stride(from: -d, through: d, by: 2) {
                var x = k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])
                    ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n, y < m, a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[offset + k] = x
                if x >= n, y >= m {
                    return backtrack(trace, n: n, m: m)
                }
            }
        }
        return nil
    }

    private static func backtrack(_ trace: [[Int]], n: Int, m: Int) -> [Operation] {
        var x = n, y = m, reversed: [Operation] = []
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let v = trace[d]
            func value(_ k: Int) -> Int {
                v[k + d]
            }
            let k = x - y
            let previous = k == -d || (k != d && value(k - 1) < value(k + 1)) ? k + 1 : k - 1
            let previousX = d == 0 ? 0 : value(previous), previousY = previousX - previous
            while x > previousX, y > previousY {
                reversed.append(.equal)
                x -= 1
                y -= 1
            }
            if d > 0 {
                reversed.append(x == previousX ? .insert : .delete)
                x = previousX
                y = previousY
            }
        }
        return reversed.reversed()
    }

    private static func render(_ operations: [Operation], old: Side, new: Side) -> Summary {
        let changes = operations.indices.filter { operations[$0] != .equal }
        guard !changes.isEmpty else {
            return Summary(hunks: [], omittedHunks: 0, abbreviated: false)
        }
        // Group changes whose surrounding context would overlap.
        var ranges: [ClosedRange<Int>] = []
        for index in changes {
            if let last = ranges.last, index - last.upperBound <= 2 * contextLines + 1 {
                ranges[ranges.count - 1] = last.lowerBound ... index
            } else {
                ranges.append(index ... index)
            }
        }
        // Line positions before each operation.
        var oldBefore = [Int](repeating: 0, count: operations.count + 1)
        var newBefore = oldBefore
        for (index, operation) in operations.enumerated() {
            oldBefore[index + 1] = oldBefore[index] + (operation == .insert ? 0 : 1)
            newBefore[index + 1] = newBefore[index] + (operation == .delete ? 0 : 1)
        }
        var hunks: [Hunk] = [], budget = maximumCharacters, abbreviated = false
        for range in ranges {
            guard hunks.count < maximumHunks, budget > 0 else {
                abbreviated = true
                break
            }
            let lower = max(0, range.lowerBound - contextLines)
            let upper = min(operations.count - 1, range.upperBound + contextLines)
            let span = operations[lower ... upper]
            let beforeCount = span.count(where: { $0 != .insert })
            let afterCount = span.count(where: { $0 != .delete })
            var lines: [String] = [], index = lower
            while index <= upper {
                // Pair a run of deletions with the following insertions to locate the edit in long lines.
                var deleted: [Int] = [], inserted: [Int] = []
                while index <= upper, operations[index] == .delete {
                    deleted.append(oldBefore[index])
                    index += 1
                }
                while index <= upper, operations[index] == .insert {
                    inserted.append(newBefore[index])
                    index += 1
                }
                if deleted.isEmpty, inserted.isEmpty {
                    lines.append(line(" ", old, oldBefore[index], focus: 0, abbreviated: &abbreviated))
                    index += 1
                    continue
                }
                for (offset, position) in deleted.enumerated() {
                    let focus = offset < inserted.count ? commonPrefix(
                        old.lines[position],
                        new.lines[inserted[offset]],
                    ) : 0
                    lines.append(line("-", old, position, focus: focus, abbreviated: &abbreviated))
                }
                for (offset, position) in inserted.enumerated() {
                    let focus = offset < deleted.count ? commonPrefix(
                        old.lines[deleted[offset]],
                        new.lines[position],
                    ) : 0
                    lines.append(line("+", new, position, focus: focus, abbreviated: &abbreviated))
                }
            }
            var text = ""
            for (number, entry) in lines.enumerated() {
                let size = entry.count + 1
                guard size <= budget || number == 0 && hunks.isEmpty else {
                    text += "… \(lines.count - number) more lines\n"
                    abbreviated = true
                    budget = 0
                    break
                }
                text += entry + "\n"
                budget -= size
            }
            hunks.append(Hunk(
                beforeStart: oldBefore[lower] + (beforeCount == 0 ? 0 : 1),
                beforeCount: beforeCount,
                afterStart: newBefore[lower] + (afterCount == 0 ? 0 : 1),
                afterCount: afterCount,
                text: text,
            ))
        }
        return Summary(hunks: hunks, omittedHunks: ranges.count - hunks.count, abbreviated: abbreviated)
    }

    private static func line(
        _ marker: String,
        _ side: Side,
        _ index: Int,
        focus: Int,
        abbreviated: inout Bool,
    ) -> String {
        let text = side.lines[index]
        var result = marker
        if text.count > maximumLineCharacters {
            // Keep the changed column visible, with some text before it for orientation.
            let characters = Array(text)
            let start = max(0, min(focus - maximumLineCharacters / 3, characters.count - maximumLineCharacters))
            let end = min(characters.count, start + maximumLineCharacters)
            result += (start > 0 ? "…" : "") + String(characters[start ..< end]) + (end < characters.count ? "…" : "")
            abbreviated = true
        } else {
            result += text
        }
        if index == side.lines.count - 1, !side.terminated {
            result += "\n\\ No newline at end of file"
        }
        return result
    }

    /// Shared leading characters, in grapheme clusters.
    private static func commonPrefix(_ left: String, _ right: String) -> Int {
        var count = 0
        for (a, b) in zip(left, right) {
            guard a == b else {
                break
            }
            count += 1
        }
        return count
    }
}
