// Header-only module for the parser C ABI. The implementation is Rust
// (Engine/SyntaxBridge); this file pins the layout Swift and Rust agree on.
#include "LeftBlankSyntax.h"

_Static_assert(sizeof(LBSyntaxNode) == 16, "LBSyntaxNode layout is part of the ABI");
_Static_assert(offsetof(LBSyntaxNode, kind) == 12, "LBSyntaxNode layout is part of the ABI");
_Static_assert(offsetof(LBSyntaxNode, flags) == 15, "LBSyntaxNode layout is part of the ABI");
_Static_assert(offsetof(LBSyntaxAPI, parse) == 8, "LBSyntaxAPI layout is part of the ABI");
