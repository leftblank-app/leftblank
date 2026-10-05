import Foundation

public struct CommandGroup: Identifiable, Sendable {
    public let id: String
    public let key: String
    private let titleKey: String
    public var title: String {
        L10n.text(titleKey)
    }

    private let subtitleKey: String
    public var subtitle: String {
        L10n.text(subtitleKey)
    }

    public let icon: String
    public let parentID: String?

    public init(id: String, key: String, title: String, subtitle: String, icon: String, parentID: String? = nil) {
        self.id = id
        self.key = key
        titleKey = title
        subtitleKey = subtitle
        self.icon = icon
        self.parentID = parentID
    }

    public static var roots: [Self] {
        children(of: nil)
    }

    public static func children(of parentID: String?) -> [Self] {
        all.filter { $0.parentID == parentID }
    }

    public static let all: [Self] = [
        .init(
            id: "insert",
            key: "i",
            title: "Insert",
            subtitle: "Headings, images, equations and tables",
            icon: "plus-circle",
        ),
        .init(
            id: "style",
            key: "s",
            title: "Text Style",
            subtitle: "Give your words the right emphasis",
            icon: "text-aa",
        ),
        .init(id: "page", key: "p", title: "Page Setup", subtitle: "Paper, margins and page numbers", icon: "file"),
        .init(
            id: "math",
            key: "m",
            title: "Mathematics",
            subtitle: "Discover fractions, matrices and more",
            icon: "sigma",
        ),
        .init(
            id: "layout",
            key: "l",
            title: "Typesetting",
            subtitle: "Columns, alignment and containers",
            icon: "layout",
        ),
        .init(
            id: "references",
            key: "r",
            title: "References",
            subtitle: "Citations, bibliography and contents",
            icon: "books",
        ),
        .init(
            id: "code",
            key: "c",
            title: "Editing & Code",
            subtitle: "Editing, code and Universe packages",
            icon: "brackets-curly",
        ),
        .init(id: "view", key: "v", title: "Workspace", subtitle: "Editor, preview and writing tools", icon: "desktop"),
        .init(id: "file", key: "f", title: "Documents", subtitle: "Open, save and export", icon: "folder-open"),
        .init(
            id: "math-basic",
            key: "b",
            title: "Basic Operations",
            subtitle: "Fractions, roots and scripts",
            icon: "function",
            parentID: "math",
        ),
        .init(
            id: "math-structures",
            key: "s",
            title: "Equation Structures",
            subtitle: "Matrices, cases and calculus",
            icon: "grid-four",
            parentID: "math",
        ),
        .init(
            id: "math-symbols",
            key: "y",
            title: "Symbols & Letterforms",
            subtitle: "Greek letters, sets and vectors",
            icon: "pi",
            parentID: "math",
        ),
    ]
}

public struct CommandField: Identifiable, Sendable {
    public let id: String
    public let resourceKind: DocumentResourceKind?
    private let titleKey: String
    public var title: String {
        L10n.text(titleKey)
    }

    private let initialValue: String
    public var initial: String {
        L10n.text(initialValue)
    }

    public init(_ id: String, _ title: String, _ initial: String, resourceKind: DocumentResourceKind? = nil) {
        self.id = id
        self.resourceKind = resourceKind
        titleKey = title
        initialValue = initial
    }
}

public enum InsertionPlacement: Sendable { case inline, block, preamble }
public enum InsertionContext: String, Sendable { case markup, math }

public struct WritingCommand: Identifiable, Sendable {
    public let id: String
    public let group: String
    public let key: String
    private let titleKey: String
    public var title: String {
        L10n.text(titleKey)
    }

    private let detailKey: String
    public var detail: String {
        L10n.text(detailKey)
    }

    public let keywords: String
    public let fields: [CommandField]
    public let placement: InsertionPlacement
    public let supportsMath: Bool
    private let documentationPath: String?

    public let isInsertion: Bool
    public var documentationURL: URL? {
        guard isInsertion else {
            return nil
        }
        return URL(string: "https://typst.app/docs/reference/" + (documentationPath ?? Self.documentationPath(for: id)))
    }

    public var example: String? {
        Self.examples[L10n.resolvedLanguage]?[id]
    }

    private static let examples: [AppLanguage: [String: String]] = Dictionary(uniqueKeysWithValues:
        [AppLanguage.english, .simplifiedChinese].map { language in
            (language, Dictionary(uniqueKeysWithValues: all.filter(\.isInsertion).compactMap { command in
                (try? TypstInsertion.make(command.id, language: language).text).map { (command.id, $0) }
            }))
        })
    public var keyPath: String {
        Self.keyPaths[id] ?? key
    }

    private static let keyPaths: [String: String] = Dictionary(uniqueKeysWithValues: all.map { command in
        var path = [command.key]
        var group = CommandGroup.all.first { $0.id == command.group }
        while let current = group {
            path.insert(current.key, at: 0)
            group = CommandGroup.all.first { $0.id == current.parentID }
        }
        return (command.id, path.joined(separator: " "))
    })
    public var shortcuts: [DirectShortcut] {
        Self.directShortcuts[id] ?? []
    }

    private static let directShortcuts: [String: [DirectShortcut]] = [
        "writing": [.init("1")], "split": [.init("2")], "preview": [.init("3")],
        "outline": [.init("4")], "diagnostics": [.init("5")],
        "new": [.init("n")], "open": [.init("o")], "save": [.init("s")],
        "importDocument": [.init("o", modifiers: [.command, .shift])],
        "saveAs": [.init("s", modifiers: [.shift, .command])], "export": [.init("e", modifiers: [.shift, .command])],
        "universe": [.init("u", modifiers: [.shift, .command])],
        "completion": [.init(".", modifiers: [.control])],
        "quickHelp": [.init("h", modifiers: [.control, .option])],
        "contextActions": [.init(".", modifiers: [.command])],
        "definition": [.init("j", modifiers: [.control, .command])],
        "navigateBack": [.init("[", modifiers: [.control, .command])],
        "undo": [.init("z")], "redo": [.init("z", modifiers: [.shift, .command])],
        "cut": [.init("x")], "copy": [.init("c")], "paste": [.init("v")], "selectAll": [.init("a")],
        "find": [.init("f")],
        "fontLarger": [.init("+")], "fontSmaller": [.init("-")],
        "indent": [.init("]")], "outdent": [.init("[")], "comment": [.init("/")],
        "format": [.init("f", modifiers: [.option, .shift])],
    ]
    public var icon: String {
        Self.icons[id] ?? "command"
    }

    private static let icons: [String: String] = [
        "undo": "arrow-counter-clockwise", "redo": "arrow-clockwise", "cut": "scissors", "copy": "copy",
        "paste": "clipboard",
        "selectAll": "selection-all", "find": "magnifying-glass", "fontLarger": "magnifying-glass-plus",
        "fontSmaller": "magnifying-glass-minus",
        "heading": "text-h",
        "image": "image",
        "table": "table",
        "math": "math-operations",
        "equation": "equals",
        "code": "file-code",
        "link": "link",
        "bullet": "list-bullets",
        "numbered": "list-numbers",
        "quote": "quotes",
        "footnote": "asterisk-simple",
        "label": "tag-simple",
        "reference": "link-simple-horizontal",
        "terms": "book-open-text",
        "lineBreak": "arrow-elbow-down-left",
        "bold": "text-b",
        "italic": "text-italic",
        "highlight": "highlighter",
        "underline": "text-underline",
        "strike": "text-strikethrough",
        "superscript": "text-superscript",
        "subscript": "text-subscript",
        "smallcaps": "text-aa",
        "textColor": "text-a-underline",
        "paper": "file",
        "margin": "bounding-box",
        "fontSize": "arrows-out",
        "pageNumber": "number-square-one",
        "font": "text-t",
        "language": "translate",
        "leading": "arrows-out-line-vertical",
        "paragraphSpacing": "paragraph",
        "firstLineIndent": "arrow-line-right",
        "justify": "text-align-justify",
        "headingNumbering": "text-h-one",
        "equationNumbering": "number-circle-one",
        "header": "align-top-simple",
        "footer": "align-bottom-simple",
        "documentInfo": "info",
        "fraction": "divide",
        "squareRoot": "radical",
        "nthRoot": "function",
        "power": "arrow-up-right",
        "mathSubscript": "arrow-down-right",
        "binomial": "brackets-round",
        "matrix": "grid-four",
        "vector": "dots-three-vertical",
        "cases": "brackets-curly",
        "aligned": "list",
        "sum": "sigma",
        "integral": "wave-sine",
        "limit": "arrow-line-down",
        "greek": "pi",
        "setMembership": "intersect",
        "arrow": "arrow-right",
        "upright": "text-align-left",
        "accent": "arrow-line-up",
        "align": "text-align-center",
        "columns": "columns",
        "grid": "grid-nine",
        "block": "textbox",
        "padding": "arrows-in-simple",
        "stack": "stack-simple",
        "pageBreak": "file-dashed",
        "verticalSpace": "arrows-vertical",
        "horizontalSpace": "arrows-horizontal",
        "divider": "minus",
        "contents": "list-dashes",
        "bibliography": "books",
        "citation": "book-bookmark",
        "include": "files",
        "import": "package",
        "variable": "code",
        "rawInline": "brackets-angle",
        "universe": "planet",
        "format": "broom",
        "indent": "text-indent",
        "outdent": "text-outdent",
        "comment": "chat-text",
        "completion": "magic-wand",
        "quickHelp": "question", "contextActions": "lightbulb", "editObject": "gear",
        "definition": "arrow-elbow-up-right", "navigateBack": "arrow-left",
        "writing": "pencil-simple",
        "split": "sidebar-simple",
        "preview": "eye",
        "outline": "tree-structure",
        "outlineExpand": "caret-double-down", "outlineCollapse": "caret-double-up",
        "diagnostics": "warning-circle",
        "revealPreview": "crosshair",
        "restart": "plugs-connected",
        "logs": "terminal-window",
        "previewDark": "moon",
        "new": "file-plus",
        "open": "folder-open",
        "importDocument": "tray-arrow-down",
        "revealSource": "folder-simple",
        "save": "floppy-disk",
        "saveAs": "floppy-disk-back",
        "history": "notebook",
        "export": "file-pdf",
        "drafts": "clock-counter-clockwise",
        "reload": "arrows-clockwise",
    ]
    public func acceptsContext(_ mode: String) -> Bool {
        mode == "markup" || (supportsMath && mode == "math")
    }

    public init(
        _ id: String,
        _ group: String,
        _ key: String,
        _ title: String,
        _ detail: String,
        _ keywords: String = "",
        fields: [CommandField] = [],
        placement: InsertionPlacement? = nil,
        supportsMath: Bool = false,
        documentation: String? = nil,
        isInsertion: Bool? = nil,
    ) {
        self.id = id
        self.group = group
        self.key = key
        titleKey = title
        detailKey = detail
        self.keywords = keywords
        self.fields = fields
        self.placement = placement ?? (group == "page" ? .preamble : ([
            "heading",
            "bullet",
            "numbered",
            "quote",
            "image",
            "table",
            "code",
            "equation",
        ].contains(id) ? .block : .inline))
        self.supportsMath = supportsMath
        documentationPath = documentation
        self.isInsertion = isInsertion ?? (group != "view" && group != "file")
    }

    private static func documentationPath(for id: String) -> String {
        switch id {
        case "heading", "table", "quote", "footnote", "link": "model/\(id)/"
        case "bullet": "model/list/"
        case "numbered": "model/enum/"
        case "reference": "model/ref/"
        case "label": "foundations/label/"
        case "image": "visualize/image/"
        case "bold": "model/strong/"
        case "italic": "model/emph/"
        case "highlight": "text/highlight/"
        case "code": "text/raw/"
        case "math", "equation": "math/equation/"
        case "fontSize": "text/text/"
        case "paper", "margin", "pageNumber": "layout/page/"
        default: "syntax/"
        }
    }

    public static let all: [Self] = [
        .init(
            "heading",
            "insert",
            "h",
            "Heading",
            "Add a heading level to the current paragraph.",
            "heading title 标题",
            fields: [.init("level", "Heading level · 1–6", "1")],
        ),
        .init(
            "image",
            "insert",
            "i",
            "Image",
            "Choose or import an image. Its copy stays with your document.",
            "image figure photo picture media 图片 照片 素材",
            fields: [
                .init("path", "Image", "", resourceKind: .image),
                .init("caption", "Image caption", "Image caption"),
            ],
        ),
        .init(
            "table",
            "insert",
            "t",
            "Table",
            "Create a table. Use Tab to move between cells.",
            "table rows columns 表格",
            fields: [.init("columns", "Columns · 1–8", "3"), .init("rows", "Body rows · 1–20", "2")],
        ),
        .init("math", "insert", "m", "Inline Equation", "Insert an $equation$ within a paragraph.", "math equation 数学"),
        .init(
            "equation",
            "insert",
            "e",
            "Display Equation",
            "Set an equation on its own line with room to breathe.",
            "block equation 数学",
        ),
        .init(
            "code",
            "insert",
            "c",
            "Code Block",
            "Insert a code block in the chosen language.",
            "code programming 代码",
            fields: [.init("language", "Code language", "rust")],
        ),
        .init(
            "link",
            "insert",
            "l",
            "Link",
            "Link the selected text to a web address.",
            "link url 网址",
            fields: [.init("url", "Link URL", "https://typst.app")],
        ),
        .init("bullet", "insert", "b", "Bullet List", "Organize your thoughts, one item at a time.", "bullet list 列表"),
        .init("numbered", "insert", "n", "Numbered List", "Use numbers to show order and steps.", "numbered list 列表"),
        .init("quote", "insert", "q", "Block Quote", "Quote a passage worth keeping.", "quote quotation 引用"),
        .init("footnote", "insert", "f", "Footnote", "Add context without interrupting the text.", "footnote note 注释"),
        .init(
            "label",
            "insert",
            "a",
            "Label",
            "Give a heading, equation or image a referenceable name.",
            "label anchor 标签",
            fields: [.init("name", "Label name", "section-intro")],
        ),
        .init(
            "reference",
            "insert",
            "r",
            "Cross-reference",
            "Refer to a label. Enable numbering on the target heading, equation or image.",
            "reference cross 引用",
            fields: [.init("name", "Label name", "section-intro")],
        ),
        .init(
            "terms",
            "insert",
            "d",
            "Term Definition",
            "Arrange terms alongside their definitions.",
            "terms definition glossary 名词 定义列表",
            placement: .block,
            documentation: "model/terms/",
        ),
        .init(
            "lineBreak",
            "insert",
            "w",
            "Line Break",
            "Start a new line within the same paragraph.",
            "linebreak soft break 换行 断行",
            documentation: "text/linebreak/",
        ),
        .init("bold", "style", "b", "Bold", "Emphasize the selection with *bold text*.", "bold strong 加粗"),
        .init("italic", "style", "i", "Italic", "Set the selection in _italics_.", "italic emphasis 斜体"),
        .init("highlight", "style", "h", "Highlight", "Highlight the selected text.", "highlight mark 高亮"),
        .init(
            "underline",
            "style",
            "u",
            "Underline",
            "Underline the selected text.",
            "underline 下划线",
            documentation: "text/underline/",
        ),
        .init(
            "strike",
            "style",
            "s",
            "Strikethrough",
            "Keep text visible while marking a deletion or revision.",
            "strike strikethrough 删除线 划掉",
            documentation: "text/strike/",
        ),
        .init(
            "superscript",
            "style",
            "p",
            "Superscript",
            "Insert superscript text for ordinals or units.",
            "super superscript 上标",
            documentation: "text/super/",
        ),
        .init(
            "subscript",
            "style",
            "d",
            "Subscript",
            "Insert subscript text, such as a chemical formula.",
            "sub subscript 下标",
            documentation: "text/sub/",
        ),
        .init(
            "smallcaps",
            "style",
            "a",
            "Small Capitals",
            "Use small capital letterforms.",
            "smallcaps capitals 大写",
            documentation: "text/smallcaps/",
        ),
        .init(
            "textColor",
            "style",
            "c",
            "Text Color",
            "Set the selection's color with a hexadecimal value.",
            "text fill color 颜色",
            fields: [.init("color", "Color · hexadecimal", "245c73")],
            documentation: "text/text/",
        ),
        .init(
            "paper",
            "page",
            "p",
            "Paper Size",
            "Set the paper size at the top of the document.",
            "paper a4 letter",
            fields: [.init("paper", "Paper · a4 / us-letter / a5", "a4")],
        ),
        .init(
            "margin",
            "page",
            "m",
            "Page Margins",
            "Set consistent margins at the top of the document.",
            "margin page 边距",
            fields: [.init("margin", "Margins · mm", "24")],
        ),
        .init(
            "fontSize",
            "page",
            "s",
            "Document Font Size",
            "Set the body font size in the finished document.",
            "font size 字号",
            fields: [.init("size", "Font size · pt", "11")],
        ),
        .init("pageNumber", "page", "n", "Page Numbers", "Add centered page numbers.", "page number 页码"),
        .init(
            "font",
            "page",
            "f",
            "Document Font",
            "Choose an installed font for the finished document.",
            "font family 字体 宋体 黑体",
            fields: [.init("font", "Font name", "Libertinus Serif")],
            documentation: "text/text/#parameters-font",
        ),
        .init(
            "language",
            "page",
            "l",
            "Document Language",
            "Set a language code for hyphenation and generated headings.",
            "language locale 中文 英文 语言",
            fields: [.init("language", "Language code · en / zh / ja", "zh")],
            documentation: "text/text/#parameters-lang",
        ),
        .init(
            "leading",
            "page",
            "g",
            "Line Spacing",
            "Set the extra space between lines of text.",
            "leading line spacing 行距",
            fields: [.init("amount", "Line spacing · em", "0.65")],
            documentation: "model/par/#parameters-leading",
        ),
        .init(
            "paragraphSpacing",
            "page",
            "b",
            "Paragraph Spacing",
            "Set the space between paragraphs.",
            "paragraph spacing 段间距",
            fields: [.init("amount", "Paragraph spacing · em", "1.2")],
            documentation: "model/par/#parameters-spacing",
        ),
        .init(
            "firstLineIndent",
            "page",
            "i",
            "First-line Indent",
            "Indent the first line of body paragraphs.",
            "indent first line 首行缩进",
            fields: [.init("amount", "First-line indent · em", "2")],
            documentation: "model/par/#parameters-first-line-indent",
        ),
        .init(
            "justify",
            "page",
            "j",
            "Justify Text",
            "Align paragraphs to both left and right edges.",
            "justify paragraph 两端对齐",
            documentation: "model/par/#parameters-justify",
        ),
        .init(
            "headingNumbering",
            "page",
            "h",
            "Heading Numbers",
            "Enable hierarchical numbering for headings.",
            "heading numbering 标题 章节 编号",
            documentation: "model/heading/#parameters-numbering",
        ),
        .init(
            "equationNumbering",
            "page",
            "e",
            "Equation Numbers",
            "Number display equations in parentheses.",
            "equation numbering 数学 公式 编号",
            documentation: "math/equation/#parameters-numbering",
        ),
        .init(
            "header",
            "page",
            "a",
            "Page Header",
            "Add text to the top of each page.",
            "header 页眉",
            fields: [.init("text", "Header text", "Document title")],
            documentation: "layout/page/#parameters-header",
        ),
        .init(
            "footer",
            "page",
            "o",
            "Page Footer",
            "Add text to the bottom of each page, replacing the default page-number position.",
            "footer 页脚",
            fields: [.init("text", "Footer text", "Draft")],
            documentation: "layout/page/#parameters-footer",
        ),
        .init(
            "documentInfo",
            "page",
            "d",
            "Document Metadata",
            "Set the PDF title and author.",
            "document metadata title author 作者 元数据",
            fields: [.init("title", "PDF title", "Untitled"), .init("author", "Author", "Author")],
            documentation: "model/document/",
        ),
        .init(
            "fraction",
            "math-basic",
            "f",
            "Fraction",
            "Insert a numerator and denominator. Existing equations use math syntax directly.",
            "frac fraction 分数 分式",
            supportsMath: true,
            documentation: "math/frac/",
        ),
        .init(
            "squareRoot",
            "math-basic",
            "r",
            "Square Root",
            "Take the square root of a selection or enter a new expression.",
            "sqrt root 根号 根式 平方根",
            supportsMath: true,
            documentation: "math/roots/",
        ),
        .init(
            "nthRoot",
            "math-basic",
            "n",
            "Nth Root",
            "Insert a root with an editable degree.",
            "root nth cube 立方根 次方根",
            supportsMath: true,
            documentation: "math/roots/",
        ),
        .init(
            "power",
            "math-basic",
            "p",
            "Power & Exponent",
            "Add an exponent to the selected expression.",
            "power exponent superscript 幂 指数 数学上标",
            supportsMath: true,
            documentation: "math/attach/",
        ),
        .init(
            "mathSubscript",
            "math-basic",
            "s",
            "Math Subscript",
            "Add a subscript to the selected expression.",
            "subscript index 数学下标 索引",
            supportsMath: true,
            documentation: "math/attach/",
        ),
        .init(
            "binomial",
            "math-basic",
            "b",
            "Binomial Coefficient",
            "Insert a stacked binomial coefficient.",
            "binom binomial combination 组合数 二项式",
            supportsMath: true,
            documentation: "math/binom/",
        ),
        .init(
            "matrix",
            "math-structures",
            "m",
            "Matrix",
            "Separate columns with commas and rows with semicolons. Tab moves between entries.",
            "mat matrix 矩阵 线性代数",
            supportsMath: true,
            documentation: "math/mat/",
        ),
        .init(
            "vector",
            "math-structures",
            "v",
            "Column Vector",
            "Insert a vector with vertically arranged entries.",
            "vec vector 列向量",
            supportsMath: true,
            documentation: "math/vec/",
        ),
        .init(
            "cases",
            "math-structures",
            "c",
            "Piecewise Function",
            "Group expressions and conditions with a brace.",
            "cases piecewise 分段 条件函数",
            supportsMath: true,
            documentation: "math/cases/",
        ),
        .init(
            "aligned",
            "math-structures",
            "a",
            "Aligned Equations",
            "Align equals signs with & and start each line with a backslash.",
            "aligned multiline equation 对齐 方程组 多行",
            supportsMath: true,
            documentation: "math/#alignment",
        ),
        .init(
            "sum",
            "math-structures",
            "s",
            "Summation",
            "Insert a sum with bounds and a term.",
            "sum summation sigma 求和 累加",
            supportsMath: true,
            documentation: "math/attach/",
        ),
        .init(
            "integral",
            "math-structures",
            "i",
            "Integral",
            "Insert a definite integral and differential.",
            "integral calculus 积分 微积分",
            supportsMath: true,
            documentation: "symbols/sym/",
        ),
        .init(
            "limit",
            "math-structures",
            "l",
            "Limit",
            "Insert a limit condition and expression.",
            "lim limit 极限 趋于",
            supportsMath: true,
            documentation: "math/op/",
        ),
        .init(
            "greek",
            "math-symbols",
            "g",
            "Greek Letters",
            "Enter Greek letters by name. Tab moves between examples.",
            "alpha beta gamma Greek 希腊 阿尔法 贝塔",
            supportsMath: true,
            documentation: "symbols/sym/",
        ),
        .init(
            "setMembership",
            "math-symbols",
            "s",
            "Sets & Number Fields",
            "Insert set membership and the real number field.",
            "set membership RR NN ZZ 属于 集合 实数 自然数",
            supportsMath: true,
            documentation: "symbols/sym/",
        ),
        .init(
            "arrow",
            "math-symbols",
            "a",
            "Arrows & Mappings",
            "Insert an arrow between two expressions.",
            "arrow mapping maps to 箭头 映射",
            supportsMath: true,
            documentation: "symbols/sym/",
        ),
        .init(
            "upright",
            "math-symbols",
            "u",
            "Upright Math",
            "Set units or mathematical text in upright letterforms.",
            "upright roman unit 直立体 单位",
            supportsMath: true,
            documentation: "math/variants/",
        ),
        .init(
            "accent",
            "math-symbols",
            "v",
            "Vector Accent",
            "Add a vector arrow above an expression.",
            "accent arrow vector 矢量 向量箭头",
            supportsMath: true,
            documentation: "math/accent/",
        ),
        .init(
            "align",
            "layout",
            "a",
            "Content Alignment",
            "Set the horizontal alignment of a content block.",
            "align center left right 居中 左对齐 右对齐",
            fields: [.init("alignment", "Alignment · left / center / right", "center")],
            placement: .block,
            documentation: "layout/align/",
        ),
        .init(
            "columns",
            "layout",
            "c",
            "Columns",
            "Arrange content in two or more columns.",
            "columns newspaper 分栏 双栏",
            fields: [.init("columns", "Columns · 2–4", "2")],
            placement: .block,
            documentation: "layout/columns/",
        ),
        .init(
            "grid",
            "layout",
            "g",
            "Layout Grid",
            "Arrange content side by side in a grid. Use a table for data.",
            "grid layout 网格 布局",
            placement: .block,
            documentation: "layout/grid/",
        ),
        .init(
            "block",
            "layout",
            "b",
            "Callout",
            "Highlight content with a pale background and padding.",
            "block callout box 提示框 色块 容器",
            placement: .block,
            documentation: "layout/block/",
        ),
        .init(
            "padding",
            "layout",
            "p",
            "Content Padding",
            "Add space around a content block.",
            "pad padding 内边距 留白",
            fields: [.init("amount", "Padding · pt", "12")],
            placement: .block,
            documentation: "layout/pad/",
        ),
        .init(
            "stack",
            "layout",
            "s",
            "Horizontal Stack",
            "Arrange two content blocks side by side with spacing.",
            "stack horizontal 横向 排列",
            placement: .block,
            documentation: "layout/stack/",
        ),
        .init(
            "pageBreak",
            "layout",
            "n",
            "Page Break",
            "Start the following content on a new page.",
            "pagebreak new page 分页 换页",
            placement: .block,
            documentation: "layout/pagebreak/",
        ),
        .init(
            "verticalSpace",
            "layout",
            "v",
            "Vertical Space",
            "Insert vertical space between content blocks.",
            "vertical v spacing 垂直间距 空行",
            fields: [.init("amount", "Space · pt", "12")],
            placement: .block,
            documentation: "layout/v/",
        ),
        .init(
            "horizontalSpace",
            "layout",
            "h",
            "Horizontal Space",
            "Insert horizontal space within a line.",
            "horizontal h spacing 水平间距 空格",
            fields: [.init("amount", "Space · pt", "12")],
            documentation: "layout/h/",
        ),
        .init(
            "divider",
            "layout",
            "d",
            "Divider",
            "Separate sections with a fine rule.",
            "line divider rule 分隔线 横线",
            placement: .block,
            documentation: "visualize/line/",
        ),
        .init(
            "contents",
            "references",
            "o",
            "Table of Contents",
            "Generate a table of contents with page numbers.",
            "outline contents toc 目录",
            placement: .block,
            documentation: "model/outline/",
        ),
        .init(
            "bibliography",
            "references",
            "b",
            "Bibliography",
            "Generate a bibliography from a BibLaTeX or Hayagriva file.",
            "bibliography references bib yaml 参考文献 书目",
            fields: [.init("path", "Bibliography file · .bib / .yaml", "", resourceKind: .bibliography)],
            placement: .block,
            documentation: "model/bibliography/",
        ),
        .init(
            "citation",
            "references",
            "c",
            "Citation",
            "Cite a source by its key. The document needs a bibliography.",
            "cite citation bibliography 文献 引文",
            fields: [.init("name", "Citation key", "example")],
            documentation: "model/cite/",
        ),
        .init(
            "include",
            "code",
            "i",
            "Include Document",
            "Include another .typ document at the current position.",
            "include chapter subdocument 包含 子文稿 章节",
            fields: [.init("path", "Document", "", resourceKind: .document)],
            placement: .block,
            documentation: "scripting/#modules",
        ),
        .init(
            "import",
            "code",
            "m",
            "Import Local Module",
            "Import reusable local definitions at the top of the document.",
            "import module local 模块 导入",
            fields: [.init("path", "Module", "", resourceKind: .module)],
            placement: .preamble,
            documentation: "scripting/#modules",
        ),
        .init(
            "variable",
            "code",
            "v",
            "Define Variable",
            "Define text that you can reuse with #name.",
            "let variable binding 定义 变量",
            fields: [.init("name", "Variable name", "project"), .init("value", "Variable text", "LeftBlank")],
            placement: .preamble,
            documentation: "scripting/#bindings",
        ),
        .init(
            "rawInline",
            "code",
            "r",
            "Inline Code",
            "Show the selection literally without interpreting its Typst syntax.",
            "raw inline code 行内代码 原样",
            documentation: "text/raw/",
        ),
        .init(
            "universe",
            "code",
            "u",
            "Discover Universe Packages",
            "Find drawing, charting and typesetting packages, then insert a versioned import.",
            "universe package plugin cetz fletcher 绘图 扩展 插件 包",
            isInsertion: false,
        ),
        .init(
            "format",
            "code",
            "f",
            "Format Source",
            "Format the current document with Tinymist.",
            "format pretty 格式化 整理",
            isInsertion: false,
        ),
        .init(
            "indent",
            "code",
            ">",
            "Indent",
            "Indent the current line or selected lines.",
            "indent 缩进",
            isInsertion: false,
        ),
        .init(
            "outdent",
            "code",
            "<",
            "Outdent",
            "Outdent the current line or selected lines.",
            "outdent unindent 取消缩进",
            isInsertion: false,
        ),
        .init(
            "comment",
            "code",
            ";",
            "Toggle Line Comments",
            "Comment or uncomment the current line or selection.",
            "comment uncomment 注释",
            isInsertion: false,
        ),
        .init(
            "completion",
            "code",
            ".",
            "Complete Syntax",
            "Discover Typst names and parameters at the caret.",
            "completion autocomplete 补全",
            isInsertion: false,
        ),
        .init(
            "quickHelp",
            "code",
            "h",
            "Explain at Cursor",
            "Read documentation and function parameters at the cursor.",
            "help hover signature parameters 说明 参数 帮助",
            isInsertion: false,
        ),
        .init(
            "editObject", "code", "e", "Edit Table or Image…",
            "Change the table or image at the cursor.",
            "edit table image rows columns caption 修改 表格 图片 行 列 题注",
            isInsertion: false,
        ),
        .init(
            "contextActions",
            "code",
            "q",
            "Actions at Cursor",
            "Discover changes available for this heading, equation or selection.",
            "actions refactor quickfix 标题 公式 上下文 操作",
            isInsertion: false,
        ),
        .init(
            "definition",
            "code",
            "d",
            "Go to Definition",
            "Find the source of a variable, function, reference or imported module.",
            "definition jump import include module 定义 跳转 模块",
            isInsertion: false,
        ),
        .init(
            "navigateBack",
            "code",
            "b",
            "Go Back",
            "Return to your previous writing position.",
            "back navigation 返回",
            isInsertion: false,
        ),
        .init("undo", "code", "z", "Undo", "Undo the most recent document edit.", "undo 撤销", isInsertion: false),
        .init("redo", "code", "y", "Redo", "Restore the edit you just undid.", "redo 重做", isInsertion: false),
        .init("cut", "code", "x", "Cut", "Cut the selected source text.", "cut 剪切", isInsertion: false),
        .init("copy", "code", "c", "Copy", "Copy the selected original Typst source.", "copy 复制", isInsertion: false),
        .init(
            "paste",
            "code",
            "p",
            "Paste",
            "Paste text or import an image at the caret.",
            "paste 粘贴",
            isInsertion: false,
        ),
        .init(
            "selectAll",
            "code",
            "a",
            "Select All",
            "Select the whole document.",
            "select all 全选",
            isInsertion: false,
        ),
        .init(
            "find",
            "code",
            "s",
            "Find in Document",
            "Find text in the current document.",
            "find search 查找 搜索",
            isInsertion: false,
        ),
        .init(
            "fontLarger",
            "view",
            "+",
            "Increase Editor Text Size",
            "Increase the editor font size without changing the finished document.",
            "zoom in editor font 放大 字号",
        ),
        .init(
            "fontSmaller",
            "view",
            "-",
            "Decrease Editor Text Size",
            "Decrease the editor font size without changing the finished document.",
            "zoom out editor font 缩小 字号",
        ),
        .init("writing", "view", "w", "Focus on Writing", "Give your writing the whole window.", "focus writing 专注"),
        .init(
            "split",
            "view",
            "s",
            "Side-by-side Preview",
            "Write alongside a live preview of the finished page.",
            "split preview 分屏",
        ),
        .init(
            "preview",
            "view",
            "p",
            "Read the Preview",
            "Read the finished pages in the whole window.",
            "preview reading 预览",
        ),
        .init(
            "outline",
            "view",
            "o",
            "Outline",
            "See headings and sections in the left margin without moving your text.",
            "outline headings 大纲 目录 脉络",
        ),
        .init(
            "outlineExpand",
            "view",
            "e",
            "Expand All Headings",
            "Show every section in the outline.",
            "expand outline 展开 目录 脉络",
            isInsertion: false,
        ),
        .init(
            "outlineCollapse",
            "view",
            "c",
            "Collapse All Headings",
            "Show only top-level sections in the outline.",
            "collapse outline 折叠 目录 脉络",
            isInsertion: false,
        ),
        .init(
            "diagnostics",
            "view",
            "d",
            "Check Document",
            "Review errors and suggestions, then jump to their source.",
            "diagnostics errors 错误",
        ),
        .init(
            "revealPreview",
            "view",
            "r",
            "Reveal in Preview",
            "Find the current paragraph in the finished page.",
            "reveal jump sync 定位",
        ),
        .init(
            "restart",
            "view",
            "l",
            "Reconnect Typesetting Service",
            "Restart Tinymist and synchronize the current document.",
            "restart language server",
        ),
        .init(
            "logs",
            "view",
            "g",
            "Open Diagnostic Logs",
            "Open local activity logs to investigate crashes and errors.",
            "logs debug diagnostics 日志",
        ),
        .init(
            "previewDark",
            "view",
            "n",
            "Toggle Dark Preview",
            "Change the preview colors. Exported PDFs keep the document's original colors.",
            "dark preview night 深色 暗色 夜间",
        ),
        .init(
            "new",
            "file",
            "n",
            "New Document",
            "Choose a blank page or a template for your next idea.",
            "new document template blank welcome 新建 模板 空白 欢迎",
        ),
        .init(
            "open",
            "file",
            "o",
            "Your Writing",
            "Search and open documents in your library.",
            "open file library 文稿 资料库 打开",
        ),
        .init(
            "importDocument",
            "file",
            "i",
            "Import Document",
            "Add a copy of a source document to your library.",
            "import typ 导入",
        ),
        .init(
            "revealSource",
            "file",
            "v",
            "Show Source in Finder",
            "Reveal the current document's source file.",
            "source file finder 源码 文件",
        ),
        .init(
            "history",
            "file",
            "h",
            "Document History",
            "Compare and restore recent versions of this source document.",
            "history snapshot restore compare 历史 快照 恢复 对比",
            isInsertion: false,
        ),
        .init("save", "file", "s", "Save", "Save the current document to disk.", "save 保存"),
        .init("saveAs", "file", "a", "Save As", "Choose a new name and location for this document.", "save as 另存为"),
        .init("export", "file", "e", "Export PDF", "Export the current document as a shareable PDF.", "export pdf 导出"),
        .init(
            "drafts",
            "file",
            "d",
            "Recover Draft Copy",
            "Reopen a draft saved before switching documents or reloading.",
            "draft recovery 恢复",
        ),
        .init(
            "reload",
            "file",
            "r",
            "Reload from Disk",
            "Preserve local edits in a recovery copy, then read the file from disk.",
            "reload disk conflict 重新加载",
        ),
    ]

    private static let searchIndex = all
        .map {
            "\(L10n.searchTerms($0.titleKey)) \($0.keywords) \(L10n.searchTerms($0.detailKey)) \($0.shortcuts.map(\.label).joined(separator: " "))"
                .lowercased()
        }

    public static func search(_ query: String) -> [Self] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        if words.isEmpty {
            return all
        }
        return all.enumerated().compactMap { index, command in
            words.allSatisfy { searchIndex[index].contains($0) } ? command : nil
        }
    }
}

public struct Snippet: Equatable, Sendable {
    public let text: String
    public let selections: [NSRange]
    public init(text: String, selections: [NSRange] = []) {
        self.text = text
        self.selections = selections
    }

    public func padded(before: String, after: String) -> Snippet {
        Snippet(
            text: before + text + after,
            selections: selections.map { NSRange(location: $0.location + before.utf16.count, length: $0.length) },
        )
    }

    public func replacingLiteral(_ token: String, with value: String) -> Snippet {
        let source = text as NSString
        let range = source.range(of: token)
        guard range.location != NSNotFound else {
            return self
        }
        let delta = value.utf16.count - range.length
        return Snippet(text: source.replacingCharacters(in: range, with: value), selections: selections.map {
            NSRange(location: $0.location >= NSMaxRange(range) ? $0.location + delta : $0.location, length: $0.length)
        })
    }

    public init(_ marked: String) {
        var output = ""
        var ranges: [NSRange] = []
        var cursor = marked.startIndex
        while let open = marked[cursor...].firstIndex(of: "«"),
              let close = marked[marked.index(after: open)...].firstIndex(of: "»")
        {
            output += marked[cursor ..< open]
            let content = String(marked[marked.index(after: open) ..< close])
            ranges.append(NSRange(location: output.utf16.count, length: content.utf16.count))
            output += content
            cursor = marked.index(after: close)
        }
        output += marked[cursor...]
        text = output
        selections = ranges
    }
}

public enum CommandError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case let .invalid(message): message }
    }
}

public enum TypstInsertion {
    public static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(
                of: "\n",
                with: "\\n",
            ).replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\t", with: "\\t") + "\""
    }

    public static func make(
        _ id: String,
        values: [String: String] = [:],
        selection: String = "",
        context: InsertionContext = .markup,
        language: AppLanguage? = nil,
    ) throws -> Snippet {
        func localized(_ key: String) -> String {
            L10n.text(key, language: language)
        }
        func placeholder(_ key: String) -> String {
            "«" + localized(key) + "»"
        }
        func value(_ key: String, _ fallback: String) -> String {
            values[key] ?? fallback
        }
        func number(_ key: String, _ fallback: String, _ range: ClosedRange<Int>) throws -> Int {
            guard let n = Int(value(key, fallback)), range.contains(n) else {
                throw CommandError.invalid(L10n.format(
                    "Enter an integer between %@ and %@.",
                    String(range.lowerBound),
                    String(range.upperBound),
                ))
            }
            return n
        }
        func label(_ fallback: String = "section-intro") throws -> String {
            let name = value("name", fallback)
            guard name.range(of: "^[A-Za-z][A-Za-z0-9_-]*$", options: .regularExpression) != nil
            else {
                throw CommandError
                    .invalid(
                        localized("Start labels with an English letter; use letters, numbers, hyphens or underscores."),
                    )
            }
            return name
        }
        func amount(_ fallback: String, range: ClosedRange<Double> = 0 ... 200) throws -> String {
            let source = value("amount", fallback)
            guard source.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
                  let number = Double(source), range.contains(number)
            else {
                throw CommandError.invalid(L10n.format(
                    "Enter a number between %@ and %@.",
                    String(range.lowerBound),
                    String(range.upperBound),
                ))
            }
            return source
        }
        var literals: [(String, String)] = []
        func protect(_ value: String) -> String {
            let token = "LEFTBLANK_LITERAL_" + UUID().uuidString
            literals.append((token, value))
            return token
        }
        func snippet(_ marked: String) -> Snippet {
            literals.reduce(Snippet(marked)) { $0.replacingLiteral($1.0, with: $1.1) }
        }
        func math(_ marked: String, block: Bool = false) -> Snippet {
            snippet(context == .math ? marked : (block ? "$ \(marked) $" : "$\(marked)$"))
        }
        let selectedSource = protect(selection)
        let selected = selection.isEmpty ? placeholder("Text") : selectedSource
        switch id {
        case "heading": return try snippet(String(repeating: "=", count: number("level", "1", 1 ... 6)) + " " +
                (selection.isEmpty ? placeholder("Heading") : selectedSource))
        case "bold": return snippet("*\(selected)*")
        case "italic": return snippet("_\(selected)_")
        case "highlight": return snippet("#highlight[\(selected)]")
        case "underline", "strike", "smallcaps": return snippet("#\(id)[\(selected)]")
        case "superscript": return snippet("#super[\(selected)]")
        case "subscript": return snippet("#sub[\(selected)]")
        case "textColor":
            let color = value("color", "245c73").trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            guard color
                .range(of: "^(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$", options: .regularExpression) != nil
            else {
                throw CommandError.invalid(localized("Enter a 3-, 6- or 8-digit hexadecimal color, such as 245c73."))
            }
            return snippet("#text(fill: rgb(\(quoted(color))))[\(selected)]")
        case "math": return snippet("$\(selection.isEmpty ? "«x^2 + y^2»" : selectedSource)$")
        case "equation": return snippet("\n$ \(selection.isEmpty ? "«E = m c^2»" : selectedSource) $\n")
        case "bullet": return snippet(
                "- \(selection.isEmpty ? placeholder("First item") : selectedSource)\n- \(placeholder("Second item"))",
            )
        case "numbered": return snippet(
                "+ \(selection.isEmpty ? placeholder("First step") : selectedSource)\n+ \(placeholder("Second step"))",
            )
        case "terms": return snippet(
                "/ \(placeholder("Term")): \(selection.isEmpty ? placeholder("Definition") : selectedSource)",
            )
        case "lineBreak": return snippet("#linebreak()\n")
        case "quote": return snippet("#quote(block: true)[\n  \(selected)\n]")
        case "footnote": return snippet("#footnote[\(selected)]")
        case "label": return try snippet("<\(label())>")
        case "reference": return try snippet("@\(label())")
        case "link": return snippet("#link(\(protect(quoted(value("url", "https://typst.app")))))[\(selected)]")
        case "image": return snippet(
                "#figure(\n  image(\(protect(quoted(value("path", "images/figure.png")))), width: 80%),\n  caption: \(protect(quoted(value("caption", localized("Image caption"))))),\n)",
            )
        case "code":
            let language = value("language", "rust")
            guard language.range(of: "^[A-Za-z0-9_+-]*$", options: .regularExpression) != nil
            else {
                throw CommandError
                    .invalid(
                        localized(
                            "Code language names may contain letters, numbers, underscores, plus signs or hyphens.",
                        ),
                    )
            }
            let backticks = selection.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
            let fence = String(repeating: "`", count: max(3, backticks + 1))
            return snippet(
                "\(fence)\(language)\n\(selection.isEmpty ? placeholder("// Write code here") : selectedSource)\n\(fence)",
            )
        case "table":
            let columns = try number("columns", "3", 1 ... 8)
            let rows = try number("rows", "2", 1 ... 20)
            var source = "#table(\n  columns: \(columns),\n  inset: 10pt,\n  table.header(\(Array(1 ... columns).map { "[«\(localized("Heading")) \($0)»]" }.joined(separator: ", "))),\n"
            for row in 1 ...
                rows
            {
                source += "  " + (1 ... columns).map { "[«\(localized("Cell")) \(row).\($0)»]" }
                    .joined(separator: ", ") + ",\n"
            }
            return snippet(source + ")")
        case "paper":
            let paper = value("paper", "a4").lowercased()
            guard ["a4", "a5", "us-letter"].contains(paper)
            else {
                throw CommandError.invalid(localized("Choose a4, a5 or us-letter for the paper size."))
            }
            return snippet("#set page(paper: \(quoted(paper)))\n")
        case "margin": return try snippet("#set page(margin: \(number("margin", "24", 5 ... 80))mm)\n")
        case "fontSize": return try snippet("#set text(size: \(number("size", "11", 6 ... 72))pt)\n")
        case "pageNumber": return snippet("#set page(numbering: \"1\")\n")
        case "font": return snippet("#set text(font: \(protect(quoted(value("font", "Libertinus Serif")))))\n")
        case "language":
            let language = value(
                "language",
                AppLanguage.resolve(language ?? L10n.language) == .simplifiedChinese ? "zh" : "en",
            )
            guard language.range(of: "^[A-Za-z]{2,3}$", options: .regularExpression) != nil
            else {
                throw CommandError
                    .invalid(localized("Enter a two- or three-letter language code, such as en, zh or ja."))
            }
            return snippet("#set text(lang: \(quoted(language.lowercased())))\n")
        case "leading": return try snippet("#set par(leading: \(amount("0.65", range: 0 ... 10))em)\n")
        case "paragraphSpacing": return try snippet("#set par(spacing: \(amount("1.2", range: 0 ... 20))em)\n")
        case "firstLineIndent": return try snippet("#set par(first-line-indent: \(amount("2", range: 0 ... 20))em)\n")
        case "justify": return snippet("#set par(justify: true)\n")
        case "headingNumbering": return snippet("#set heading(numbering: \"1.1\")\n")
        case "equationNumbering": return snippet("#set math.equation(numbering: \"(1)\")\n")
        case "header",
             "footer": return snippet(
                "#set page(\(id): \(protect(quoted(value("text", id == "header" ? localized("Document title") : localized("Draft"))))))\n",
            )
        case "documentInfo": return snippet(
                "#set document(title: \(protect(quoted(value("title", localized("Untitled"))))), author: \(protect(quoted(value("author", localized("Author"))))))\n",
            )
        case "fraction": return math("frac(\(selection.isEmpty ? "«a»" : selectedSource), «b»)")
        case "squareRoot": return math("sqrt(\(selection.isEmpty ? "«x»" : selectedSource))")
        case "nthRoot": return math("root(«3», \(selection.isEmpty ? "«x»" : selectedSource))")
        case "power": return math("(\(selection.isEmpty ? "«x»" : selectedSource))^«2»")
        case "mathSubscript": return math("(\(selection.isEmpty ? "«x»" : selectedSource))_«i»")
        case "binomial": return math("binom(«n», «k»)")
        case "matrix": return math("mat(«1», «2»; «3», «4»)")
        case "vector": return math("vec(«x», «y», «z»)")
        case "cases": return math("f(x) = cases(«x» & \"if\" x >= 0, «-x» & \"otherwise\")", block: true)
        case "aligned": return math("«a» &= «b + c» \\\n  &= «d»", block: true)
        case "sum": return math("sum_(«k = 1»)^«n» «k^2»")
        case "integral": return math("integral_«0»^«1» «x» dif «x»")
        case "limit": return math("lim_(«x -> 0») «sin(x)/x»")
        case "greek": return math("«alpha» + «beta» = «gamma»")
        case "setMembership": return math("«x» in «RR»")
        case "arrow": return math("«A» arrow.r «B»")
        case "upright": return math("upright(\(selection.isEmpty ? "«m»" : selectedSource))")
        case "accent": return math("arrow(\(selection.isEmpty ? "«v»" : selectedSource))")
        case "align":
            let alignment = value("alignment", "center")
            guard ["left", "center", "right"].contains(alignment)
            else {
                throw CommandError.invalid(localized("Choose left, center or right."))
            }
            return snippet("#align(\(alignment))[\(selected)]")
        case "columns": return try snippet(
                "#columns(\(number("columns", "2", 2 ... 4)), gutter: 18pt)[\n  \(selected)\n]",
            )
        case "grid": return snippet(
                "#grid(\n  columns: (1fr, 1fr),\n  gutter: 12pt,\n  [\(placeholder("Left content"))], [\(placeholder("Right content"))],\n)",
            )
        case "block": return snippet("#block(fill: luma(95%), inset: 12pt, radius: 4pt)[\n  \(selected)\n]")
        case "padding": return try snippet("#pad(\(amount("12"))pt)[\(selected)]")
        case "stack": return snippet(
                "#stack(dir: ltr, spacing: 12pt, [\(placeholder("Left content"))], [\(placeholder("Right content"))])",
            )
        case "pageBreak": return snippet("#pagebreak()")
        case "verticalSpace": return try snippet("#v(\(amount("12"))pt)")
        case "horizontalSpace": return try snippet("#h(\(amount("12"))pt)")
        case "divider": return snippet("#line(length: 100%, stroke: 0.5pt)")
        case "contents": return snippet("#outline(title: \(quoted(localized("Contents"))))")
        case "bibliography": return snippet(
                "#bibliography(\(protect(quoted(value("path", "references.bib")))), style: \"ieee\")",
            )
        case "citation": return try snippet("#cite(<\(label("example"))>)")
        case "include": return snippet("#include \(protect(quoted(value("path", "section.typ"))))")
        case "import": return snippet("#import \(protect(quoted(value("path", "helpers.typ")))): *\n")
        case "variable":
            let name = try label("project")
            guard ![
                "let",
                "set",
                "show",
                "import",
                "include",
                "return",
                "break",
                "continue",
                "for",
                "while",
                "if",
                "else",
                "in",
                "as",
                "and",
                "or",
                "not",
                "true",
                "false",
                "none",
                "auto",
                "context",
            ].contains(name) else {
                throw CommandError.invalid(localized("Variable names cannot be Typst keywords."))
            }
            return snippet("#let \(name) = \(protect(quoted(value("value", "LeftBlank"))))\n")
        case "rawInline": return snippet(
                "#raw(\(selection.isEmpty ? "\"\(placeholder("Code"))\"" : protect(quoted(selection))))",
            )
        default: throw CommandError.invalid(localized("This command does not insert text."))
        }
    }
}
