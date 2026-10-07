import CoreGraphics
import Foundation

// The presentation model of the visual editing plan (docs/visual-editing.md):
// source + typst-syntax nodes + selection -> a display plan. Pure value code
// with no text system, identical on macOS and iPadOS. Every range is UTF-16 in
// the original source; a plan never changes the source.

/// How the editor styles a run of source.
public enum PresentationStyle: Equatable, Sendable {
    case heading(level: Int)
    case strong
    case emphasis
    case code
    case link
    case reference
    case label
    case listMarker
    case math
    /// A marker that is concealed elsewhere, shown because the selection touches its construct.
    case revealedMarker
}

public struct StyleRun: Equatable, Sendable {
    public let range: NSRange
    public let style: PresentationStyle

    public init(range: NSRange, style: PresentationStyle) {
        self.range = range
        self.style = style
    }
}

/// One literal argument of a call shown as a chip.
public struct ChipArgument: Equatable, Sendable {
    /// The explicit name of a named argument, or the signature's name for a positional one.
    public let name: String?
    public let isPositional: Bool
    /// The value's source range, including quotes.
    public let valueRange: NSRange
    /// The decoded value: string contents, or the source of a number, boolean, `none` or `auto`.
    public let literal: String
    public let isString: Bool

    public init(name: String?, isPositional: Bool, valueRange: NSRange, literal: String, isString: Bool) {
        self.name = name
        self.isPositional = isPositional
        self.valueRange = valueRange
        self.literal = literal
        self.isString = isString
    }
}

/// A call drawn as one atomic box, with an argument model for a form editor.
public struct Chip: Equatable, Sendable {
    public let callee: String
    /// From `#` through the closing parenthesis.
    public let range: NSRange
    public let arguments: [ChipArgument]
    public let label: String
    /// Location of the closing parenthesis, where new arguments are inserted.
    public let closingParenthesis: Int

    public init(callee: String, range: NSRange, arguments: [ChipArgument], label: String, closingParenthesis: Int) {
        self.callee = callee
        self.range = range
        self.arguments = arguments
        self.label = label
        self.closingParenthesis = closingParenthesis
    }
}

/// An engine-rendered fragment, such as an equation, available for display.
public struct RenderedFragment: Equatable, Sendable {
    public let size: CGSize
    public let baseline: CGFloat

    public init(size: CGSize, baseline: CGFloat) {
        self.size = size
        self.baseline = baseline
    }
}

public enum ReplacementContent: Equatable, Sendable {
    case chip(Chip)
    case bullet
    case image(path: String)
    /// A cached engine fragment, keyed by its source.
    case fragment(key: String, RenderedFragment)
}

/// A source range drawn as one atomic box: the box occupies the first UTF-16
/// unit and the rest of the range is concealed.
public struct Replacement: Equatable, Sendable {
    public let range: NSRange
    public let content: ReplacementContent

    public init(range: NSRange, content: ReplacementContent) {
        self.range = range
        self.content = content
    }
}

/// Work the platform performs off the main thread and reports back as a fragment or image.
public enum InlineRequest: Equatable, Sendable {
    case math(range: NSRange, source: String, isBlock: Bool)
    case image(range: NSRange, path: String)

    public var range: NSRange {
        switch self {
        case let .math(range, _, _), let .image(range, _): range
        }
    }
}

/// Which constructs show their source because of the selection.
public enum RevealPolicy: Equatable, Sendable {
    /// Constructs the selection touches, including at either edge.
    case construct
    /// Every construct in the selection's paragraphs, as the editor does today.
    case paragraph
}

/// A `#let name(a, b, c: default) = …` function definition.
public struct FunctionSignature: Equatable, Sendable {
    public struct Parameter: Equatable, Sendable {
        public let name: String
        public let isPositional: Bool
        /// Source of the default value of a named parameter.
        public let defaultSource: String?

        public init(name: String, isPositional: Bool, defaultSource: String?) {
            self.name = name
            self.isPositional = isPositional
            self.defaultSource = defaultSource
        }
    }

    public let name: String
    public let parameters: [Parameter]

    public init(name: String, parameters: [Parameter]) {
        self.name = name
        self.parameters = parameters
    }

    public var positional: [Parameter] {
        parameters.filter(\.isPositional)
    }
}

/// The `#let` function definitions of a document, in order. A call uses the
/// latest definition before it, as Typst resolves names.
public struct FunctionDefinitions: Equatable, Sendable {
    public struct Definition: Equatable, Sendable {
        /// Start of the `let` binding.
        public let location: Int
        public let signature: FunctionSignature

        public init(location: Int, signature: FunctionSignature) {
            self.location = location
            self.signature = signature
        }
    }

    public let definitions: [Definition]
    private let byName: [String: [Definition]]

    public init(_ definitions: [Definition] = []) {
        self.definitions = definitions
        byName = Dictionary(grouping: definitions, by: \.signature.name)
    }

    /// The definitions among `nodes`.
    public init(source: NSString, nodes: [SyntaxNode]) {
        self.init(Presentation.definitions(source: source, nodes: nodes))
    }

    /// The definition of `name` visible at `location`.
    public func signature(_ name: String, before location: Int) -> FunctionSignature? {
        guard let candidates = byName[name] else {
            return nil
        }
        let index = Presentation.firstIndex(candidates) { $0.location >= location }
        return index > 0 ? candidates[index - 1].signature : nil
    }

    /// The signatures in order, without locations: what can change any call.
    var signatures: [FunctionSignature] {
        definitions.map(\.signature)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.definitions == rhs.definitions
    }
}

/// Chip labels, with optional display names for enumerated values
/// (`status: "done"` -> `[已完成]`).
/// One enumerated value of a parameter and the text a chip shows for it.
public struct ChipValueLabel: Equatable, Sendable {
    public let value: String
    public let label: String

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

public struct ChipFormatter: Equatable, Sendable {
    /// Parameter name -> literal value -> label, for every function.
    public var valueLabels: [String: [String: String]]
    /// Function -> parameter -> labelled values in source order, from the
    /// document's definitions (`Presentation.valueLabels`). These win over
    /// `valueLabels`.
    public var functions: [String: [String: [ChipValueLabel]]]

    public init(
        valueLabels: [String: [String: String]] = [:],
        functions: [String: [String: [ChipValueLabel]]] = [:],
    ) {
        self.valueLabels = valueLabels
        self.functions = functions
    }

    /// The labelled values of one parameter: an enumeration for forms.
    public func labels(callee: String, parameter: String) -> [ChipValueLabel]? {
        functions[callee]?[parameter] ?? valueLabels[parameter].map { labels in
            labels.sorted { $0.key < $1.key }.map { ChipValueLabel(value: $0.key, label: $0.value) }
        }
    }

    public func label(callee: String, arguments: [ChipArgument]) -> String {
        var words: [String] = []
        for argument in arguments where !argument.literal.isEmpty {
            if let name = argument.name, let labels = labels(callee: callee, parameter: name) {
                words.append("[\(labels.first { $0.value == argument.literal }?.label ?? argument.literal)]")
            } else if argument.isPositional {
                words.append(argument.literal)
            }
        }
        return words.isEmpty ? callee : words.joined(separator: " ")
    }
}

/// Settings that change how every construct is planned.
public struct PresentationOptions: Equatable, Sendable {
    public var reveal: RevealPolicy
    public var formatter: ChipFormatter
    public var showsImages: Bool
    /// Engine-rendered equations available now, keyed by equation source.
    public var fragments: [String: RenderedFragment]

    public init(
        reveal: RevealPolicy = .construct,
        formatter: ChipFormatter = ChipFormatter(),
        showsImages: Bool = true,
        fragments: [String: RenderedFragment] = [:],
    ) {
        self.reveal = reveal
        self.formatter = formatter
        self.showsImages = showsImages
        self.fragments = fragments
    }
}

/// What the editor draws instead of plain source. Every array is sorted by location.
public struct DisplayPlan: Equatable, Sendable {
    /// Disjoint ranges drawn with zero width.
    public var conceals: [NSRange] = []
    /// Disjoint atomic boxes.
    public var replacements: [Replacement] = []
    /// Style runs; they may nest (a heading containing a strong run).
    public var styles: [StyleRun] = []
    public var requests: [InlineRequest] = []
    /// Extents of constructs showing source because of the selection.
    public var revealed: [NSRange] = []
    /// Extents of every planned construct and `#let` signature. Plan storage
    /// never splits one, so each lies inside a single stored block.
    public var extents: [NSRange] = []

    public init() {}

    public var isEmpty: Bool {
        conceals.isEmpty && replacements.isEmpty && styles.isEmpty && requests.isEmpty && revealed.isEmpty
    }

    public func isConcealed(_ location: Int) -> Bool {
        let index = Presentation.firstIndex(conceals) { NSMaxRange($0) > location }
        return index < conceals.count && conceals[index].location <= location
    }

    public func replacement(containing location: Int) -> Replacement? {
        let index = Presentation.firstIndex(replacements) { NSMaxRange($0.range) > location }
        return index < replacements.count && replacements[index].range.location <= location ? replacements[index] : nil
    }

    /// The chips in document order.
    public var chips: [Chip] {
        replacements.compactMap {
            if case let .chip(chip) = $0.content {
                return chip
            }
            return nil
        }
    }

    /// The same plan with every location moved by `delta`.
    func offset(by delta: Int) -> DisplayPlan {
        guard delta != 0 else {
            return self
        }
        var plan = DisplayPlan()
        plan.conceals = conceals.map { $0.offset(by: delta) }
        plan.replacements = replacements.map { $0.offset(by: delta) }
        plan.styles = styles.map { StyleRun(range: $0.range.offset(by: delta), style: $0.style) }
        plan.requests = requests.map { $0.offset(by: delta) }
        plan.revealed = revealed.map { $0.offset(by: delta) }
        plan.extents = extents.map { $0.offset(by: delta) }
        return plan
    }

    /// Appends a plan that lies entirely after this one.
    mutating func append(_ other: DisplayPlan) {
        for range in other.conceals {
            if let last = conceals.last, NSMaxRange(last) >= range.location {
                conceals[conceals.count - 1] = NSUnionRange(last, range)
            } else {
                conceals.append(range)
            }
        }
        replacements += other.replacements
        styles += other.styles
        requests += other.requests
        revealed += other.revealed
        extents += other.extents
    }

    /// The entries that intersect or touch `range`.
    func restricted(to range: NSRange) -> DisplayPlan {
        func touches(_ value: NSRange) -> Bool {
            value.location <= NSMaxRange(range) && NSMaxRange(value) >= range.location
        }
        var plan = DisplayPlan()
        plan.conceals = conceals.filter(touches)
        plan.replacements = replacements.filter { touches($0.range) }
        plan.styles = styles.filter { touches($0.range) }
        plan.requests = requests.filter { touches($0.range) }
        plan.revealed = revealed.filter(touches)
        plan.extents = extents.filter(touches)
        return plan
    }
}

extension NSRange {
    func offset(by delta: Int) -> NSRange {
        NSRange(location: location + delta, length: length)
    }
}

extension Replacement {
    func offset(by delta: Int) -> Replacement {
        let content: ReplacementContent = if case let .chip(chip) = content {
            .chip(Chip(
                callee: chip.callee,
                range: chip.range.offset(by: delta),
                arguments: chip.arguments.map {
                    ChipArgument(
                        name: $0.name,
                        isPositional: $0.isPositional,
                        valueRange: $0.valueRange.offset(by: delta),
                        literal: $0.literal,
                        isString: $0.isString,
                    )
                },
                label: chip.label,
                closingParenthesis: chip.closingParenthesis + delta,
            ))
        } else {
            self.content
        }
        return Replacement(range: range.offset(by: delta), content: content)
    }
}

extension InlineRequest {
    func offset(by delta: Int) -> InlineRequest {
        switch self {
        case let .math(range, source, isBlock): .math(range: range.offset(by: delta), source: source, isBlock: isBlock)
        case let .image(range, path): .image(range: range.offset(by: delta), path: path)
        }
    }
}

/// Builds display plans from syntax nodes.
public enum Presentation {
    /// One planned construct before the reveal decision.
    struct Construct {
        let extent: NSRange
        var conceals: [NSRange] = []
        var replacement: Replacement?
        var styles: [StyleRun] = []
        var request: InlineRequest?
    }

    /// Children of each node in a pre-order list.
    struct Tree {
        let nodes: [SyntaxNode]
        let children: [[Int]]

        init(_ nodes: [SyntaxNode]) {
            var children = [[Int]](repeating: [], count: nodes.count)
            for (index, node) in nodes.enumerated() {
                if let parent = node.parent, parent < nodes.count {
                    children[parent].append(index)
                }
            }
            self.nodes = nodes
            self.children = children
        }

        func children(_ index: Int, _ kind: SyntaxKind) -> [SyntaxNode] {
            children[index].map { nodes[$0] }.filter { $0.kind == kind }
        }
    }

    /// Plans `nodes`, which may be a window of the document's nodes (as
    /// `SyntaxTree.nodes(in:)` returns them). Erroneous constructs and calls
    /// without a visible signature stay source.
    public static func plan(
        source: NSString,
        nodes: [SyntaxNode],
        selection: NSRange,
        definitions: FunctionDefinitions,
        options: PresentationOptions = PresentationOptions(),
    ) -> DisplayPlan {
        let tree = Tree(nodes)
        var constructs: [Construct] = []
        var extents: [NSRange] = []
        for (index, node) in nodes.enumerated() {
            if node.kind == .letBinding {
                // Keep each `#let` within one stored block, so signatures are per block.
                extents.append(node.range)
            }
            guard !node.isErroneous,
                  let construct = construct(
                      index,
                      tree: tree,
                      source: source,
                      definitions: definitions,
                      options: options,
                  )
            else {
                continue
            }
            constructs.append(construct)
        }
        return assemble(constructs, extents: extents, source: source, selection: selection, options: options)
    }

    private static func construct(
        _ index: Int,
        tree: Tree,
        source: NSString,
        definitions: FunctionDefinitions,
        options: PresentationOptions,
    ) -> Construct? {
        let node = tree.nodes[index], range = node.range
        switch node.kind {
        case .heading:
            guard let marker = tree.children(index, .headingMarker).first,
                  let body = tree.children(index, .markup).first, body.range.length > 0
            else {
                return nil
            }
            // `= ` up to the body, so a concealed heading starts at its text.
            let hidden = NSRange(location: marker.range.location, length: body.range.location - marker.range.location)
            return Construct(
                extent: range,
                conceals: [hidden],
                styles: [StyleRun(range: range, style: .heading(level: marker.range.length))],
            )
        case .strong, .emph:
            let markers = tree.children(index, node.kind == .strong ? .star : .underscore).map(\.range)
            guard markers.count == 2, range.length > 2 else {
                return nil
            }
            return Construct(
                extent: range,
                conceals: markers,
                styles: [StyleRun(range: range, style: node.kind == .strong ? .strong : .emphasis)],
            )
        case .raw:
            // Inline raw hides its backticks; a block keeps its fences visible.
            let block = source.substring(with: range).rangeOfCharacter(from: .newlines) != nil
            let delimiters = tree.children(index, .rawDelim).map(\.range) + tree.children(index, .rawLang).map(\.range)
            return Construct(
                extent: range,
                conceals: block ? [] : delimiters.sorted { $0.location < $1.location },
                styles: [StyleRun(range: range, style: .code)],
            )
        case .link:
            return Construct(extent: range, styles: [StyleRun(range: range, style: .link)])
        case .ref:
            // RefMarker spans `@target`; only the `@` is syntax.
            guard let marker = tree.children(index, .refMarker).first else {
                return nil
            }
            return Construct(
                extent: range,
                conceals: [NSRange(location: marker.range.location, length: 1)],
                styles: [StyleRun(range: range, style: .reference)],
            )
        case .label where range.length > 2:
            return Construct(
                extent: range,
                conceals: [
                    NSRange(location: range.location, length: 1),
                    NSRange(location: NSMaxRange(range) - 1, length: 1),
                ],
                styles: [StyleRun(range: range, style: .label)],
            )
        case .listItem:
            guard let marker = tree.children(index, .listMarker).first else {
                return nil
            }
            return Construct(
                extent: marker.range,
                replacement: Replacement(range: marker.range, content: .bullet),
                styles: [StyleRun(range: marker.range, style: .listMarker)],
            )
        case .enumItem, .termItem:
            guard let marker = tree.children(index, node.kind == .enumItem ? .enumMarker : .termMarker).first else {
                return nil
            }
            return Construct(extent: marker.range, styles: [StyleRun(range: marker.range, style: .listMarker)])
        case .equation:
            let body = source.substring(with: range)
            // `$ x $` with inner spaces is a block equation.
            let isBlock = body.count > 2 && body.dropFirst().first?.isWhitespace == true
                && body.dropLast().last?.isWhitespace == true
            var construct = Construct(
                extent: range,
                styles: [StyleRun(range: range, style: .math)],
                request: .math(range: range, source: body, isBlock: isBlock),
            )
            if let fragment = options.fragments[body] {
                construct.replacement = Replacement(range: range, content: .fragment(key: body, fragment))
            }
            return construct
        case .hash:
            // In markup, `#` is a sibling of the embedded call that follows it.
            let next = index + 1
            guard next < tree.nodes.count, tree.nodes[next].kind == .funcCall, tree.nodes[next].parent == node.parent,
                  tree.nodes[next].range.location == NSMaxRange(range), !tree.nodes[next].isErroneous
            else {
                return nil
            }
            return call(next, hash: range, tree: tree, source: source, definitions: definitions, options: options)
        default:
            return nil
        }
    }

    private static func call(
        _ index: Int,
        hash: NSRange,
        tree: Tree,
        source: NSString,
        definitions: FunctionDefinitions,
        options: PresentationOptions,
    ) -> Construct? {
        let parts = tree.children[index].map { tree.nodes[$0] }
        guard parts.count == 2, parts[0].kind == .ident, parts[1].kind == .args,
              let argsIndex = tree.children[index].last,
              let close = tree.children[argsIndex].last.map({ tree.nodes[$0] }), close.kind == .rightParen,
              let arguments = arguments(argsIndex, tree: tree, source: source)
        else {
            return nil
        }
        let callee = source.substring(with: parts[0].range)
        let extent = NSRange(location: hash.location, length: NSMaxRange(tree.nodes[index].range) - hash.location)
        let signature = definitions.signature(callee, before: hash.location)
        if callee == "image", signature == nil {
            guard options.showsImages, let path = arguments.first(where: \.isPositional), path.isString else {
                return nil
            }
            return Construct(
                extent: extent,
                replacement: Replacement(range: extent, content: .image(path: path.literal)),
                request: .image(range: extent, path: path.literal),
            )
        }
        guard let signature else {
            return nil
        }
        // Name positional arguments from the signature, so forms and labels agree.
        let positional = signature.positional
        var position = 0
        let named = arguments.map { argument -> ChipArgument in
            guard argument.isPositional else {
                return argument
            }
            defer { position += 1 }
            return ChipArgument(
                name: position < positional.count ? positional[position].name : nil,
                isPositional: true,
                valueRange: argument.valueRange,
                literal: argument.literal,
                isString: argument.isString,
            )
        }
        let chip = Chip(
            callee: callee,
            range: extent,
            arguments: named,
            label: options.formatter.label(callee: callee, arguments: named),
            closingParenthesis: close.range.location,
        )
        return Construct(extent: extent, replacement: Replacement(range: extent, content: .chip(chip)))
    }

    /// Literal-only argument lists; content blocks, spreads and expressions keep the call as source.
    private static func arguments(_ args: Int, tree: Tree, source: NSString) -> [ChipArgument]? {
        var result: [ChipArgument] = []
        for index in tree.children[args] {
            let node = tree.nodes[index]
            switch node.kind {
            case .leftParen, .rightParen, .comma, .lineComment, .blockComment:
                continue
            case .named:
                let parts = tree.children[index].map { tree.nodes[$0] }
                guard parts.count == 3, parts[0].kind == .ident, let literal = literal(parts[2], source: source) else {
                    return nil
                }
                result.append(ChipArgument(
                    name: source.substring(with: parts[0].range),
                    isPositional: false,
                    valueRange: parts[2].range,
                    literal: literal,
                    isString: parts[2].kind == .str,
                ))
            default:
                guard let literal = literal(node, source: source) else {
                    return nil
                }
                result.append(ChipArgument(
                    name: nil,
                    isPositional: true,
                    valueRange: node.range,
                    literal: literal,
                    isString: node.kind == .str,
                ))
            }
        }
        return result
    }

    static func literal(_ node: SyntaxNode, source: NSString) -> String? {
        switch node.kind {
        case .str: decodeString(source.substring(with: node.range))
        case .int, .float, .numeric, .bool, .noneKeyword, .autoKeyword: source.substring(with: node.range)
        default: nil
        }
    }

    /// The contents of a Typst string literal; nil for an escape this model does not decode.
    static func decodeString(_ raw: String) -> String? {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else {
            return nil
        }
        var result = "", escaped = false
        for character in raw.dropFirst().dropLast() {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "\\", "\"": result.append(character)
                default: return nil
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return escaped ? nil : result
    }

    /// A Typst string literal for `value`.
    public static func encodeString(_ value: String) -> String {
        var result = "\""
        for character in value {
            switch character {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.append(character)
            }
        }
        return result + "\""
    }

    private static func assemble(
        _ constructs: [Construct],
        extents signatureExtents: [NSRange],
        source: NSString,
        selection: NSRange,
        options: PresentationOptions,
    ) -> DisplayPlan {
        let paragraphs: NSRange? = options.reveal == .paragraph ? paragraphRange(selection, in: source) : nil
        func revealed(_ extent: NSRange) -> Bool {
            if let paragraphs {
                let overlaps = NSIntersectionRange(paragraphs, extent).length > 0
                return overlaps || NSLocationInRange(extent.location, paragraphs)
            }
            // Touching either edge counts: the caret right after `*bold*` reveals it.
            return selection.location <= NSMaxRange(extent) && NSMaxRange(selection) >= extent.location
        }
        var plan = DisplayPlan()
        var conceals: [NSRange] = []
        var replacements: [Replacement] = []
        plan.extents = signatureExtents
        for construct in constructs {
            plan.extents.append(construct.extent)
            plan.styles += construct.styles
            if let request = construct.request {
                plan.requests.append(request)
            }
            let hides = !construct.conceals.isEmpty || construct.replacement != nil
            if hides, revealed(construct.extent) {
                plan.revealed.append(construct.extent)
                plan.styles += construct.conceals.map { StyleRun(range: $0, style: .revealedMarker) }
                continue
            }
            conceals += construct.conceals
            if let replacement = construct.replacement {
                replacements.append(replacement)
            }
        }
        // An outer replacement wins over anything nested inside it.
        for replacement in replacements.sorted(by: { $0.range.location < $1.range.location }) {
            if let last = plan.replacements.last, NSMaxRange(last.range) > replacement.range.location {
                continue
            }
            plan.replacements.append(replacement)
        }
        plan.conceals = merged(conceals.filter { range in
            plan.replacement(containing: range.location).map { NSIntersectionRange($0.range, range) != range } ?? true
        })
        plan.styles = plan.styles.enumerated().sorted {
            ($0.element.range.location, $0.offset) < ($1.element.range.location, $1.offset)
        }.map(\.element)
        plan.requests.sort { $0.range.location < $1.range.location }
        plan.revealed.sort { $0.location < $1.location }
        plan.extents.sort { ($0.location, $0.length) < ($1.location, $1.length) }
        return plan
    }

    /// `#let name(…) = …` definitions in document order.
    static func definitions(source: NSString, nodes: [SyntaxNode]) -> [FunctionDefinitions.Definition] {
        let tree = Tree(nodes)
        var result: [FunctionDefinitions.Definition] = []
        for (index, node) in nodes.enumerated() where node.kind == .letBinding && !node.isErroneous {
            guard let closure = tree.children[index].first(where: { nodes[$0].kind == .closure }),
                  let name = tree.children[closure].first.map({ nodes[$0] }), name.kind == .ident,
                  let params = tree.children[closure].first(where: { nodes[$0].kind == .params })
            else {
                continue
            }
            var parameters: [FunctionSignature.Parameter] = []
            for param in tree.children[params] {
                let node = nodes[param]
                if node.kind == .ident {
                    parameters.append(.init(
                        name: source.substring(with: node.range),
                        isPositional: true,
                        defaultSource: nil,
                    ))
                } else if node.kind == .named, let ident = tree.children[param].first.map({ nodes[$0] }),
                          let value = tree.children[param].last.map({ nodes[$0] }), ident.kind == .ident
                {
                    parameters.append(.init(
                        name: source.substring(with: ident.range),
                        isPositional: false,
                        defaultSource: source.substring(with: value.range),
                    ))
                }
            }
            result.append(.init(
                location: node.range.location,
                signature: FunctionSignature(name: source.substring(with: name.range), parameters: parameters),
            ))
        }
        return result
    }

    /// Enumerated values of each function's parameters, read from its body.
    ///
    /// A parameter used as `(key: value, …).at(parameter)` takes the keys
    /// (identifiers or strings) as
    /// its values. A value's label is the value itself when it is a string, or
    /// the first string of an array value; otherwise the key. A parameter
    /// passed on to another such function (`#let item(id, s) = … status(s)`)
    /// inherits that function's labels.
    public static func valueLabels(source: NSString, nodes: [SyntaxNode]) -> [String: [String: [ChipValueLabel]]] {
        let tree = Tree(nodes)
        func text(_ node: SyntaxNode) -> String {
            source.substring(with: node.range)
        }
        func descendants(_ index: Int) -> [Int] {
            var result: [Int] = [], stack = [index]
            while let next = stack.popLast() {
                result.append(next)
                stack += tree.children[next].reversed()
            }
            return result
        }
        func dictionaryLabels(_ dict: Int) -> [ChipValueLabel]? {
            var labels: [ChipValueLabel] = []
            for pair in tree.children[dict] where [.keyed, .named].contains(nodes[pair].kind) {
                let parts = tree.children[pair].map { nodes[$0] }
                guard parts.count == 3 else {
                    return nil
                }
                let key = parts[0].kind == .str ? decodeString(text(parts[0])) : text(parts[0])
                guard let key else {
                    return nil
                }
                let valueIndex = tree.children[pair][2]
                var label = key
                if parts[2].kind == .str {
                    label = decodeString(text(parts[2])) ?? key
                } else if parts[2].kind == .array,
                          let first = tree.children[valueIndex].map({ nodes[$0] }).first(where: { $0.kind == .str })
                {
                    label = decodeString(text(first)) ?? key
                }
                labels.append(ChipValueLabel(value: key, label: label))
            }
            return labels.isEmpty ? nil : labels
        }
        // `forwards` holds (callee, argument position, own parameter).
        struct Function {
            let parameters: [String]
            var labels: [String: [ChipValueLabel]] = [:]
            var forwards: [(String, Int, String)] = []
        }
        var functions: [String: Function] = [:]
        for (index, node) in nodes.enumerated() where node.kind == .letBinding && !node.isErroneous {
            guard let closure = tree.children[index].first(where: { nodes[$0].kind == .closure }),
                  let name = tree.children[closure].first.map({ nodes[$0] }), name.kind == .ident,
                  let params = tree.children[closure].first(where: { nodes[$0].kind == .params })
            else {
                continue
            }
            let parameters = tree.children[params].compactMap { param -> String? in
                let node = nodes[param]
                if node.kind == .ident {
                    return text(node)
                }
                return node.kind == .named ? tree.children[param].first.map { text(nodes[$0]) } : nil
            }
            var function = Function(parameters: parameters)
            for call in descendants(closure) where nodes[call].kind == .funcCall {
                let parts = tree.children[call]
                guard parts.count == 2, nodes[parts[1]].kind == .args else {
                    continue
                }
                let arguments = tree.children[parts[1]].map { nodes[$0] }.filter {
                    ![.leftParen, .rightParen, .comma].contains($0.kind)
                }
                let callee = nodes[parts[0]]
                if callee.kind == .fieldAccess {
                    // `(…).at(parameter)`
                    let access = tree.children[parts[0]].map { nodes[$0] }
                    guard let object = tree.children[parts[0]].first, let field = access.last,
                          field.kind == .ident, text(field) == "at", arguments.count == 1,
                          arguments[0].kind == .ident, parameters.contains(text(arguments[0]))
                    else {
                        continue
                    }
                    var dict = object
                    while nodes[dict].kind == .parenthesized, let inner = tree.children[dict].first(where: {
                        ![.leftParen, .rightParen].contains(nodes[$0].kind)
                    }) {
                        dict = inner
                    }
                    if nodes[dict].kind == .dict, let labels = dictionaryLabels(dict) {
                        function.labels[text(arguments[0])] = labels
                    }
                } else if callee.kind == .ident {
                    for (position, argument) in arguments.enumerated()
                        where argument.kind == .ident && parameters.contains(text(argument))
                    {
                        function.forwards.append((text(callee), position, text(argument)))
                    }
                }
            }
            functions[text(name)] = function
        }
        // Two rounds follow a parameter through two levels of forwarding.
        for _ in 0 ..< 2 {
            for (name, function) in functions {
                var updated = function
                for (callee, position, parameter) in function.forwards where updated.labels[parameter] == nil {
                    if let target = functions[callee], position < target.parameters.count,
                       let labels = target.labels[target.parameters[position]]
                    {
                        updated.labels[parameter] = labels
                    }
                }
                functions[name] = updated
            }
        }
        return functions.compactMapValues { $0.labels.isEmpty ? nil : $0.labels }
    }

    static func paragraphRange(_ range: NSRange, in source: NSString) -> NSRange {
        let location = min(max(0, range.location), source.length)
        let length = min(max(0, range.length), source.length - location)
        return source.paragraphRange(for: NSRange(location: location, length: length))
    }

    static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.filter({ $0.length > 0 }).sorted(by: { $0.location < $1.location }) {
            if let last = result.last, NSMaxRange(last) >= range.location {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// Index of the first element satisfying a predicate that is false then true.
    static func firstIndex<T>(_ items: [T], where predicate: (T) -> Bool) -> Int {
        var low = 0, high = items.count
        while low < high {
            let mid = (low + high) / 2
            if predicate(items[mid]) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }
}
