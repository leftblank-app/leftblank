import Foundation

/// Tracks UTF-16 placeholder ranges while the user edits one placeholder.
public struct SnippetNavigation: Sendable {
    public private(set) var ranges: [NSRange]
    public private(set) var index = 0

    public init(_ snippet: Snippet, at offset: Int) {
        ranges = snippet.selections.map { NSRange(location: offset + $0.location, length: $0.length) }
    }

    public var current: NSRange? {
        ranges.indices.contains(index) ? ranges[index] : nil
    }

    public mutating func edit(_ range: NSRange, replacement: String) {
        guard let current, range.location >= current.location, NSMaxRange(range) <= NSMaxRange(current) else {
            ranges = []
            return
        }
        let delta = replacement.utf16.count - range.length
        ranges[index].length += delta
        for next in ranges.indices where next > index {
            ranges[next].location += delta
        }
    }

    public mutating func move(backward: Bool) -> NSRange? {
        guard let last = ranges.last else {
            return nil
        }
        let end = NSMaxRange(last)
        index += backward ? -1 : 1
        if let current {
            return current
        }
        ranges = []
        return NSRange(location: end, length: 0)
    }
}

/// Tinymist returns numbered placeholders even when snippetSupport is false.
/// Decode its simple tab stops; reject variables, mirrors, choices and transforms.
public enum CompletionSnippet {
    public static func decode(_ source: String) -> Snippet? {
        guard source.utf16.count <= 1_000_000 else {
            return nil
        }
        let input = Array(source)
        var index = 0, output = "", ranges: [NSRange] = [], lastStop = 0
        var finalStop: NSRange?
        while index < input.count {
            let character = input[index]
            index += 1
            if character == "\\" {
                guard index < input.count, ["\\", "$", "}"].contains(input[index]) else {
                    return nil
                }
                output.append(input[index])
                index += 1
            } else if character == "$" {
                let braced = index < input.count && input[index] == "{"
                if braced {
                    index += 1
                }
                let start = index
                while index < input.count, input[index].isASCII, input[index].isNumber {
                    index += 1
                }
                guard index > start, let number = Int(String(input[start ..< index])), number >= 0,
                      number == 0 ? finalStop == nil : number > lastStop,
                      finalStop == nil, ranges.count < 128
                else {
                    return nil
                }
                var value = ""
                if braced {
                    guard index < input.count else {
                        return nil
                    }
                    if input[index] == ":" {
                        index += 1
                        while index < input.count, input[index] != "}" {
                            if input[index] == "\\" {
                                index += 1
                                guard index < input.count, ["\\", "$", "}"].contains(input[index]) else {
                                    return nil
                                }
                            } else if input[index] == "$" {
                                return nil
                            }
                            value.append(input[index])
                            index += 1
                        }
                    }
                    guard index < input.count, input[index] == "}" else {
                        return nil
                    }
                    index += 1
                }
                let range = NSRange(location: output.utf16.count, length: value.utf16.count)
                output += value
                if number == 0 {
                    finalStop = range
                } else {
                    ranges.append(range)
                    lastStop = number
                }
            } else {
                output.append(character)
            }
        }
        if let finalStop {
            ranges.append(finalStop)
        }
        return Snippet(text: output, selections: ranges)
    }
}
