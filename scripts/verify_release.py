#!/usr/bin/env python3
"""Detect incomplete or mixed uploads before invoking Xcode. No network access."""
import hashlib
import json
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / 'RELEASE-MANIFEST.json').read_text())
errors = []
for name, expected in manifest['files'].items():
    path = root / name
    if not path.is_file():
        errors.append(f'MISSING: {name}')
    elif hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        errors.append(f'CHANGED: {name}')
print(f"KontYT source snapshot: {manifest['release']}", flush=True)
if errors:
    for error in errors:
        print(f'::error title=Incomplete or mixed release::{error}')
    print('Upload all extracted release files at repository root. A ZIP uploaded as a single file is not extracted by GitHub.')
    sys.exit(1)
print(f"PASS: {len(manifest['files'])} source/dependency/asset files match the release snapshot.")
