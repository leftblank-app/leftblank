#ifndef LEFTBLANK_TINYMIST_H
#define LEFTBLANK_TINYMIST_H

#include <stdint.h>

// Runs Tinymist 0.15.8 inside the caller's process. Call on a worker thread.
// Transfers ownership of two distinct, valid file descriptors to the engine.
// The caller speaks the same Content-Length framed LSP as the macOS app.
// The optional UTF-8 font directory is copied before the server starts.
// Returns 0 on normal shutdown, 1 on an engine error, 2 on a caught panic.
int32_t leftblank_tinymist_run(int32_t input_fd, int32_t output_fd,
                             const char *font_directory);

// LeftBlank's typst-syntax table (LBSyntaxAPI in LeftBlankCore's
// LeftBlankSyntax.h), bundled in the same library. Pass it to
// SyntaxTree.install before parsing.
const void *leftblank_tinymist_syntax_api(void);

#endif
