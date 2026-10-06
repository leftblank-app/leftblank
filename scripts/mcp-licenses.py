#!/usr/bin/env python3
"""Collect the pinned helper's dependency notices into its macOS package resource."""
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
metadata = json.loads(subprocess.check_output([
    'cargo', '+1.92.0', 'metadata', '--locked', '--format-version', '1',
    '--manifest-path', str(root / 'Tools/MCPServer/Cargo.toml'),
    '--filter-platform', 'aarch64-apple-darwin',
], text=True))
sections = ['LeftBlank macOS MCP helper dependency notices.\n']
for package in sorted(metadata['packages'], key=lambda p: (p['name'], p['version'])):
    if package['name'] == 'leftblank-mcp':
        continue
    directory = Path(package['manifest_path']).parent
    licenses = sorted(p for p in directory.iterdir()
                      if p.is_file() and p.name.lower().startswith(('license', 'copying', 'notice')))
    if package['name'] == 'rmcp':
        # rmcp 3.5.0 omits the repository-root license from its crates.io archive.
        licenses = [root / 'Tools/MCPServer/LICENSE-rmcp']
    if not licenses:
        raise SystemExit('Missing license notice for ' + package['name'])
    sections.append(f"\n{'=' * 72}\n{package['name']} {package['version']} ({package['license']})\n"
                    f"{package.get('repository') or ''}\n")
    for license_file in licenses:
        sections.append('\n' + license_file.read_text() + '\n')
(root / '.tools/MCP-LICENSES.txt').write_text(''.join(sections))
