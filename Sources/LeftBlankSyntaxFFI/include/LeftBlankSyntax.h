// typst-syntax behind a small C ABI (Engine/SyntaxBridge).
//
// The macOS app links Engine/SyntaxBridge as a static library. On iPad the same
// code is part of the TinymistBridge engine library; the app passes
// lb_syntax_api() to LeftBlankCore at launch. Both reach the parser only
// through the function table below.
//
// All offsets are UTF-16 code units, compatible with NSString and NSRange.
// Offsets that would split a surrogate pair are rejected by edit and rounded
// outward by nodes. A tree is not thread-safe; one serial owner uses it.
#ifndef LEFTBLANK_SYNTAX_H
#define LEFTBLANK_SYNTAX_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#pragma clang assume_nonnull begin

// Increment whenever LBSyntaxAPI or LBSyntaxNode changes.
#define LB_SYNTAX_ABI_VERSION 1u
// LBSyntaxNode.parent when the node is the root.
#define LB_SYNTAX_NO_PARENT UINT32_MAX
// LBSyntaxNode.flags: the node or a descendant contains a syntax error.
#define LB_SYNTAX_NODE_ERRONEOUS 1u

typedef struct LBSyntaxTree LBSyntaxTree;

// One node of a pre-order flattened tree. Text and Space leaves are omitted,
// and Math nodes are opaque (their children are omitted).
typedef struct {
    uint32_t start;
    uint32_t end;
    // Index into the same array, or LB_SYNTAX_NO_PARENT.
    uint32_t parent;
    // Stable LeftBlank kind code; see kind_name. Append-only, never renumbered.
    uint16_t kind;
    // Depth below the root, saturating at 255.
    uint8_t depth;
    uint8_t flags;
} LBSyntaxNode;

typedef struct {
    uint32_t abi_version;
    // sizeof(LBSyntaxNode) as compiled into the library.
    uint32_t node_size;
    // Parses UTF-8 source. Returns NULL for invalid UTF-8. Release with free.
    LBSyntaxTree *_Nullable (*_Nonnull parse)(const uint8_t *_Nullable utf8, size_t length);
    void (*_Nonnull free)(LBSyntaxTree *_Nullable tree);
    // Replaces UTF-16 [start, end) with UTF-8 text and reparses incrementally.
    // On success writes the reparsed UTF-16 range of the new text and returns
    // true. Returns false, leaving the tree unchanged, for an invalid range or
    // invalid UTF-8. After a caught internal failure every later call fails;
    // parse the source again.
    bool (*_Nonnull edit)(LBSyntaxTree *_Nullable tree, uint32_t start, uint32_t end, const uint8_t *_Nullable utf8,
                 size_t length, uint32_t *_Nullable reparsed_start, uint32_t *_Nullable reparsed_end);
    // Nodes overlapping UTF-16 [start, end) in pre-order: a non-empty node that
    // intersects the window, or an empty node inside the closed window. An
    // empty window selects the nodes touching that point. A node is listed
    // only with its parent. end is clamped to the text length. Release with
    // nodes_free. NULL on failure.
    LBSyntaxNode *_Nullable (*_Nonnull nodes)(const LBSyntaxTree *_Nullable tree, uint32_t start, uint32_t end,
                                     size_t *_Nullable count);
    void (*_Nonnull nodes_free)(LBSyntaxNode *_Nullable nodes, size_t count);
    // UTF-16 length of the tree's current text, a cheap consistency check.
    uint32_t (*_Nonnull utf16_length)(const LBSyntaxTree *_Nullable tree);
    // Static NUL-terminated name of a kind code (typst-syntax's own name), or NULL.
    const char *_Nullable (*_Nonnull kind_name)(uint16_t kind);
} LBSyntaxAPI;

// The only exported symbol.
const LBSyntaxAPI *lb_syntax_api(void);

#pragma clang assume_nonnull end

#endif
