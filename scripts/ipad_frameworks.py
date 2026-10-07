#!/usr/bin/env python3
"""Every @rpath library the iPad app links must resolve inside the installed bundle.

The simulator resolves LeftBlankCore through the build products directory, so a
missing runpath only crashes on a device, at launch.
"""
from pathlib import Path
import subprocess
import sys


def load_commands(binary):
    output = subprocess.check_output(['otool', '-l', str(binary)], text=True)
    rpaths, libraries, command = [], [], None
    for line in output.splitlines():
        words = line.split()
        if words[:1] == ['cmd']:
            command = words[1]
        elif words[:1] == ['path'] and command == 'LC_RPATH':
            rpaths.append(words[1])
        elif words[:1] == ['name'] and command in {'LC_LOAD_DYLIB', 'LC_LOAD_WEAK_DYLIB'}:
            libraries.append(words[1])
    return rpaths, libraries


def unresolved(app, binary, rpaths, libraries):
    missing = []
    for library in libraries:
        if not library.startswith('@rpath/'):
            continue
        name = library.removeprefix('@rpath/')
        candidates = [
            Path(rpath.replace('@executable_path', str(app)).replace('@loader_path', str(binary.parent))) / name
            for rpath in rpaths
            if rpath.startswith(('@executable_path', '@loader_path'))
        ]
        if not any(candidate.exists() for candidate in candidates):
            missing.append(library)
    return missing


def check_app(app):
    for binary in [app / 'LeftBlank', *app.glob('*.debug.dylib')]:
        missing = unresolved(app, binary, *load_commands(binary))
        if missing:
            raise ValueError(f'{binary.name} links {", ".join(missing)} without a runpath inside the app bundle')


def main(products):
    apps = list(Path(products).glob('**/LeftBlank.app'))
    if not apps:
        raise SystemExit('No built iPad application found for the framework check')
    for app in apps:
        try:
            check_app(app)
        except ValueError as error:
            raise SystemExit(str(error))
    print('iPad app resolves its embedded frameworks')


if __name__ == '__main__':
    main(sys.argv[1])
