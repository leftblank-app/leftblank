// LB-019 spike: typst-syntax C ABI shared by the macOS app and the iPad engine.
// All offsets are UTF-16 code units (NSRange-compatible).
#ifndef LEFTBLANK_SYNTAX_H
#define LEFTBLANK_SYNTAX_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct LBSyntaxTree LBSyntaxTree;

typedef struct {
    uint32_t start;
    uint32_t end;
    uint32_t parent; // index into the same array, UINT32_MAX if outside it
    uint16_t kind;   // stable LeftBlank kind code, see lb_syntax_kind_name
    uint8_t depth;
    uint8_t flags;   // bit 0: erroneous
} LBSyntaxNode;

LBSyntaxTree *lb_syntax_parse(const uint8_t *utf8, size_t length);
void lb_syntax_free(LBSyntaxTree *tree);
bool lb_syntax_edit(LBSyntaxTree *tree, uint32_t start, uint32_t end, const uint8_t *utf8, size_t length,
                    uint32_t *reparsed_start, uint32_t *reparsed_end);
size_t lb_syntax_nodes(const LBSyntaxTree *tree, uint32_t start, uint32_t end, LBSyntaxNode *out, size_t capacity);
LBSyntaxNode *lb_syntax_nodes_copy(const LBSyntaxTree *tree, uint32_t start, uint32_t end, size_t *count);
void lb_syntax_nodes_release(LBSyntaxNode *nodes, size_t count);
uint32_t lb_syntax_utf16_length(const LBSyntaxTree *tree);
const char *lb_syntax_kind_name(uint16_t code);

#endif
