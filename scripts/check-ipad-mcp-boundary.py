#!/usr/bin/env python3
"""The iOS app may embed Tinymist Rust code, but never a desktop MCP helper."""
from pathlib import Path
import subprocess
import sys

products = Path(sys.argv[1])
apps = list(products.glob('*/LeftBlank.app'))
if not apps:
    raise SystemExit('No built iPad application found for the MCP boundary check')
for app in apps:
    for path in app.rglob('*'):
        if path.name.lower() in {'leftblank-mcp', 'connection.json', 'access.json', 'mcp-licenses.txt'}:
            raise SystemExit('Unexpected MCP resource in iOS app: ' + str(path))
    executable = app / 'LeftBlank'
    # -a includes statically linked Rust symbols in debug builds; don't prohibit
    # Rust/Tokio generally, because the embedded typesetting engine needs them.
    symbols = subprocess.check_output(['nm', '-a', str(executable)], text=True)
    if 'MCPConnection' in symbols or 'MCPLinePipe' in symbols or '4rmcp' in symbols:
        raise SystemExit('Unexpected MCP implementation in iOS executable')
print('iPad artifact excludes MCP components')
