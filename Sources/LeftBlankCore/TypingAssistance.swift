import Foundation

/// A conservative trigger, not a Typst parser. The language service supplies candidates.
/// Track strings, raw text and comments so they do not accidentally activate code assistance.
public struct TypingContext: Equatable, Sendable {
    public let prefix: String
    public let wantsCompletion: Bool
    public let wantsSignature: Bool

    /// Run the lexical pass away from the UI thread, and stop obsolete requests promptly.
    public static func resolve(source: String, selection: NSRange) async -> TypingContext? {
        let task = Task.detached(priority: .userInitiated) {
            TypingContext(source: source, selection: selection)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public init?(source: String, selection: NSRange) {
        let text = source as NSString
        guard selection.length == 0, selection.location > 0, selection.location <= text.length else {
            return nil
        }
        let end = selection.location
        if end < text.length, (0xD800 ... 0xDBFF).contains(text.character(at: end - 1)),
           (0xDC00 ... 0xDFFF).contains(text.character(at: end))
        {
            return nil
        }
        var index = 0, wordStart = end, calls = 0, rawTicks = 0, blockDepth = 0
        var code = false, math = false, quoted = false, lineComment = false
        while index < end {
            if index.isMultiple(of: 4096), Task.isCancelled {
                return nil
            }
            let c = text.character(at: index)
            let next: UInt16 = index + 1 < end ? text.character(at: index + 1) : 0
            if lineComment {
                if c == 10 || c == 13 {
                    lineComment = false
                    if calls == 0 {
                        code = false
                    }
                }
                index += 1
                wordStart = index
                continue
            }
            if blockDepth > 0 {
                if c == 47, next == 42 {
                    blockDepth += 1
                    index += 2
                } else if c == 42, next == 47 {
                    blockDepth -= 1
                    index += 2
                } else {
                    index += 1
                }
                wordStart = index
                continue
            }
            if rawTicks > 0 {
                if c == 96 {
                    let start = index
                    while index < end, text.character(at: index) == 96 {
                        index += 1
                    }
                    if index - start == rawTicks {
                        rawTicks = 0
                    }
                } else {
                    index += 1
                }
                wordStart = index
                continue
            }
            if c == 92 {
                index = min(end, index + 2)
                wordStart = index
                continue
            }
            if !quoted {
                if c == 47, next == 47 {
                    lineComment = true
                    index += 2
                    wordStart = index
                    continue
                }
                if c == 47, next == 42 {
                    blockDepth = 1
                    index += 2
                    wordStart = index
                    continue
                }
                if c == 96 {
                    let start = index
                    while index < end, text.character(at: index) == 96 {
                        index += 1
                    }
                    rawTicks = index - start
                    wordStart = index
                    continue
                }
            }
            if c == 34, code || calls > 0 {
                quoted.toggle()
                wordStart = index + 1
            } else if quoted {
                if c == 47 {
                    wordStart = index + 1
                }
            } else if c == 35 || c == 64 {
                code = true
                wordStart = index + 1
            } else if c == 36 {
                math.toggle()
                wordStart = index + 1
            } else if c == 40, code || math || calls > 0 {
                calls += 1
                wordStart = index + 1
            } else if c == 41, calls > 0 {
                calls -= 1
                wordStart = index + 1
                if calls == 0 {
                    code = false
                }
            } else if (65 ... 90).contains(c) || (97 ... 122).contains(c) || (48 ... 57).contains(c)
                || c == 95 || c == 45 || c >= 128
            {
                // Continue a Unicode identifier. The caret boundary was checked above.
            } else {
                wordStart = index + 1
                if calls == 0, !math, c != 46 {
                    code = false
                }
            }
            index += 1
        }
        guard !lineComment, blockDepth == 0, rawTicks == 0 else {
            return nil
        }
        let last = text.character(at: end - 1)
        let word = text.substring(with: NSRange(location: min(wordStart, end), length: end - min(wordStart, end)))
        let completion = quoted || ((code || math || calls > 0) && (!word.isEmpty || [35, 64, 46].contains(last)))
        guard completion || calls > 0 else {
            return nil
        }
        prefix = word
        wantsCompletion = completion
        wantsSignature = calls > 0
    }
}

/// Keyboard selection is identical on both platforms. Preserve server ranking.
public struct CompletionList: Sendable {
    public let items: [SourceCompletion]
    public private(set) var index = 0

    public init(items: [SourceCompletion], prefix: String) {
        // The server may use labels such as `width:` or paths; do not rewrite edits.
        let matched = items.filter {
            prefix.isEmpty || $0.label.localizedCaseInsensitiveContains(prefix)
        }
        self.items = matched
    }

    public var selected: SourceCompletion? {
        items.indices.contains(index) ? items[index] : nil
    }

    public mutating func move(_ delta: Int) {
        guard !items.isEmpty else {
            return
        }
        index = min(max(index + delta, 0), items.count - 1)
    }
}
