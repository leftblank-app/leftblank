import Foundation
@testable import LeftBlankCore
import Testing

struct AgentDiffTests {
    private func numbered(_ count: Int, _ change: [Int: String] = [:]) -> String {
        (1 ... count).map { change[$0] ?? "line \($0)" }.joined(separator: "\n") + "\n"
    }

    @Test func singleChangeShowsTheChangedRegionWithContext() {
        let summary = AgentDiff.summary(before: numbered(20), after: numbered(20, [10: "changed 10"]))
        #expect(summary.hunks.count == 1 && !summary.abbreviated && summary.omittedHunks == 0)
        let hunk = summary.hunks[0]
        #expect(hunk.beforeStart == 7 && hunk.beforeCount == 7 && hunk.afterStart == 7 && hunk.afterCount == 7)
        #expect(hunk.text == " line 7\n line 8\n line 9\n-line 10\n+changed 10\n line 11\n line 12\n line 13\n")
    }

    @Test func separateEditsBecomeSeparateHunksWithTheirOwnLineNumbers() {
        let after = numbered(100, [5: "five", 50: "fifty"]).replacingOccurrences(of: "line 80\n", with: "")
        let summary = AgentDiff.summary(before: numbered(100), after: after)
        #expect(summary.hunks.map(\.beforeStart) == [2, 47, 77])
        #expect(summary.hunks.map(\.afterStart) == [2, 47, 77])
        #expect(summary.hunks[1].text.contains("-line 50\n+fifty\n"))
        #expect(summary.hunks[2].beforeCount == 7 && summary.hunks[2].afterCount == 6)
        #expect(summary.hunks[2].text.contains("-line 80\n"))
        // Nearby edits share one hunk instead of repeating context.
        let close = AgentDiff.summary(before: numbered(30), after: numbered(30, [10: "ten", 14: "fourteen"]))
        #expect(close.hunks.count == 1 && close.hunks[0].beforeCount == 11)
    }

    @Test func longCJKLinesStayBoundedAroundTheChangedText() {
        let prefix = String(repeating: "汉字排版", count: 200), suffix = String(repeating: "中文段落", count: 200)
        let before = "= 标题\n" + prefix + "旧词" + suffix + "\n结尾 😀\n"
        let after = "= 标题\n" + prefix + "新词" + suffix + "\n结尾 😀\n"
        let summary = AgentDiff.summary(before: before, after: after)
        #expect(summary.abbreviated && summary.hunks.count == 1)
        let lines = summary.hunks[0].text.split(separator: "\n").map(String.init)
        #expect(lines.first == " = 标题" && lines.last == " 结尾 😀")
        let removed = lines.first { $0.hasPrefix("-") }, added = lines.first { $0.hasPrefix("+") }
        #expect(removed?.contains("旧词") == true && added?.contains("新词") == true)
        #expect(removed?.hasPrefix("-…") == true && removed?.hasSuffix("…") == true)
        #expect(lines.allSatisfy { $0.count <= AgentDiff.maximumLineCharacters + 3 })
        #expect(summary.hunks[0].beforeStart == 1 && summary.hunks[0].beforeCount == 3)
    }

    @Test func addedDeletedIdenticalAndNewlineOnlyChanges() {
        let added = AgentDiff.summary(before: nil, after: "a\nb\n")
        #expect(added.hunks == [AgentDiff.Hunk(
            beforeStart: 0,
            beforeCount: 0,
            afterStart: 1,
            afterCount: 2,
            text: "+a\n+b\n",
        )])
        let deleted = AgentDiff.summary(before: "a\n", after: nil)
        #expect(deleted.hunks.first?.text == "-a\n" && deleted.hunks.first?.afterCount == 0)
        #expect(AgentDiff.summary(before: "same\n", after: "same\n").hunks.isEmpty)
        let newline = AgentDiff.summary(before: "a\nb", after: "a\nb\n")
        #expect(newline.hunks.first?.text == " a\n-b\n\\ No newline at end of file\n+b\n")
        let inserted = AgentDiff.summary(before: "a\nb\n", after: "a\nnew\nb\n")
        #expect(inserted.hunks.first?.text == " a\n+new\n b\n")
        let crlf = AgentDiff.summary(before: "x\r\ny\r\n", after: "x\r\nz\r\n")
        #expect(crlf.hunks.first?.text == " x\r\n-y\r\n+z\r\n")
    }

    @Test func randomEditsRoundTripThroughTheHunks() {
        var seed: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        for _ in 0 ..< 200 {
            let before = (0 ..< next(30)).map { _ in ["a", "b", "c", "中", "😀"][next(5)] }
            var after = before
            for _ in 0 ..< next(6) {
                let position = next(after.count + 1)
                switch next(3) {
                case 0: after.insert(["x", "a", "文"][next(3)], at: position)
                case 1 where position < after.count: after.remove(at: position)
                default: if position < after.count {
                        after[position] = "y"
                    }
                }
            }
            let old = before.map { $0 + "\n" }.joined(), new = after.map { $0 + "\n" }.joined()
            let summary = AgentDiff.summary(before: old, after: new)
            // Apply hunks to the old lines; the result must equal the new lines.
            var result: [String] = [], consumed = 0
            for hunk in summary.hunks {
                let start = hunk.beforeCount == 0 ? hunk.beforeStart : hunk.beforeStart - 1
                result += before[consumed ..< start]
                consumed = start
                for line in hunk.text.split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
                    switch line.first {
                    case " ": result.append(String(line.dropFirst()))
                        consumed += 1
                    case "-": consumed += 1
                    default: result.append(String(line.dropFirst()))
                    }
                }
            }
            result += before[consumed...]
            #expect(result == after, "\(before) -> \(after)")
            #expect(summary.hunks.isEmpty == (before == after))
        }
    }

    @Test func largeRewritesAndManyHunksAreBounded() throws {
        let before = (1 ... 5000).map { "old \($0)" }.joined(separator: "\n")
        let after = (1 ... 5000).map { "new \($0)" }.joined(separator: "\n")
        let rewrite = AgentDiff.summary(before: before, after: after)
        #expect(rewrite.abbreviated && rewrite.hunks.count == 1)
        #expect(rewrite.hunks[0].beforeCount == 5000 && rewrite.hunks[0].afterCount == 5000)
        #expect(rewrite.hunks[0].text.count <= AgentDiff.maximumCharacters + 40)
        #expect(rewrite.hunks[0].text.hasSuffix("more lines\n"))
        let scattered = Dictionary(uniqueKeysWithValues: stride(from: 10, through: 1000, by: 20).map { ($0, "x\($0)") })
        let many = AgentDiff.summary(before: numbered(1000), after: numbered(1000, scattered))
        #expect(many.hunks.count == AgentDiff.maximumHunks && many.omittedHunks == scattered.count - many.hunks.count)
        #expect(many.abbreviated)
        let json = AgentDiff.json(before: numbered(1000), after: numbered(1000, scattered))
        #expect(json["omitted_hunks"].int == many.omittedHunks && json["format"].string == "unified")
        #expect(try AgentTools.canonical(json).count < 16 * 1024)
    }
}
