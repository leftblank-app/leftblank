#!/usr/bin/env python3
"""Evaluate real Swift manifests offline and check the iPad/desktop boundary."""

import json
import os
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'iPad/LeftBlank.xcodeproj/project.pbxproj'
MAC_TARGETS = {
    'LeftBlankCore',
    'LeftBlankApp', 'LeftBlankLauncher', 'LeftBlankTestSupport', 'LeftBlankCoreTests',
    'LeftBlankAppTests',
}
DESKTOP_DEPENDENCIES = {
    'swift-sdk', 'sparkle', 'eventsource', 'swift-atomics', 'swift-collections',
    'swift-log', 'swift-nio', 'swift-system',
}


def manifest(path, distribution):
    env = {**os.environ, 'LEFTBLANK_DISTRIBUTION': distribution}
    # dump-package evaluates the manifest without resolving, fetching or building
    # any dependency. Separate scratch paths avoid a shared manifest cache.
    scratch = ROOT / 'build/package-contracts' / f'{path.name}-{distribution}'
    result = subprocess.run(
        ['swift', 'package', '--package-path', str(path), '--scratch-path', str(scratch),
         '--cache-path', str(ROOT / 'build/package-contracts/cache'), '--manifest-cache', 'local',
         'dump-package'],
        env=env, check=True, capture_output=True, text=True, timeout=60,
    )
    return json.loads(result.stdout)


def dependencies(graph):
    return {row['sourceControl'][0]['identity'] for row in graph['dependencies']}


def targets(graph):
    return {target['name']: target for target in graph['targets']}


class PackageGraphs(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mac = {mode: manifest(ROOT, mode) for mode in ('appstore', 'preview')}
        cls.ipad = {mode: manifest(ROOT / 'Sources', mode) for mode in ('appstore', 'preview')}

    def test_ipad_graph_has_only_core_and_zip(self):
        for mode, graph in self.ipad.items():
            with self.subTest(distribution=mode):
                self.assertEqual(set(targets(graph)), {'LeftBlankCore'})
                self.assertEqual(dependencies(graph), {'zipfoundation'})
                self.assertEqual([(p['name'], p['targets']) for p in graph['products']],
                                 [('LeftBlankCore', ['LeftBlankCore'])])
                self.assertEqual(graph['products'][0]['type'], {'library': ['dynamic']})
                self.assertEqual(targets(graph)['LeftBlankCore']['settings'], [])
                self.assertEqual([(p['platformName'], p['version']) for p in graph['platforms']],
                                 [('ios', '17.0')])

    def test_mcp_stays_outside_shared_core_and_ipad_build(self):
        for source in (ROOT / 'Sources/LeftBlankCore').glob('*.swift'):
            text = source.read_text()
            self.assertNotRegex(text, r'(?m)^import (?:MCP|RMCP|AppKit)$', str(source))
        for name in ('build-ipad.sh', 'prepare-ipad-engine.sh'):
            self.assertNotIn('MCPServer', (ROOT / 'scripts' / name).read_text())
            self.assertNotIn('build-mcp.sh', (ROOT / 'scripts' / name).read_text())
        self.assertNotIn('rmcp', (ROOT / 'Engine/TinymistBridge/Cargo.toml').read_text())
        self.assertNotIn('MCPServer', PROJECT.read_text())
        self.assertNotIn('MCPConnection.swift', PROJECT.read_text())

    def test_ipad_ignores_mac_preview_environment(self):
        self.assertEqual(self.ipad['appstore'], self.ipad['preview'])

    def test_ipad_and_mac_compile_the_same_core_sources_and_resources(self):
        mac, ipad = self.mac['appstore'], self.ipad['appstore']
        mac_core, ipad_core = targets(mac)['LeftBlankCore'], targets(ipad)['LeftBlankCore']
        mac_path = ROOT / mac_core.get('path', 'Sources/LeftBlankCore')
        ipad_path = ROOT / 'Sources' / ipad_core['path']
        self.assertEqual(mac_path.resolve(), ipad_path.resolve())
        self.assertEqual(mac['name'], ipad['name'], 'SwiftPM resource bundle identity must remain stable')
        # Swift 6.2 omits this field from dump-package; newer versions include it.
        self.assertEqual(mac.get('defaultLocalization'), ipad.get('defaultLocalization'))
        for key in ('dependencies', 'resources', 'type'):
            self.assertEqual(mac_core[key], ipad_core[key], key)

    def test_mac_keeps_apps_and_preview_updater(self):
        for mode, graph in self.mac.items():
            with self.subTest(distribution=mode):
                self.assertEqual(set(targets(graph)), MAC_TARGETS)
                self.assertEqual({p['name'] for p in graph['products']},
                                 {'LeftBlankCore', 'LeftBlank'})
                expected = {'zipfoundation'} | ({'sparkle'} if mode == 'preview' else set())
                self.assertEqual(dependencies(graph), expected)
                for name in ('LeftBlankApp', 'LeftBlankAppTests'):
                    has_updater = any(row.get('product', [])[:2] == ['Sparkle', 'Sparkle']
                                      for row in targets(graph)[name]['dependencies'])
                    self.assertEqual(has_updater, mode == 'preview')

    def test_xcode_uses_core_package_and_does_not_pin_desktop_dependencies(self):
        result = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(PROJECT)],
                                check=True, capture_output=True, text=True, timeout=10)
        project = json.loads(result.stdout)
        objects = project['objects']
        references = objects[project['rootObject']]['packageReferences']
        local_packages = [objects[reference] for reference in references
                          if objects[reference]['isa'] == 'XCLocalSwiftPackageReference']
        self.assertEqual(len(local_packages), 1)
        self.assertEqual((PROJECT.parent.parent / local_packages[0]['relativePath']).resolve(),
                         ROOT / 'Sources')
        resolved = PROJECT.parent / 'project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
        pins = {pin['identity'] for pin in json.loads(resolved.read_text())['pins']}
        self.assertIn('zipfoundation', pins)
        self.assertFalse(pins & DESKTOP_DEPENDENCIES, f'Desktop dependencies in iPad lock: {pins}')


if __name__ == '__main__':
    unittest.main()
