#!/usr/bin/env python3
"""Express pinned Kitten C++17 using SwiftPM's supported manifest setting.
Only derived SPM checkout Package.swift is changed; target sources/pins are untouched.
"""
import argparse
import hashlib
from pathlib import Path
import subprocess


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('derived_data', type=Path)
args = parser.parse_args()
checkout = args.derived_data / 'SourcePackages/checkouts/KittenTTS-swift'
require(subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip() == '4da0abbb92af4e7faf61affabbdb80d334ea768e', "Validation failed: subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip() == '4da0abbb92af4e7faf61affabbdb80d334ea768e'")
changed = subprocess.check_output(['git', '-C', str(checkout), 'diff', '--name-only', 'HEAD'], text=True).splitlines()
require(set(changed) <= {'Package.swift'}, 'Pinned Kitten target sources have unexpected edits')
manifest = checkout / 'Package.swift'
original = subprocess.check_output(['git', '-C', str(checkout), 'show', 'HEAD:Package.swift']).decode()
flag = '                .unsafeFlags(["-std=c++17"]),\n'
require(original.count(flag) == 1 and original.endswith('    ]\n)\n'), "Validation failed: original.count(flag) == 1 and original.endswith('    ]\\n)\\n')")
patched = original.replace(flag, '').replace('    ]\n)\n', '    ],\n    cxxLanguageStandard: .cxx17\n)\n')
require(manifest.read_text() in (original, patched), 'Unexpected existing manifest edits')
manifest.chmod(manifest.stat().st_mode | 0o200)
manifest.write_text(patched)
print('Kitten SDK 0.1.0 / 4da0abbb92af4e7faf61affabbdb80d334ea768e: manifest-only C++17 compatibility patch')
print('Original manifest SHA256:', hashlib.sha256(original.encode()).hexdigest())
print('Patched manifest SHA256:', hashlib.sha256(patched.encode()).hexdigest())
