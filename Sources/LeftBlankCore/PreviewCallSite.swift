import Foundation

/// The text under a preview click, reported by the shared preview script.
public struct PreviewClick: Equatable, Sendable {
    /// The clicked text run, without surrounding whitespace.
    public let text: String
    /// The text runs on the clicked line, which tell apart calls with an equal argument.
    public let line: String

    public init?(text: String, line: String = "") {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }
        self.text = text
        self.line = line
    }

    public init?(message: [String: Any]) {
        guard message["kind"] as? String == "click", let text = message["text"] as? String else {
            return nil
        }
        self.init(text: text, line: message["line"] as? String ?? "")
    }
}

/// Typst gives a string value no source span. Text that a function displays from its
/// parameter, as in `#let item(id) = [== #id]`, therefore jumps to the parameter in the
/// function body rather than to the `#item("LB-001")` call that supplied it. This moves
/// such a target to the call argument that contains the clicked text. It stays where it
/// is unless one call clearly matches. Offsets use UTF-16, like both native editors.
public enum PreviewCallSite {
    /// Function parameters forwarded to another function are followed up to this depth.
    static let forwardingLimit = 4

    public static func offset(_ offset: Int, in source: String, click: PreviewClick?) -> Int {
        let scanner = ObjectScanner(source)
        guard offset >= 0, offset < scanner.units.count, source.contains("let") else {
            return offset
        }
        let index = Index(scanner)
        var offset = offset
        for _ in 0 ..< forwardingLimit {
            guard let (next, forwarded) = index.argument(for: offset, click: click) else {
                break
            }
            offset = next
            if !forwarded {
                break
            }
        }
        return offset
    }
}

private struct Definition {
    let name: String
    let start: Int
    /// Positional parameter names in order; nil for destructuring or after a sink.
    let positional: [String?]
    let named: Set<String>
    let body: Range<Int>
}

private enum Slot: Equatable {
    case positional(Int)
    case named(String)
}

private struct Index {
    let scanner: ObjectScanner
    var definitions: [Definition] = []
    /// Starts of call names, by name, for the defined functions.
    var calls: [String: [Int]] = [:]

    init(_ scanner: ObjectScanner) {
        self.scanner = scanner
        var names: Set<Int> = []
        _ = scanner.scan(from: 0, frames: [], visit: { hash in
            inspect(hash + 1, names: &names)
            return nil
        }, code: { position in
            guard position == 0 || !Self.continues(scanner.units[position - 1]) && scanner.units[position - 1] != 46
            else {
                return
            }
            inspect(position, names: &names)
        })
    }

    /// Records a definition or a call of a defined function that starts at `start`.
    mutating func inspect(_ start: Int, names: inout Set<Int>) {
        guard let name = identifier(at: start) else {
            return
        }
        let after = start + name.utf16.count
        if name == "let", let definition = definition(after: after) {
            definitions.append(definition)
            names.insert(definition.start)
        } else if !names.contains(start), after < scanner.units.count, [40, 91].contains(scanner.units[after]),
                  definitions.contains(where: { $0.name == name })
        {
            calls[name, default: []].append(start)
        }
    }

    func definition(after keyword: Int) -> Definition? {
        let units = scanner.units
        var index = keyword
        while index < units.count, units[index] == 32 || units[index] == 9 {
            index += 1
        }
        guard index > keyword, let name = identifier(at: index) else {
            return nil
        }
        let start = index
        index += name.utf16.count
        guard index < units.count, units[index] == 40, let (parameters, end) = scanner.arguments(at: index) else {
            return nil
        }
        index = end
        while index < units.count, ObjectScanner.space(units[index]) {
            index += 1
        }
        guard index + 1 < units.count, units[index] == 61, units[index + 1] != 61 else {
            return nil
        }
        index += 1
        while index < units.count, ObjectScanner.space(units[index]) {
            index += 1
        }
        guard index < units.count else {
            return nil
        }
        let body: Int
        if let frame = ObjectScanner.frame(units[index], in: .code) {
            guard let end = scanner.scan(from: index + 1, frames: [frame], lenient: true) else {
                return nil
            }
            body = end
        } else {
            body = units[index...].firstIndex(of: 10) ?? units.count
        }
        var positional: [String?] = [], named: Set<String> = [], sink = false
        for parameter in parameters {
            let text = scanner.text(parameter)
            if text.hasPrefix("..") {
                sink = true
                positional.append(nil)
            } else if let (key, _) = self.named(parameter) {
                named.insert(key)
            } else {
                positional.append(sink || identifier(at: parameter.location) != text ? nil : text)
            }
        }
        return Definition(name: name, start: start, positional: positional, named: named, body: index ..< body)
    }

    /// The call argument for the parameter at `target`, and whether that argument is itself
    /// a parameter forwarded by an enclosing function.
    func argument(for target: Int, click: PreviewClick?) -> (Int, Bool)? {
        let units = scanner.units
        var position = target
        if units[position] == 35, position + 1 < units.count {
            position += 1
        }
        var start = position
        while start > 0, Self.continues(units[start - 1]) {
            start -= 1
        }
        guard start == 0 || units[start - 1] != 46, let name = identifier(at: start),
              start + name.utf16.count > position
        else {
            return nil
        }
        guard let definition = definitions.filter({ $0.body.contains(start) })
            .sorted(by: { $0.body.count < $1.body.count })
            .first(where: { slot(for: name, in: $0) != nil }),
            let slot = slot(for: name, in: definition)
        else {
            return nil
        }
        // A later definition with the same name shadows this one.
        let shadow = definitions.first { $0.name == definition.name && $0.start > definition.start }?.start ?? Int.max
        let sites = (calls[definition.name] ?? []).filter { $0 > definition.start && $0 < shadow }
            .compactMap { arguments(at: $0) }
        let values = sites.compactMap { $0.value(for: slot) }
        if let click {
            let scored = sites.compactMap { site -> (score: Int, context: Int, offset: Int)? in
                guard let value = site.value(for: slot), let match = match(click.text, in: value) else {
                    return nil
                }
                let context = site.all.filter { $0 != value }.flatMap(pieces)
                    .count { !$0.trimmed.isEmpty && click.line.contains($0.trimmed) }
                return (match.score, context, match.offset)
            }
            if let best = scored.max(by: { ($0.score, $0.context) < ($1.score, $1.context) }) {
                let ties = scored.count { $0.score == best.score && $0.context == best.context }
                return ties == 1 ? (best.offset, false) : nil
            }
        }
        // A single call is the only one that can have displayed this parameter.
        guard sites.count == 1, values.count == 1, let value = values.first else {
            return nil
        }
        if let piece = pieces(in: value).first, value.location == piece.start - 1 {
            return (piece.start, false)
        }
        return (value.location, identifier(at: value.location).map { $0.utf16.count == value.length } ?? false)
    }

    func slot(for name: String, in definition: Definition) -> Slot? {
        if let index = definition.positional.firstIndex(of: name) {
            return .positional(index)
        }
        return definition.named.contains(name) ? .named(name) : nil
    }

    /// Positional, named and trailing content arguments of the call whose name starts at `start`.
    func arguments(at start: Int) -> Call? {
        let units = scanner.units
        var index = start
        while index < units.count, Self.continues(units[index]) {
            index += 1
        }
        var ranges: [NSRange] = []
        if index < units.count, units[index] == 40 {
            guard let (arguments, end) = scanner.arguments(at: index) else {
                return nil
            }
            ranges = arguments
            index = end
        }
        while index < units.count, units[index] == 91,
              let end = scanner.scan(
                  from: index + 1,
                  frames: [ObjectScanner.Frame(closer: 93, mode: .markup)],
                  lenient: true,
              )
        {
            ranges.append(NSRange(location: index, length: end - index))
            index = end
        }
        var call = Call(all: ranges)
        for range in ranges {
            if scanner.text(range).hasPrefix("..") {
                call.spread = true
            } else if let (key, value) = named(range) {
                call.named[key] = value
            } else {
                call.positional.append(call.spread ? nil : range)
            }
        }
        return call
    }

    /// `key: value` with an identifier key, and the value's range.
    func named(_ range: NSRange) -> (String, NSRange)? {
        guard let key = identifier(at: range.location) else {
            return nil
        }
        var index = range.location + key.utf16.count
        while index < NSMaxRange(range), ObjectScanner.space(scanner.units[index]) {
            index += 1
        }
        guard index < NSMaxRange(range), scanner.units[index] == 58 else {
            return nil
        }
        return (key, scanner.trimmed(index + 1, NSMaxRange(range)))
    }

    /// Where `text` appears in a string or content literal of the argument `value`.
    /// An exact literal scores 3, a literal containing it 2, and a literal it contains 1.
    func match(_ text: String, in value: NSRange) -> (score: Int, offset: Int)? {
        let needle = Array(text.utf16)
        var best: (score: Int, offset: Int)?
        for piece in pieces(in: value) {
            let candidate: (score: Int, offset: Int)? = if piece.trimmed == text {
                (3, piece.offsets[piece.units.firstIndex(where: { !ObjectScanner.space($0) }) ?? 0])
            } else if let found = Self.find(needle, in: piece.units) {
                (2, piece.offsets[found])
            } else if !piece.trimmed.isEmpty, text.contains(piece.trimmed) {
                (1, piece.start)
            } else {
                nil
            }
            if let candidate, candidate.score > best?.score ?? 0 {
                best = candidate
            }
        }
        return best
    }

    /// String and content literals directly inside an argument, such as its value or the
    /// fields of a dictionary, with each decoded UTF-16 unit's source offset.
    func pieces(in range: NSRange) -> [Piece] {
        let units = scanner.units
        var pieces: [Piece] = [], index = range.location
        while index < NSMaxRange(range) {
            if units[index] == 34 {
                let end = min(scanner.ignored(at: index, mode: .code) ?? units.count, NSMaxRange(range))
                pieces.append(decoded(from: index + 1, to: units[end - 1] == 34 && end - 1 > index ? end - 1 : end))
                index = end
            } else if units[index] == 91,
                      let end = scanner.scan(
                          from: index + 1,
                          frames: [ObjectScanner.Frame(closer: 93, mode: .markup)],
                          lenient: true,
                      )
            {
                let inner = index + 1 ..< max(index + 1, end - 1)
                pieces.append(Piece(units: Array(units[inner]), offsets: Array(inner), start: index + 1))
                index = end
            } else if let end = scanner.ignored(at: index, mode: .code) {
                index = end
            } else {
                index += 1
            }
        }
        return pieces
    }

    /// Typst string escapes, mapping each decoded unit to the escape that produced it.
    func decoded(from start: Int, to end: Int) -> Piece {
        let units = scanner.units
        var decoded: [UInt16] = [], offsets: [Int] = [], index = start
        while index < end {
            var produced: [UInt16] = [units[index]], next = index + 1
            if units[index] == 92, index + 1 < end {
                next = index + 2
                switch units[index + 1] {
                case 110: produced = [10]
                case 114: produced = [13]
                case 116: produced = [9]
                case 117 where index + 2 < end && units[index + 2] == 123:
                    if let close = units[index ..< end].firstIndex(of: 125),
                       let value = UInt32(
                           scanner.text(NSRange(location: index + 3, length: close - index - 3)),
                           radix: 16,
                       ),
                       let scalar = Unicode.Scalar(value)
                    {
                        produced = Array(String(scalar).utf16)
                        next = close + 1
                    } else {
                        produced = [117]
                    }
                default: produced = [units[index + 1]]
                }
            }
            decoded += produced
            offsets += Array(repeating: index, count: produced.count)
            index = next
        }
        return Piece(units: decoded, offsets: offsets, start: start)
    }

    /// A Typst identifier starting at `start`: letters, digits, `_` and `-`.
    func identifier(at start: Int) -> String? {
        let units = scanner.units
        guard start < units.count, Self.starts(units[start]) else {
            return nil
        }
        var end = start + 1
        while end < units.count, Self.continues(units[end]) {
            end += 1
        }
        return scanner.text(NSRange(location: start, length: end - start))
    }

    static func starts(_ unit: UInt16) -> Bool {
        if unit < 128 {
            return (65 ... 90).contains(unit) || (97 ... 122).contains(unit) || unit == 95
        }
        return Unicode.Scalar(unit)?.properties.isXIDStart ?? false
    }

    static func continues(_ unit: UInt16) -> Bool {
        if unit < 128 {
            return starts(unit) || (48 ... 57).contains(unit) || unit == 45
        }
        return Unicode.Scalar(unit)?.properties.isXIDContinue ?? false
    }

    static func find(_ needle: [UInt16], in units: [UInt16]) -> Int? {
        guard !needle.isEmpty, needle.count <= units.count else {
            return nil
        }
        return (0 ... units.count - needle.count).first { units[$0 ..< $0 + needle.count].elementsEqual(needle) }
    }
}

private struct Call {
    let all: [NSRange]
    /// Positional arguments in order; nil after a spread, whose position is unknown.
    var positional: [NSRange?] = []
    var named: [String: NSRange] = [:]
    var spread = false

    func value(for slot: Slot) -> NSRange? {
        switch slot {
        case let .positional(index): index < positional.count ? positional[index] : nil
        case let .named(name): named[name]
        }
    }
}

private struct Piece {
    let units: [UInt16]
    let offsets: [Int]
    /// The source offset where the literal's text starts.
    let start: Int
    var trimmed: String {
        String(decoding: units, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
