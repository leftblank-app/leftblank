//! typst-syntax behind a small, stable C ABI for LeftBlank's visual editor.
//!
//! Swift owns the text (`NSTextStorage`). This library owns one parsed
//! `typst_syntax::Source` per editor and mirrors the same edits the native text
//! view performs. Every offset crossing the boundary is a UTF-16 code unit,
//! matching `NSString`/`NSRange`; typst-syntax works in UTF-8 bytes and the
//! conversion happens here.
//!
//! Node kinds are mapped to LeftBlank's own stable codes (`kinds!`), so Swift
//! never depends on typst-syntax's enum order. The C declarations live in
//! `Sources/LeftBlankSyntaxFFI/include/LeftBlankSyntax.h`; the only exported
//! symbol is `lb_syntax_api`, a table of the entry points below.

#![deny(unsafe_op_in_unsafe_fn)]

use std::ffi::c_char;
use std::ops::Range;
use std::panic::{catch_unwind, AssertUnwindSafe};

use typst_syntax::{Source, SyntaxKind, SyntaxNode};

/// `LB_SYNTAX_ABI_VERSION`. Increment whenever `LBSyntaxAPI` or `LBSyntaxNode` changes.
pub const ABI_VERSION: u32 = 1;
/// `LB_SYNTAX_NO_PARENT`.
pub const NO_PARENT: u32 = u32::MAX;
/// `LB_SYNTAX_NODE_ERRONEOUS`.
pub const ERRONEOUS: u8 = 1;

/// One flattened syntax node; see `LeftBlankSyntax.h`.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct LBSyntaxNode {
    pub start: u32,
    pub end: u32,
    pub parent: u32,
    pub kind: u16,
    pub depth: u8,
    pub flags: u8,
}

/// The function table returned by `lb_syntax_api`.
#[repr(C)]
pub struct LBSyntaxAPI {
    pub abi_version: u32,
    pub node_size: u32,
    pub parse: unsafe extern "C" fn(*const u8, usize) -> *mut LBSyntaxTree,
    pub free: unsafe extern "C" fn(*mut LBSyntaxTree),
    pub edit: unsafe extern "C" fn(
        *mut LBSyntaxTree,
        u32,
        u32,
        *const u8,
        usize,
        *mut u32,
        *mut u32,
    ) -> bool,
    pub nodes: unsafe extern "C" fn(*const LBSyntaxTree, u32, u32, *mut usize) -> *mut LBSyntaxNode,
    pub nodes_free: unsafe extern "C" fn(*mut LBSyntaxNode, usize),
    pub utf16_length: unsafe extern "C" fn(*const LBSyntaxTree) -> u32,
    pub kind_name: extern "C" fn(u16) -> *const c_char,
}

macro_rules! kinds {
    ($($code:literal => $kind:ident),* $(,)?) => {
        /// The stable LeftBlank code of a typst-syntax kind. The match is
        /// exhaustive, so a parser upgrade that adds a kind fails to compile
        /// until it is given a new code.
        pub fn code(kind: SyntaxKind) -> u16 {
            match kind {
                $(SyntaxKind::$kind => $code,)*
            }
        }

        /// Every code with its NUL-terminated typst-syntax name.
        pub const KIND_NAMES: &[(u16, &str)] = &[$(($code, concat!(stringify!($kind), "\0")),)*];
    };
}

// Stable LeftBlank codes. Append only; never renumber or reuse a code.
// LeftBlankCore's `SyntaxKind` mirrors this table; its tests compare the two.
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
    87 => Let, 88 => Set, 89 => Show, 90 => Import, 91 => Include, 92 => End,
    93 => Shebang, 94 => MathText, 95 => MathIdent, 96 => MathFieldAccess,
    97 => MathShorthand, 98 => MathAlignPoint, 99 => MathCall, 100 => MathArgs,
    101 => MathDelimited, 102 => MathAttach, 103 => MathPrimes, 104 => MathFrac,
    105 => MathRoot, 106 => Plus, 107 => Minus, 108 => Slash, 109 => Hat, 110 => EqEq,
    111 => ExclEq, 112 => Lt, 113 => LtEq, 114 => Gt, 115 => GtEq, 116 => PlusEq,
    117 => HyphEq, 118 => StarEq, 119 => SlashEq, 120 => Arrow, 121 => Root, 122 => Bang,
    123 => Not, 124 => And, 125 => Or, 126 => Context, 127 => If, 128 => Else, 129 => For,
    130 => In, 131 => While, 132 => Break, 133 => Continue, 134 => Return, 135 => As,
    136 => ImportItems, 137 => ImportItemPath, 138 => RenamedImportItem, 139 => LoopBreak,
    140 => LoopContinue, 141 => FuncReturn, 142 => DestructAssignment,
}

/// The typst-syntax name of a LeftBlank kind code.
pub fn kind_name(code: u16) -> Option<&'static str> {
    KIND_NAMES
        .iter()
        .find(|(value, _)| *value == code)
        .map(|(_, name)| name.trim_end_matches('\0'))
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

/// Whether a node `[start, end)` belongs to a window query; see the header.
fn included(start: usize, end: usize, window: &Range<usize>) -> bool {
    if start == end {
        window.start <= start && start <= window.end
    } else if window.start == window.end {
        start <= window.start && window.start <= end
    } else {
        start < window.end && end > window.start
    }
}

/// An open inner node during the iterative pre-order walk.
struct Frame<'a> {
    children: std::slice::Iter<'a, SyntaxNode>,
    /// Byte offset of the next child.
    byte: usize,
    end: usize,
    index: Option<usize>,
    /// Depth and parent index given to the children.
    depth: u8,
    parent: u32,
}

pub struct LBSyntaxTree {
    source: Source,
    /// Set while typst-syntax mutates the tree, so a caught panic leaves it unusable.
    poisoned: bool,
}

impl LBSyntaxTree {
    /// Parses text whose UTF-8 length fits the ABI's 32-bit offsets.
    pub fn parse(text: &str) -> Option<Self> {
        (text.len() < u32::MAX as usize).then(|| Self {
            source: Source::detached(text),
            poisoned: false,
        })
    }

    pub fn text(&self) -> &str {
        self.source.text()
    }

    pub fn utf16_len(&self) -> usize {
        self.source.lines().len_utf16()
    }

    /// The byte offset of a UTF-16 offset, rejecting one that splits a
    /// surrogate pair (typst-syntax would round it silently).
    fn exact_byte(&self, utf16: usize) -> Option<usize> {
        let lines = self.source.lines();
        let byte = lines.utf16_to_byte(utf16)?;
        (lines.byte_to_utf16(byte)? == utf16).then_some(byte)
    }

    /// The UTF-16 window as bytes, clamped and rounded outward.
    fn byte_window(&self, start16: usize, end16: usize) -> Range<usize> {
        let lines = self.source.lines();
        let length = lines.len_utf16();
        let start16 = start16.min(length);
        let end16 = end16.clamp(start16, length);
        let ceil = |utf16: usize| lines.utf16_to_byte(utf16).unwrap_or(lines.len_bytes());
        let mut start = ceil(start16);
        if lines.byte_to_utf16(start) != Some(start16) {
            // Inside a surrogate pair: back up to the start of its 4-byte character.
            start -= 4;
        }
        start..ceil(end16).max(start)
    }

    /// Nodes in the UTF-16 window, in pre-order; see the header for the rule.
    pub fn nodes(&self, start16: usize, end16: usize) -> Vec<LBSyntaxNode> {
        let window = self.byte_window(start16, end16);
        let lines = self.source.lines();
        let utf16_at = |byte: usize| lines.byte_to_utf16(byte).unwrap_or(0);
        let mut out: Vec<LBSyntaxNode> = Vec::new();
        let mut stack: Vec<Frame> = Vec::new();
        // The UTF-16 offset just after the last visited node, while the walk
        // has been contiguous. Skipping a subtree forgets it.
        let mut known: Option<usize> = Some(0);
        let mut pending = Some((self.source.root(), 0usize, 0u8, NO_PARENT));
        loop {
            if let Some((node, byte, depth, parent)) = pending.take() {
                let end = byte + node.len();
                if !included(byte, end, &window) {
                    if end > byte {
                        known = None;
                    }
                } else {
                    let start16 = known.unwrap_or_else(|| utf16_at(byte));
                    let kind = node.kind();
                    let index = (!skipped(kind)).then(|| {
                        out.push(LBSyntaxNode {
                            start: start16 as u32,
                            end: start16 as u32,
                            parent,
                            kind: code(kind),
                            depth,
                            flags: if node.diagnosis().errors {
                                ERRONEOUS
                            } else {
                                0
                            },
                        });
                        out.len() - 1
                    });
                    if node.children().len() == 0 || opaque(kind) {
                        let end16 = if node.children().len() == 0 {
                            start16 + node.leaf_text().encode_utf16().count()
                        } else {
                            utf16_at(end)
                        };
                        if let Some(index) = index {
                            out[index].end = end16 as u32;
                        }
                        known = Some(end16);
                    } else {
                        known = Some(start16);
                        stack.push(Frame {
                            children: node.children(),
                            byte,
                            end,
                            index,
                            depth: depth.saturating_add(1),
                            parent: index.map_or(parent, |index| index as u32),
                        });
                    }
                }
            }
            let Some(frame) = stack.last_mut() else { break };
            match frame.children.next() {
                Some(child) if frame.byte <= window.end => {
                    pending = Some((child, frame.byte, frame.depth, frame.parent));
                    frame.byte += child.len();
                }
                _ => {
                    // All children visited, or the rest start after the window.
                    let frame = stack.pop().expect("open frame");
                    let contiguous = frame.byte == frame.end && frame.children.len() == 0;
                    let end16 = match known {
                        Some(value) if contiguous => value,
                        _ => utf16_at(frame.end),
                    };
                    if let Some(index) = frame.index {
                        out[index].end = end16 as u32;
                    }
                    known = Some(end16);
                }
            }
        }
        out
    }

    /// Replaces a UTF-16 range; returns the reparsed UTF-16 range in the new text.
    pub fn edit(&mut self, start16: usize, end16: usize, with: &str) -> Option<Range<usize>> {
        if self.poisoned || start16 > end16 {
            return None;
        }
        let start = self.exact_byte(start16)?;
        let end = self.exact_byte(end16)?;
        if self.source.text().len() - (end - start) + with.len() >= u32::MAX as usize {
            return None;
        }
        self.poisoned = true;
        let reparsed = self.source.edit(start..end, with);
        self.poisoned = false;
        let lines = self.source.lines();
        Some(lines.byte_to_utf16(reparsed.start)?..lines.byte_to_utf16(reparsed.end)?)
    }
}

fn guarded<T>(fallback: T, body: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(fallback)
}

/// # Safety
/// `utf8` must be null or valid for `length` bytes.
unsafe fn text<'a>(utf8: *const u8, length: usize) -> Option<&'a str> {
    if length == 0 {
        return Some("");
    }
    if utf8.is_null() {
        return None;
    }
    // SAFETY: the caller guarantees `length` readable bytes.
    std::str::from_utf8(unsafe { std::slice::from_raw_parts(utf8, length) }).ok()
}

/// # Safety
/// See `LeftBlankSyntax.h`. `utf8` must be null or valid for `length` bytes.
unsafe extern "C" fn parse(utf8: *const u8, length: usize) -> *mut LBSyntaxTree {
    guarded(std::ptr::null_mut(), || {
        // SAFETY: forwarded caller contract.
        match unsafe { text(utf8, length) }.and_then(LBSyntaxTree::parse) {
            Some(tree) => Box::into_raw(Box::new(tree)),
            None => std::ptr::null_mut(),
        }
    })
}

/// # Safety
/// `tree` must be null or come from `parse` and not be used afterwards.
unsafe extern "C" fn free(tree: *mut LBSyntaxTree) {
    if !tree.is_null() {
        guarded((), || {
            // SAFETY: the caller transfers a tree created by `parse`.
            drop(unsafe { Box::from_raw(tree) })
        });
    }
}

/// # Safety
/// `tree` must be null or a live tree with no other concurrent use; `utf8`
/// must be null or valid for `length` bytes; output pointers may be null.
unsafe extern "C" fn edit(
    tree: *mut LBSyntaxTree,
    start: u32,
    end: u32,
    utf8: *const u8,
    length: usize,
    reparsed_start: *mut u32,
    reparsed_end: *mut u32,
) -> bool {
    guarded(false, || {
        // SAFETY: forwarded caller contract.
        let (Some(tree), Some(with)) = (unsafe { tree.as_mut() }, unsafe { text(utf8, length) })
        else {
            return false;
        };
        let Some(range) = tree.edit(start as usize, end as usize, with) else {
            return false;
        };
        // SAFETY: output pointers are null or writable.
        unsafe {
            if let Some(out) = reparsed_start.as_mut() {
                *out = range.start as u32;
            }
            if let Some(out) = reparsed_end.as_mut() {
                *out = range.end as u32;
            }
        }
        true
    })
}

/// # Safety
/// `tree` must be null or a live tree; `count` must be null or writable.
unsafe extern "C" fn nodes(
    tree: *const LBSyntaxTree,
    start: u32,
    end: u32,
    count: *mut usize,
) -> *mut LBSyntaxNode {
    guarded(std::ptr::null_mut(), || {
        // SAFETY: forwarded caller contract.
        let Some(tree) = (unsafe { tree.as_ref() }) else {
            return std::ptr::null_mut();
        };
        if tree.poisoned {
            return std::ptr::null_mut();
        }
        let nodes = tree.nodes(start as usize, end as usize).into_boxed_slice();
        // SAFETY: `count` is null or writable.
        if let Some(out) = unsafe { count.as_mut() } {
            *out = nodes.len();
        }
        Box::into_raw(nodes) as *mut LBSyntaxNode
    })
}

/// # Safety
/// `nodes` must be null or come from `nodes` with the `count` it reported.
unsafe extern "C" fn nodes_free(nodes: *mut LBSyntaxNode, count: usize) {
    if !nodes.is_null() {
        // SAFETY: the caller returns the boxed slice `nodes` allocated.
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(nodes, count)) });
    }
}

/// # Safety
/// `tree` must be null or a live tree.
unsafe extern "C" fn utf16_length(tree: *const LBSyntaxTree) -> u32 {
    // SAFETY: forwarded caller contract.
    guarded(0, || {
        unsafe { tree.as_ref() }.map_or(0, |tree| tree.utf16_len() as u32)
    })
}

extern "C" fn kind_name_c(code: u16) -> *const c_char {
    KIND_NAMES
        .iter()
        .find(|(value, _)| *value == code)
        .map_or(std::ptr::null(), |(_, name)| name.as_ptr() as *const c_char)
}

static API: LBSyntaxAPI = LBSyntaxAPI {
    abi_version: ABI_VERSION,
    node_size: std::mem::size_of::<LBSyntaxNode>() as u32,
    parse,
    free,
    edit,
    nodes,
    nodes_free,
    utf16_length,
    kind_name: kind_name_c,
};

/// The parser's C function table. The only exported symbol.
#[no_mangle]
pub extern "C" fn lb_syntax_api() -> *const LBSyntaxAPI {
    &API
}

#[cfg(test)]
mod tests;
