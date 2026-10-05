#!/usr/bin/env python3
"""Check the production SwiftLint icon rule with real Swift source tokens."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SWIFTLINT = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else (
    ROOT / '.tools/swiftlint-0.64.1/swiftlint'
)


class IconPolicyTests(unittest.TestCase):
    def lint(self, source, directory='Sources/LeftBlank'):
        scratch = ROOT / 'build/icon-policy'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as temporary:
            path = Path(temporary) / directory / 'IconPolicyProbe.swift'
            path.parent.mkdir(parents=True)
            path.write_text(source + '\n')
            result = subprocess.run(
                [str(SWIFTLINT), 'lint', str(path), '--config', str(ROOT / '.swiftlint.yml'),
                 '--strict', '--reporter', 'json', '--quiet', '--no-cache'],
                cwd=ROOT, capture_output=True, text=True, timeout=30,
            )
            violations = json.loads(result.stdout)
            return result.returncode, violations

    def test_system_symbol_apis_fail_for_both_apps(self):
        sources = [
            'let image = Image(systemName: "lock")',
            'let image = SwiftUI.Image(\n    systemName:\n        "lock"\n)',
            'let label = Label("Read-only", systemImage: "lock")',
            'let button = Button("Read-only", systemImage: "lock") {}',
            'let image = UIImage(systemName: "lock")',
            'let image = NSImage(systemSymbolName: "lock", accessibilityDescription: nil)',
            'let image: UIImage? = .init(systemName: symbolName)',
        ]
        for directory in ['Sources/LeftBlank', 'iPad/Sources']:
            for source in sources:
                with self.subTest(directory=directory, source=source):
                    status, violations = self.lint(source, directory)
                    self.assertNotEqual(status, 0)
                    matches = [v for v in violations if v['rule_id'] == 'phosphor_icons_only']
                    self.assertEqual(len(matches), 1, violations)
                    self.assertEqual(matches[0]['severity'], 'Error')

    def test_shared_icons_and_documentation_are_allowed(self):
        sources = [
            'let icon = PhosphorIcon(name: "lock-simple", size: 12)',
            'let icon = TabletIcon(name: "check", size: 18)',
            'let image = TabletIcon.menuImage("file", title: "Document")',
            '// Image(systemName: "lock")',
            '/* Label("Read-only", systemImage: "lock") */',
            '/// NSImage(systemSymbolName: "lock", accessibilityDescription: nil)',
            'let message = #"Image(systemName: "lock")"#',
            'let image = Image(nsImage: suppliedImage).accessibilityHidden(true)',
        ]
        for source in sources:
            with self.subTest(source=source):
                status, violations = self.lint(source)
                self.assertEqual(status, 0, violations)
                self.assertEqual(violations, [])


if __name__ == '__main__':
    unittest.main()
