use super::*;

fn named(tree: &LBSyntaxTree, start: usize, end: usize) -> Vec<(&'static str, u32, u32)> {
    tree.nodes(start, end)
        .iter()
        .map(|node| (kind_name(node.kind).unwrap_or("?"), node.start, node.end))
        .collect()
}

fn utf16(text: &str) -> Vec<u16> {
    text.encode_utf16().collect()
}

/// Deterministic xorshift64* so failures reproduce from the printed seed.
struct Random(u64);

impl Random {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn below(&mut self, bound: usize) -> usize {
        (self.next() % bound.max(1) as u64) as usize
    }
}

/// Markup, code, CJK, emoji, CRLF and unclosed delimiters, so random edits
/// open and close constructs and cross line endings.
const FRAGMENTS: &[&str] = &[
    "= 标题 😀\n",
    "== Section\r\n",
    "*粗体*",
    "_emph_",
    " ",
    "\n",
    "\r\n",
    "\n\n",
    "#item(\"LB-001\", \"标题\", \"done\")",
    "#let item(id, title, status) = [#id #title]\n",
    "#f[content *b*]",
    "#set text(size: 12pt)\n",
    "$x^2 + 中$",
    "```rust\nfn main() {}\n```",
    "`raw`",
    "- item\n",
    "+ enum\n",
    "/ term: desc\n",
    "@ref",
    "<label>",
    "https://typst.app",
    "// comment\n",
    "/* block */",
    "(",
    ")",
    "[",
    "]",
    "{",
    "}",
    "\"",
    "$",
    "*",
    "_",
    "#",
    "😀",
    "中文",
    "e\u{301}",
    "\\#",
    "--",
    "...",
];

fn random_text(random: &mut Random, pieces: usize) -> String {
    (0..pieces)
        .map(|_| FRAGMENTS[random.below(FRAGMENTS.len())])
        .collect()
}

/// The nearest offset at or after `offset` that does not split a surrogate pair.
fn boundary(units: &[u16], mut offset: usize) -> usize {
    while offset < units.len() && (0xDC00..0xE000).contains(&units[offset]) {
        offset += 1;
    }
    offset
}

#[test]
fn kind_codes_are_unique_named_and_stable() {
    let mut codes: Vec<u16> = KIND_NAMES.iter().map(|(code, _)| *code).collect();
    let mut names: Vec<&str> = KIND_NAMES.iter().map(|(_, name)| *name).collect();
    assert!(names
        .iter()
        .all(|name| name.ends_with('\0') && name.len() > 1));
    codes.sort_unstable();
    names.sort_unstable();
    codes.dedup();
    names.dedup();
    assert_eq!(codes.len(), KIND_NAMES.len(), "duplicate kind code");
    assert_eq!(names.len(), KIND_NAMES.len(), "duplicate kind name");
    assert!(
        !codes.contains(&0),
        "0 is reserved for kinds the Swift side does not know"
    );
    // Spot-check codes that LeftBlankCore and saved plans depend on.
    for (kind, expected) in [
        (SyntaxKind::Markup, 1),
        (SyntaxKind::Strong, 9),
        (SyntaxKind::Heading, 19),
        (SyntaxKind::Equation, 27),
        (SyntaxKind::Hash, 30),
        (SyntaxKind::Str, 56),
        (SyntaxKind::FuncCall, 65),
        (SyntaxKind::LetBinding, 70),
        (SyntaxKind::Error, 83),
        (SyntaxKind::DestructAssignment, 142),
    ] {
        assert_eq!(code(kind), expected, "{kind:?}");
        assert_eq!(kind_name(expected), Some(format!("{kind:?}").as_str()));
    }
    assert_eq!(kind_name(0), None);
    assert_eq!(kind_name(29), None);
    assert!(kind_name_c(500).is_null());
}

#[test]
fn utf16_offsets_cover_cjk_emoji_and_crlf() {
    let tree = LBSyntaxTree::parse("= 标题 😀\r\n*粗* _e_ #item(\"LB-001\", \"标题\")").unwrap();
    let nodes = named(&tree, 0, usize::MAX);
    assert!(nodes.contains(&("Heading", 0, 7)), "{nodes:?}");
    assert!(nodes.contains(&("Strong", 9, 12)), "{nodes:?}");
    assert!(nodes.contains(&("Emph", 13, 16)), "{nodes:?}");
    // `#` is a sibling of the embedded call: a chip spans Hash.start..FuncCall.end.
    assert!(nodes.contains(&("Hash", 17, 18)), "{nodes:?}");
    assert!(nodes.contains(&("FuncCall", 18, 38)), "{nodes:?}");
    assert!(nodes.contains(&("Str", 33, 37)), "{nodes:?}");
    assert_eq!(nodes[0], ("Markup", 0, 38));
    assert_eq!(tree.utf16_len(), 38);
    // Text and Space are not emitted; parents index the same array.
    let all = tree.nodes(0, usize::MAX);
    assert!(all.iter().all(|node| node.kind != 2 && node.kind != 3));
    assert_eq!(all[0].parent, NO_PARENT);
    for (index, node) in all.iter().enumerate().skip(1) {
        let parent = all[node.parent as usize];
        assert!((node.parent as usize) < index);
        assert!(parent.start <= node.start && node.end <= parent.end);
        assert_eq!(node.depth, parent.depth + 1);
    }
}

#[test]
fn errors_are_flagged_and_math_is_opaque() {
    let tree = LBSyntaxTree::parse("*open and $x^2$ #f(1,").unwrap();
    let nodes = tree.nodes(0, usize::MAX);
    assert_ne!(nodes[0].flags & ERRONEOUS, 0, "root contains an error");
    let equation = nodes.iter().position(|node| node.kind == 27).unwrap();
    assert_eq!(nodes[equation + 1].kind, 41, "dollar follows the equation");
    let math = nodes.iter().find(|node| node.kind == 28).unwrap();
    assert!(nodes
        .iter()
        .all(|node| node.parent == NO_PARENT || nodes[node.parent as usize] != *math));
    let tree = LBSyntaxTree::parse("*closed* $x$").unwrap();
    assert!(tree.nodes(0, usize::MAX).iter().all(|node| node.flags == 0));
}

#[test]
fn rejects_split_surrogates_and_out_of_range_edits() {
    let mut tree = LBSyntaxTree::parse("a😀b").unwrap();
    assert!(tree.edit(2, 2, "x").is_none());
    assert!(tree.edit(1, 2, "").is_none());
    assert!(tree.edit(2, 3, "").is_none());
    assert!(tree.edit(3, 2, "").is_none());
    assert!(tree.edit(0, 5, "").is_none());
    assert_eq!(tree.text(), "a😀b");
    assert!(tree.edit(1, 3, "中").is_some());
    assert_eq!(tree.text(), "a中b");
    // Windows round outward instead of failing.
    let tree = LBSyntaxTree::parse("*😀*").unwrap();
    assert_eq!(tree.byte_window(2, 2), 1..5);
    assert_eq!(named(&tree, 2, 2), named(&tree, 1, 3));
}

#[test]
fn window_matches_filtered_full_flatten() {
    let mut random = Random(0x5EED_0001);
    for _ in 0..40 {
        let text = random_text(&mut random, 120);
        let tree = LBSyntaxTree::parse(&text).unwrap();
        let units = utf16(&text);
        let all = tree.nodes(0, usize::MAX);
        for _ in 0..10 {
            let start = boundary(&units, random.below(units.len() + 1));
            let end = boundary(&units, start + random.below(200)).min(units.len());
            let window = tree.byte_window(start, end);
            let lines = tree.source.lines();
            let hit = |node: &LBSyntaxNode| {
                let (s, e) = (node.start as usize, node.end as usize);
                included(
                    lines.utf16_to_byte(s).unwrap(),
                    lines.utf16_to_byte(e).unwrap(),
                    &window,
                )
            };
            // A node is listed with its whole ancestor chain, never without its parent.
            let expected: Vec<_> = all
                .iter()
                .filter(|node| {
                    let mut current = **node;
                    loop {
                        if !hit(&current) {
                            return false;
                        }
                        if current.parent == NO_PARENT {
                            return true;
                        }
                        current = all[current.parent as usize];
                    }
                })
                .map(|node| (node.kind, node.start, node.end, node.depth, node.flags))
                .collect();
            let windowed = tree.nodes(start, end);
            for (index, node) in windowed.iter().enumerate() {
                assert!(node.parent == NO_PARENT || (node.parent as usize) < index);
            }
            let actual: Vec<_> = windowed
                .iter()
                .map(|node| (node.kind, node.start, node.end, node.depth, node.flags))
                .collect();
            assert_eq!(actual, expected, "window {start}..{end} of {text:?}");
        }
    }
}

#[test]
fn seeded_incremental_edits_match_a_fresh_parse() {
    for seed in [1u64, 0xC0FFEE, 0x1B019] {
        let mut random = Random(seed);
        let mut text = random_text(&mut random, 80);
        let mut tree = LBSyntaxTree::parse(&text).unwrap();
        for step in 0..400 {
            let mut units = utf16(&text);
            let start = boundary(&units, random.below(units.len() + 1));
            let end = boundary(&units, start + random.below(24)).min(units.len());
            let pieces = random.below(3);
            let with = random_text(&mut random, pieces);
            let reparsed = tree
                .edit(start, end, &with)
                .unwrap_or_else(|| panic!("seed {seed} step {step}: edit {start}..{end} rejected"));
            units.splice(start..end, with.encode_utf16());
            text = String::from_utf16(&units).unwrap();
            assert!(reparsed.start <= reparsed.end && reparsed.end <= units.len());
            assert_eq!(tree.text(), text, "seed {seed} step {step}");
            assert_eq!(
                tree.nodes(0, usize::MAX),
                LBSyntaxTree::parse(&text).unwrap().nodes(0, usize::MAX),
                "seed {seed} step {step}: incremental tree differs after {start}..{end} -> {with:?}"
            );
        }
    }
}

#[test]
fn deep_nesting_fits_a_secondary_thread_stack() {
    // Apple's secondary threads (GCD, Swift concurrency) default to 512 KiB.
    let text = "#{".repeat(400) + &"[*x*]".repeat(200) + &"}".repeat(400);
    std::thread::Builder::new()
        .stack_size(512 * 1024)
        .spawn(move || {
            let mut tree = LBSyntaxTree::parse(&text).unwrap();
            assert!(!tree.nodes(0, usize::MAX).is_empty());
            assert!(tree.edit(10, 10, "(").is_some());
            assert!(!tree.nodes(0, usize::MAX).is_empty());
        })
        .unwrap()
        .join()
        .unwrap();
}

#[test]
fn c_table_validates_every_input() {
    // SAFETY: exercising the documented C contract, including null and invalid inputs.
    unsafe {
        let api = &*lb_syntax_api();
        assert_eq!(api.abi_version, ABI_VERSION);
        assert_eq!(api.node_size, 16);
        assert_eq!(std::mem::size_of::<LBSyntaxNode>(), 16);
        assert!((api.parse)([0xFFu8].as_ptr(), 1).is_null(), "invalid UTF-8");
        assert!((api.parse)(std::ptr::null(), 3).is_null());
        let empty = (api.parse)(std::ptr::null(), 0);
        assert!(!empty.is_null());
        assert_eq!((api.utf16_length)(empty), 0);
        let mut count = 99;
        let nodes = (api.nodes)(empty, 0, u32::MAX, &mut count);
        assert_eq!(count, 1, "the empty root markup");
        (api.nodes_free)(nodes, count);
        (api.free)(empty);

        let source = "= 中文😀\r\n";
        let tree = (api.parse)(source.as_ptr(), source.len());
        assert_eq!((api.utf16_length)(tree), 8);
        let edit = |tree: *mut LBSyntaxTree, start: u32, end: u32, bytes: &[u8]| {
            let (mut first, mut last) = (0, 0);
            let ptr = bytes.as_ptr();
            (api.edit)(tree, start, end, ptr, bytes.len(), &mut first, &mut last)
                .then_some((first, last))
        };
        assert_eq!(edit(tree, 5, 5, b"x"), None, "splits the emoji");
        assert_eq!(edit(tree, 0, 0, &[0xC3]), None, "invalid UTF-8");
        assert_eq!(edit(std::ptr::null_mut(), 0, 0, b"x"), None);
        let with = "标题";
        let ptr = with.as_ptr();
        let null = std::ptr::null_mut();
        assert!((api.edit)(tree, 2, 4, ptr, with.len(), null, null));
        let (start, end) = edit(tree, 8, 8, b"*b*").unwrap();
        assert!(start <= 8 && end >= 11, "{start}..{end}");
        assert_eq!((*tree).text(), "= 标题😀\r\n*b*");
        assert!((api.nodes)(std::ptr::null(), 0, 1, &mut count).is_null());
        (*tree).poisoned = true;
        assert!((api.nodes)(tree, 0, 1, &mut count).is_null());
        assert_eq!(
            edit(tree, 0, 0, b"x"),
            None,
            "a poisoned tree stays unusable"
        );
        (api.free)(tree);
        (api.free)(std::ptr::null_mut());
        (api.nodes_free)(std::ptr::null_mut(), 0);
        assert_eq!((api.utf16_length)(std::ptr::null()), 0);

        let name = std::ffi::CStr::from_ptr((api.kind_name)(65));
        assert_eq!(name.to_str(), Ok("FuncCall"));
        assert!((api.kind_name)(0).is_null());
    }
}
