//! LB-019 spike: typst-syntax behind a small, stable C ABI.
//!
//! Swift owns the text (NSTextStorage). This library owns one parsed
//! `typst_syntax::Source` per editor, kept in sync through the same edits the
//! native text view performs. All offsets crossing the boundary are UTF-16
//! code units, matching NSString/NSRange; typst-syntax uses UTF-8 bytes
//! internally and the conversion happens here.
//!
//! Node kinds are mapped to LeftBlank's own stable codes (`KINDS`), so Swift
//! does not depend on typst-syntax's private enum numbering.

use std::ffi::c_char;
use std::ops::Range;
use std::panic::{catch_unwind, AssertUnwindSafe};

use typst_syntax::{Source, SyntaxKind, SyntaxNode};

/// One flattened syntax node. `parent` indexes the same output array, or is
/// `u32::MAX` when the parent is outside the requested window.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct LBSyntaxNode {
    pub start: u32,
    pub end: u32,
    pub parent: u32,
    pub kind: u16,
    pub depth: u8,
    /// Bit 0: the node or a descendant is erroneous.
    pub flags: u8,
}

pub struct LBSyntaxTree {
    source: Source,
}

macro_rules! kinds {
    ($($code:literal => $kind:ident),* $(,)?) => {
        fn code(kind: SyntaxKind) -> u16 {
            match kind {
                $(SyntaxKind::$kind => $code,)*
                _ => 0,
            }
        }
        const KIND_NAMES: &[(u16, &str)] = &[$(($code, concat!(stringify!($kind), "\0")),)*];
    };
}

// Stable LeftBlank codes. Append only; never renumber.
kinds! {
    1 => Markup, 2 => Text, 3 => Space, 4 => Linebreak, 5 => Parbreak, 6 => Escape,
    7 => Shorthand, 8 => SmartQuote, 9 => Strong, 10 => Emph, 11 => Raw, 12 => RawLang,
    13 => RawDelim, 14 => RawTrimmed, 15 => Link, 16 => Label, 17 => Ref, 18 => RefMarker,
    19 => Heading, 20 => HeadingMarker, 21 => ListItem, 22 => ListMarker, 23 => EnumItem,
    24 => EnumMarker, 25 => TermItem, 26 => TermMarker, 27 => Equation, 28 => Math,
    30 => Hash, 31 => LeftBrace, 32 => RightBrace, 33 => LeftBracket, 34 => RightBracket,
    35 => LeftParen, 36 => RightParen, 37 => Comma, 38 => Colon, 39 => Star,
    40 => Underscore, 41 => Dollar, 42 => Semicolon, 43 => Eq, 44 => Dot, 45 => Dots,
    50 => Code, 51 => Ident, 52 => Bool, 53 => Int, 54 => Float, 55 => Numeric, 56 => Str,
    57 => CodeBlock, 58 => ContentBlock, 59 => Parenthesized, 60 => Array, 61 => Dict,
    62 => Named, 63 => Keyed, 64 => FieldAccess, 65 => FuncCall, 66 => Args, 67 => Spread,
    68 => Closure, 69 => Params, 70 => LetBinding, 71 => SetRule, 72 => ShowRule,
    73 => ModuleImport, 74 => ModuleInclude, 75 => Conditional, 76 => WhileLoop,
    77 => ForLoop, 78 => Contextual, 79 => Unary, 80 => Binary, 81 => LineComment,
    82 => BlockComment, 83 => Error, 84 => None, 85 => Auto, 86 => Destructuring,
    87 => Let, 88 => Set, 89 => Show, 90 => Import, 91 => Include,
}

/// Leaves that carry no presentation structure. Their text still advances
/// offsets; they are simply not emitted.
fn skipped(kind: SyntaxKind) -> bool {
    matches!(kind, SyntaxKind::Text | SyntaxKind::Space)
}

/// Equation internals are rendered by the engine, never by the editor.
fn opaque(kind: SyntaxKind) -> bool {
    matches!(kind, SyntaxKind::Math)
}

fn utf16_len(node: &SyntaxNode) -> usize {
    if node.children().as_slice().is_empty() {
        node.leaf_text().encode_utf16().count()
    } else {
        node.children().map(utf16_len).sum()
    }
}

struct Flattener<'a> {
    source: &'a Source,
    window: Range<usize>, // bytes
    out: Vec<LBSyntaxNode>,
    utf16: Option<usize>,
}

impl Flattener<'_> {
    fn visit(&mut self, node: &SyntaxNode, byte: usize, depth: u8, parent: u32) {
        let end = byte + node.len();
        // Skip whole subtrees outside the window by byte length (O(1)).
        let overlaps = end > self.window.start && byte < self.window.end
            || (node.is_empty() && byte >= self.window.start && byte <= self.window.end);
        if !overlaps {
            if byte >= self.window.end {
                return;
            }
            self.utf16 = None;
            return;
        }
        let start16 = match self.utf16 {
            Some(value) => value,
            None => self.source.lines().byte_to_utf16(byte).unwrap_or(0),
        };
        let kind = node.kind();
        let leaf = node.children().as_slice().is_empty();
        let emit = !skipped(kind);
        let index = self.out.len() as u32;
        if emit {
            self.out.push(LBSyntaxNode {
                start: start16 as u32,
                end: start16 as u32,
                parent,
                kind: code(kind),
                depth,
                flags: node.diagnosis().errors as u8,
            });
        }
        let end16 = if leaf {
            start16 + node.leaf_text().encode_utf16().count()
        } else if opaque(kind) {
            start16 + utf16_len(node)
        } else {
            self.utf16 = Some(start16);
            let mut offset = byte;
            let next_parent = if emit { index } else { parent };
            for child in node.children() {
                if offset >= self.window.end {
                    break;
                }
                self.visit(child, offset, depth.saturating_add(1), next_parent);
                offset += child.len();
            }
            match self.utf16 {
                Some(value) if offset == end => value,
                _ => self.source.lines().byte_to_utf16(end).unwrap_or(start16),
            }
        };
        if emit {
            self.out[index as usize].end = end16 as u32;
        }
        self.utf16 = Some(end16);
    }
}

impl LBSyntaxTree {
    pub fn parse(text: &str) -> Self {
        Self {
            source: Source::detached(text),
        }
    }

    pub fn text(&self) -> &str {
        self.source.text()
    }

    /// Rejects offsets that split a surrogate pair (typst-syntax rounds them).
    fn byte(&self, utf16: usize) -> Option<usize> {
        let lines = self.source.lines();
        let byte = lines.utf16_to_byte(utf16)?;
        (lines.byte_to_utf16(byte)? == utf16).then_some(byte)
    }

    /// Nodes overlapping the UTF-16 window, in pre-order.
    pub fn nodes(&self, start16: usize, end16: usize) -> Vec<LBSyntaxNode> {
        let lines = self.source.lines();
        let length = lines.len_utf16();
        let start = self.byte(start16.min(length)).unwrap_or(0);
        let end = self.byte(end16.min(length)).unwrap_or(lines.len_bytes());
        let mut flattener = Flattener {
            source: &self.source,
            window: start..end.max(start),
            out: Vec::new(),
            utf16: Some(0),
        };
        flattener.visit(self.source.root(), 0, 0, u32::MAX);
        flattener.out
    }

    /// Replace a UTF-16 range; returns the reparsed UTF-16 range in the new text.
    pub fn edit(&mut self, start16: usize, end16: usize, with: &str) -> Option<Range<usize>> {
        let start = self.byte(start16)?;
        let end = self.byte(end16)?;
        if start > end {
            return None;
        }
        let reparsed = self.source.edit(start..end, with);
        let lines = self.source.lines();
        Some(lines.byte_to_utf16(reparsed.start)?..lines.byte_to_utf16(reparsed.end)?)
    }
}

fn guarded<T>(fallback: T, body: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(fallback)
}

unsafe fn text<'a>(utf8: *const u8, length: usize) -> Option<&'a str> {
    if length == 0 {
        return Some("");
    }
    if utf8.is_null() {
        return None;
    }
    std::str::from_utf8(std::slice::from_raw_parts(utf8, length)).ok()
}

/// Parses UTF-8 source. Returns null for invalid UTF-8. Free with `lb_syntax_free`.
///
/// # Safety
/// Pointers must be null or valid for the documented lengths; a tree pointer
/// must come from `lb_syntax_parse` and not be used after `lb_syntax_free`.
#[no_mangle]
pub unsafe extern "C" fn lb_syntax_parse(utf8: *const u8, length: usize) -> *mut LBSyntaxTree {
    guarded(std::ptr::null_mut(), || match text(utf8, length) {
        Some(text) => Box::into_raw(Box::new(LBSyntaxTree::parse(text))),
        None => std::ptr::null_mut(),
    })
}

///
/// # Safety
/// Pointers must be null or valid for the documented lengths; a tree pointer
/// must come from `lb_syntax_parse` and not be used after `lb_syntax_free`.
#[no_mangle]
pub unsafe extern "C" fn lb_syntax_free(tree: *mut LBSyntaxTree) {
    if !tree.is_null() {
        drop(Box::from_raw(tree));
    }
}

/// Applies one replacement of UTF-16 `[start, end)`. On success writes the
/// reparsed UTF-16 range of the new text and returns true.
///
/// # Safety
/// Pointers must be null or valid for the documented lengths; a tree pointer
/// must come from `lb_syntax_parse` and not be used after `lb_syntax_free`.
#[no_mangle]
pub unsafe extern "C" fn lb_syntax_edit(
    tree: *mut LBSyntaxTree,
    start: u32,
    end: u32,
    utf8: *const u8,
    length: usize,
    reparsed_start: *mut u32,
    reparsed_end: *mut u32,
) -> bool {
    guarded(false, || {
        let (Some(tree), Some(with)) = (tree.as_mut(), text(utf8, length)) else {
            return false;
        };
        match tree.edit(start as usize, end as usize, with) {
            Some(range) => {
                if let Some(out) = reparsed_start.as_mut() {
                    *out = range.start as u32;
                }
                if let Some(out) = reparsed_end.as_mut() {
                    *out = range.end as u32;
                }
                true
            }
            None => false,
        }
    })
}

/// Copies nodes overlapping UTF-16 `[start, end)` into `out` (pre-order).
/// Returns the total count; call with `capacity == 0` to size the buffer.
///
/// # Safety
/// Pointers must be null or valid for the documented lengths; a tree pointer
/// must come from `lb_syntax_parse` and not be used after `lb_syntax_free`.
#[no_mangle]
pub unsafe extern "C" fn lb_syntax_nodes(
    tree: *const LBSyntaxTree,
    start: u32,
    end: u32,
    out: *mut LBSyntaxNode,
    capacity: usize,
) -> usize {
    guarded(0, || {
        let Some(tree) = tree.as_ref() else { return 0 };
        let nodes = tree.nodes(start as usize, end as usize);
        if !out.is_null() && capacity > 0 {
            let count = nodes.len().min(capacity);
            std::ptr::copy_nonoverlapping(nodes.as_ptr(), out, count);
        }
        nodes.len()
    })
}

/// Single-pass variant: returns an owned buffer of nodes overlapping UTF-16
/// `[start, end)`. Release it with `lb_syntax_nodes_release`.
///
/// # Safety
/// Pointers must be null or valid for the documented lengths; a tree pointer
/// must come from `lb_syntax_parse` and not be used after `lb_syntax_free`.
#[no_mangle]
pub unsafe extern "C" fn lb_syntax_nodes_copy(
    tree: *const LBSyntaxTree,
    start: u32,
    end: u32,
    count: *mut usize,
) -> *mut LBSyntaxNode {
    guarded(std::ptr::null_mut(), || {
        let Some(tree) = tree.as_ref() else {
            return std::ptr::null_mut();
        };
        let nodes = tree.nodes(start as usize, end as usize).into_boxed_slice();
        if let Some(out) = count.as_mut() {
            *out = nodes.len();
        }
        Box::into_raw(nodes) as *mut LBSyntaxNode
    })
}

///
/// # Safety
/// Pointers must be null or valid for the documented lengths; a tree pointer
/// must come from `lb_syntax_parse` and not be used after `lb_syntax_free`.
#[no_mangle]
pub unsafe extern "C" fn lb_syntax_nodes_release(nodes: *mut LBSyntaxNode, count: usize) {
    if !nodes.is_null() {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
            nodes, count,
        )));
    }
}

/// UTF-16 length of the tree's current text (a cheap consistency check).
///
/// # Safety
/// Pointers must be null or valid for the documented lengths; a tree pointer
/// must come from `lb_syntax_parse` and not be used after `lb_syntax_free`.
#[no_mangle]
pub unsafe extern "C" fn lb_syntax_utf16_length(tree: *const LBSyntaxTree) -> u32 {
    tree.as_ref()
        .map_or(0, |tree| tree.source.lines().len_utf16() as u32)
}

/// Static NUL-terminated name of a LeftBlank kind code, or null.
#[no_mangle]
pub extern "C" fn lb_syntax_kind_name(code: u16) -> *const c_char {
    KIND_NAMES
        .iter()
        .find(|(value, _)| *value == code)
        .map_or(std::ptr::null(), |(_, name)| name.as_ptr() as *const c_char)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(tree: &LBSyntaxTree) -> Vec<(&'static str, u32, u32)> {
        tree.nodes(0, usize::MAX)
            .iter()
            .map(|node| {
                let name = KIND_NAMES
                    .iter()
                    .find(|(c, _)| *c == node.kind)
                    .map_or("Other\0", |(_, n)| n);
                (name.trim_end_matches('\0'), node.start, node.end)
            })
            .collect()
    }

    #[test]
    fn utf16_offsets_cover_cjk_and_emoji() {
        let tree = LBSyntaxTree::parse("= 标题 😀\n*粗* _e_ #item(\"LB-001\", \"标题\")");
        let nodes = kinds(&tree);
        assert!(nodes.contains(&("Heading", 0, 7)), "{nodes:?}");
        assert!(nodes.contains(&("Strong", 8, 11)), "{nodes:?}");
        // `#` is a sibling of the embedded call: a chip spans Hash.start..FuncCall.end.
        assert!(nodes.contains(&("Hash", 16, 17)), "{nodes:?}");
        assert!(nodes.contains(&("FuncCall", 17, 37)), "{nodes:?}");
        assert!(nodes.contains(&("Str", 32, 36)), "{nodes:?}");
    }

    #[test]
    fn window_matches_full_flatten() {
        let text = "= A\n\nSome *b* and #f(1, x: [y]).\n\n- item @ref <lab>\n".repeat(50);
        let tree = LBSyntaxTree::parse(&text);
        let all = tree.nodes(0, usize::MAX);
        let (start, end) = (400usize, 900usize);
        let window = tree.nodes(start, end);
        let expected: Vec<_> = all
            .iter()
            .filter(|n| (n.end as usize) > start && (n.start as usize) < end)
            .map(|n| (n.kind, n.start, n.end))
            .collect();
        let actual: Vec<_> = window.iter().map(|n| (n.kind, n.start, n.end)).collect();
        assert_eq!(actual, expected);
    }

    #[test]
    fn incremental_edit_matches_fresh_parse() {
        let mut text =
            "= 第一章\n\n正文 *重点* 和 #item(\"LB-001\", \"标题\", \"done\")。\n".repeat(200);
        let mut tree = LBSyntaxTree::parse(&text);
        let edits = [
            (10usize, 10usize, "插入"),
            (100, 104, ""),
            (500, 500, "*新*"),
            (40, 41, "#f("),
        ];
        for (start, end, with) in edits {
            let range = tree.edit(start, end, with).expect("edit");
            let mut units: Vec<u16> = text.encode_utf16().collect();
            units.splice(start..end, with.encode_utf16());
            text = String::from_utf16(&units).expect("utf16");
            assert!(range.end <= units.len());
            assert_eq!(tree.text(), text);
            assert_eq!(
                tree.nodes(0, usize::MAX),
                LBSyntaxTree::parse(&text).nodes(0, usize::MAX)
            );
        }
    }

    #[test]
    fn rejects_split_surrogate_offsets() {
        let mut tree = LBSyntaxTree::parse("a😀b");
        assert!(tree.edit(2, 2, "x").is_none());
        assert!(tree.edit(3, 3, "x").is_some());
    }
}
