#!/usr/bin/env python3
"""Exercise the iPad in-process bridge on macOS without launching Tinymist."""

import argparse
import json
import os
import re
import zlib
from pathlib import Path
import select
import tempfile
import subprocess
import time
import urllib.request


def assert_pdf_draws_text(data):
    streams = re.findall(rb"stream\r?\n(.*?)\r?\nendstream", data, re.S)
    for stream in streams:
        try:
            commands = zlib.decompress(stream)
        except zlib.error:
            continue
        if b"BT" in commands and (b"TJ" in commands or b"Tj" in commands):
            return
    raise AssertionError("PDF contains no text drawing commands; check engine fonts")


class Engine:
    def __init__(self, library, *, linger=False):
        self.process = subprocess.Popen([str(library), *(['--linger'] if linger else [])],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE if linger else None)
        self.writer = self.process.stdin.fileno()
        self.reader = self.process.stdout.fileno()
        self.buffer = bytearray()
        self.sequence = 0
        self.notifications = []

    def send(self, message):
        body = json.dumps({"jsonrpc": "2.0", **message}, ensure_ascii=False).encode()
        data = f"Content-Length: {len(body)}\r\n\r\n".encode() + body
        while data:
            written = os.write(self.writer, data)
            data = data[written:]

    def read(self, deadline):
        while True:
            header_end = self.buffer.find(b"\r\n\r\n")
            if header_end >= 0:
                headers = self.buffer[:header_end].decode().split("\r\n")
                length = next(int(line.split(":", 1)[1]) for line in headers
                              if line.lower().startswith("content-length:"))
                end = header_end + 4 + length
                if len(self.buffer) >= end:
                    message = json.loads(self.buffer[header_end + 4:end])
                    del self.buffer[:end]
                    return message
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.reader], [], [], remaining)[0]:
                raise TimeoutError("In-process Tinymist did not respond")
            chunk = os.read(self.reader, 65536)
            if not chunk:
                raise RuntimeError(f"Tinymist closed its output (status={self.process.poll()})")
            self.buffer.extend(chunk)

    def request(self, method, params):
        self.sequence += 1
        request_id = self.sequence
        self.send({"id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + 60
        while True:
            message = self.read(deadline)
            if "method" in message:
                if "id" in message:
                    if message["method"] == "workspace/configuration":
                        result = [None] * len(message.get("params", {}).get("items", []))
                    elif message["method"] == "window/showDocument":
                        result = {"success": True}
                    else:
                        result = None
                    self.send({"id": message["id"], "result": result})
                else:
                    self.notifications.append(message)
                continue
            if message.get("id") == request_id:
                if "error" in message:
                    raise RuntimeError(message["error"])
                return message.get("result")

    def notify(self, method, params):
        self.send({"method": method, "params": params})

    def command(self, method, arguments):
        return self.request("workspace/executeCommand", {"command": method, "arguments": arguments})

    def close(self):
        try:
            self.request("shutdown", None)
            self.notify("exit", None)
        finally:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=10)
                raise AssertionError("Tinymist did not shut down its worker")
            finally:
                self.process.stdout.close()
        assert self.process.returncode == 0, f"Tinymist returned {self.process.returncode}"



def verify(library, scratch):
    with tempfile.TemporaryDirectory(prefix="ipad-engine.", dir=scratch) as directory:
        root = Path(directory)
        source = root / "main.typ"
        original = "= Shared engine\n\nHello from iPad. $x^2$\n"
        source.write_text(original)
        engine = Engine(library)
        try:
            result = engine.request("initialize", {
                "processId": None,
                "rootUri": root.as_uri(),
                "capabilities": {"general": {"positionEncodings": ["utf-16"]}},
                "initializationOptions": {
                    "exportPdf": "never",
                    "outputPath": str(root / "$name"),
                    "compileStatus": "enable",
                    "typstExtraArgs": ["--package-cache-path", str(root / "packages")],
                },
            })
            assert result["capabilities"]["positionEncoding"] == "utf-16"
            engine.notify("initialized", {})
            engine.notify("textDocument/didOpen", {"textDocument": {
                "uri": source.as_uri(), "languageId": "typst", "version": 1, "text": original,
            }})
            symbols = engine.request("textDocument/documentSymbol", {
                "textDocument": {"uri": source.as_uri()},
            })
            assert any(item["name"] == "Shared engine" for item in symbols), symbols
            preview = engine.command("tinymist.doStartPreview", [[
                "--task-id=leftblank", "--data-plane-host=127.0.0.1:0",
                "--control-plane-host=127.0.0.1:0", "--no-open",
                "--partial-rendering=true", "--invert-colors=never", str(source),
            ]])
            preview_url = f"http://127.0.0.1:{preview['staticServerPort']}/"
            # HTTP remains on loopback, as in the macOS app; no remote typesetting.
            with urllib.request.urlopen(preview_url, timeout=10) as response:
                assert response.status == 200
                assert b"<html" in response.read().lower()
            first = engine.command("tinymist.exportPdf", [str(source)])
            first_bytes = Path(first["path"]).read_bytes()
            assert first_bytes.startswith(b"%PDF")
            assert_pdf_draws_text(first_bytes)
            changed = "= Edited engine\n\nEmoji 👩🏽‍💻 and $x^3$.\n"
            engine.notify("textDocument/didChange", {
                "textDocument": {"uri": source.as_uri(), "version": 2},
                "contentChanges": [{"text": changed}],
            })
            symbols = engine.request("textDocument/documentSymbol", {
                "textDocument": {"uri": source.as_uri()},
            })
            assert any(item["name"] == "Edited engine" for item in symbols), symbols
            second = engine.command("tinymist.exportPdf", [str(source)])
            second_bytes = Path(second["path"]).read_bytes()
            assert second_bytes.startswith(b"%PDF")
            assert_pdf_draws_text(second_bytes)
            assert second_bytes != first_bytes, "Export ignored the in-memory edit"
            # The engine must compile the open buffer without writing over disk.
            assert source.read_text() == original
            engine.command("tinymist.doKillPreview", ["leftblank"])
        finally:
            engine.close()
    print("PASS: in-process LSP, outline, loopback preview, live edits, PDF export and shutdown")


def verify_immediate_exports(library, scratch):
    with tempfile.TemporaryDirectory(prefix="ipad-export.", dir=scratch) as directory:
        root = Path(directory)
        source, included = root / 'main.typ', root / 'section.typ'
        source.write_text('Saved baseline')
        included.write_text('Saved include')
        engine = Engine(library)
        try:
            engine.request('initialize', {
                'processId': None, 'rootUri': root.as_uri(), 'capabilities': {},
                'initializationOptions': {'exportPdf': 'never', 'outputPath': str(root / '$name')},
            })
            engine.notify('initialized', {})
            for path in (source, included):
                engine.notify('textDocument/didOpen', {'textDocument': {
                    'uri': path.as_uri(), 'languageId': 'typst', 'version': 1, 'text': path.read_text(),
                }})
            engine.command('tinymist.doStartPreview', [[
                '--task-id=leftblank', '--data-plane-host=127.0.0.1:0',
                '--control-plane-host=127.0.0.1:0', '--no-open', str(source),
            ]])
            # The stale-include race needed a concurrent compile and hit about 1% of
            # 20-edit runs on loaded CI runners; more edits widen the regression net.
            for version in range(2, 102):
                # didClose causes an asynchronous filesystem invalidation. Queue a
                # reopen/edit/export immediately; do not wait for preview or retry.
                engine.notify('textDocument/didClose', {'textDocument': {'uri': source.as_uri()}})
                engine.notify('textDocument/didOpen', {'textDocument': {
                    'uri': source.as_uri(), 'languageId': 'typst', 'version': 1, 'text': 'Saved baseline',
                }})
                before, after = f'Before revision {version}', f'After revision {version}'
                current_include = f'Unsaved include {version}'
                for path, text in ((included, current_include),
                                   (source, before + '\n\n#include "section.typ"\n\n' + after)):
                    engine.notify('textDocument/didChange', {
                        'textDocument': {'uri': path.as_uri(), 'version': version},
                        'contentChanges': [{'text': text}],
                    })
                result = engine.command('tinymist.exportText', [str(source)])
                rendered = Path(result['path']).read_text()
                for expected in (before, current_include, after):
                    assert expected in rendered, (version, expected, rendered)
                assert 'Saved baseline' not in rendered and 'Saved include' not in rendered
            engine.notify('textDocument/didClose', {'textDocument': {'uri': included.as_uri()}})
            rendered = Path(engine.command('tinymist.exportText', [str(source)])['path']).read_text()
            assert 'Saved include' in rendered and current_include not in rendered
            assert before in rendered and after in rendered
            assert source.read_text() == 'Saved baseline'
            assert included.read_text() == 'Saved include'
        finally:
            engine.close()
    print('PASS: immediate exports preserve latest unsaved document and include after reopen')


def verify_shutdown_during_compile(library, scratch):
    with tempfile.TemporaryDirectory(prefix="ipad-engine-stop.", dir=scratch) as directory:
        root = Path(directory)
        source = root / "main.typ"
        text = "= Shutdown during compilation\n" + "Paragraph with $x^2$.\n\n" * 1000
        source.write_text(text)
        for delay in (0, 0.01, 0.03, 0.1):
            engine = Engine(library, linger=True)
            try:
                engine.request("initialize", {
                    "processId": None, "rootUri": root.as_uri(), "capabilities": {},
                    "initializationOptions": {"exportPdf": "never", "compileStatus": "enable"},
                })
                engine.notify("initialized", {})
                engine.notify("textDocument/didOpen", {"textDocument": {
                    "uri": source.as_uri(), "languageId": "typst", "version": 1, "text": text,
                }})
                time.sleep(delay)
                # A document switch closes input while background work may still
                # be compiling. The native host deliberately stays alive.
                engine.process.stdin.close()
                engine.process.stdin = None
                _, errors = engine.process.communicate(timeout=15)
                assert engine.process.returncode == 0, (
                    f"Shutdown during compilation returned {engine.process.returncode}: {errors[-1000:]!r}")
            finally:
                if engine.process.poll() is None:
                    engine.process.kill()
                    engine.process.communicate(timeout=10)
    print("PASS: EOF during compilation leaves the embedded host alive")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("library", type=Path)
    parser.add_argument("--scratch", type=Path, required=True)
    arguments = parser.parse_args()
    verify(arguments.library.resolve(), arguments.scratch.resolve())
    verify_immediate_exports(arguments.library.resolve(), arguments.scratch.resolve())
    verify_shutdown_during_compile(arguments.library.resolve(), arguments.scratch.resolve())
