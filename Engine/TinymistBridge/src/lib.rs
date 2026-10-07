//! In-process transport for the same Tinymist engine used by the macOS app.
//! No subprocess, shell, global stdin/stdout, or working-directory changes.

#![deny(unsafe_op_in_unsafe_fn)]

use std::ffi::{c_char, CStr};
use std::fs::File;
use std::io::{BufReader, BufWriter};
use std::os::fd::FromRawFd;
use std::path::PathBuf;

use sync_ls::{
    transport::io_transport, Connection, LspBuilder, LspClientRoot, LspMessage, MessageKind,
};
use tinymist::{world::CompileFontArgs, RegularInit, ServerState};

/// Runs until LSP exit or input EOF. The descriptors must be owned, distinct,
/// and valid; a non-null font_directory must point to a valid UTF-8 C string.
///
/// # Safety
/// The caller transfers both descriptors and keeps font_directory readable
/// for the duration of this call. Neither descriptor may be used after calling.
#[no_mangle]
pub unsafe extern "C" fn leftblank_tinymist_run(
    input_fd: i32,
    output_fd: i32,
    font_directory: *const c_char,
) -> i32 {
    // Take ownership before any fallible work, including runtime creation.
    // SAFETY: the C API contract transfers two distinct, valid descriptors.
    let input = unsafe { File::from_raw_fd(input_fd) };
    let output = unsafe { File::from_raw_fd(output_fd) };
    let fonts = if font_directory.is_null() {
        None
    } else {
        // SAFETY: the caller keeps this NUL-terminated string readable.
        match unsafe { CStr::from_ptr(font_directory) }.to_str() {
            Ok(path) => Some(PathBuf::from(path)),
            Err(_) => return 1,
        }
    };
    match std::panic::catch_unwind(|| run(input, output, fonts)) {
        Ok(Ok(())) => 0,
        Ok(Err(())) => 1,
        Err(_) => 2,
    }
}

fn run(input: File, output: File, fonts: Option<PathBuf>) -> Result<(), ()> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .map_err(|_| ())?;
    let _entered = runtime.enter();
    let (sender, receiver, io_threads) = io_transport(
        MessageKind::Lsp,
        move || BufReader::new(input),
        move || BufWriter::new(output),
    );
    let mut connection = Connection::<LspMessage>::channel();
    connection.sender.lsp = sender;
    connection.receiver.lsp = receiver;
    let client = LspClientRoot::new(runtime.handle().clone(), connection.sender);
    let font_opts = CompileFontArgs {
        font_paths: fonts.into_iter().collect(),
        // Use explicit CoreText-discovered fonts plus Typst's bundled fonts.
        ignore_system_fonts: true,
    };
    let result = ServerState::install_lsp(LspBuilder::new(
        RegularInit {
            client: client.weak().to_typed(),
            font_opts,
            exec_cmds: Vec::new(),
        },
        client.weak(),
    ))
    .build()
    .start(connection.receiver, false);
    drop(client);
    // Server tasks must stop before the writer can finish; shutdown avoids
    // retaining the runtime while its background tasks hold channel senders.
    drop(_entered);
    runtime.shutdown_timeout(std::time::Duration::from_secs(2));
    let writes = io_threads.join_write();
    result.map_err(|_| ())?;
    writes.map_err(|_| ())
}

/// LeftBlank's typst-syntax bridge (`Engine/SyntaxBridge`), linked into this
/// library so the iPad app carries one Rust runtime: two Rust static libraries
/// in one binary duplicate the standard library's symbols. LeftBlankCore
/// declares the table (`LeftBlankSyntax.h`); the app passes it to
/// `SyntaxTree.install`.
#[no_mangle]
pub extern "C" fn leftblank_tinymist_syntax_api() -> *const std::ffi::c_void {
    leftblank_syntax::lb_syntax_api().cast()
}
