"""Executable Python regressions; these do NOT typecheck Swift or execute XCTest."""
import ast
import contextlib
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class VersionChecks(unittest.TestCase):
    def setUp(self):
        path = ROOT / 'scripts/check_source.py'
        node = next(n for n in ast.parse(path.read_text()).body if isinstance(n, ast.FunctionDef) and n.name == 'validate_versions')
        ns = {'re': re}
        exec(compile(ast.Module(body=[node], type_ignores=[]), str(path), 'exec'), ns)
        self.validate = ns['validate_versions']
    def spec(self, version='0.8.1', build='11'):
        return {'targets': {name: {'settings': {'base': {'MARKETING_VERSION': version, 'CURRENT_PROJECT_VERSION': build}}} for name in ['KontYT', 'KontYTShare']}}
    def call(self, config):
        with contextlib.redirect_stdout(io.StringIO()):
            return self.validate(config, 'fixture', ['KontYT', 'KontYTShare'])
    def test_valid_versions_not_pinned(self):
        for version, build in [('0.7.0','9'),('0.8.0','10'),('0.8.1','11'),('1.0',12),('2','1.2.3')]:
            with self.subTest(version=version): self.call(self.spec(version, build))
    def test_invalid_versions(self):
        for key, value in [('MARKETING_VERSION','banana'),('CURRENT_PROJECT_VERSION',''),('MARKETING_VERSION','1.2.3.4')]:
            with self.subTest(key=key, value=value):
                spec=self.spec(); spec['targets']['KontYT']['settings']['base'][key]=value
                with self.assertRaises(ValueError): self.call(spec)
    def test_extension_mismatch(self):
        spec=self.spec(); spec['targets']['KontYTShare']['settings']['base']['MARKETING_VERSION']='0.7.0'
        with self.assertRaisesRegex(ValueError, 'KontYTShare=0.7.0'): self.call(spec)

class ReleaseChecks(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        root=Path(self.temp.name); (root/'scripts').mkdir()
        self.root=root; self.script=root/'scripts/verify_release.py'
        self.script.write_bytes((ROOT/'scripts/verify_release.py').read_bytes())
        (root/'example.swift').write_bytes(b'known content')
        self.write_manifest()
    def write_manifest(self):
        (self.root/'RELEASE-MANIFEST.json').write_text(json.dumps({'release':'fixture','files':{'example.swift':hashlib.sha256(b'known content').hexdigest()}}))
    def run_check(self):
        return subprocess.run([sys.executable,str(self.script)],capture_output=True,text=True)
    def test_complete_release_passes(self):
        self.assertEqual(self.run_check().returncode,0)
    def test_missing_file_fails(self):
        (self.root/'example.swift').unlink()
        result=self.run_check(); self.assertNotEqual(result.returncode,0); self.assertIn('MISSING: example.swift',result.stdout)
    def test_mixed_file_fails(self):
        (self.root/'example.swift').write_text('old release')
        result=self.run_check(); self.assertNotEqual(result.returncode,0); self.assertIn('CHANGED: example.swift',result.stdout)
    def test_restoring_file_recovers(self):
        (self.root/'example.swift').write_text('old release')
        self.assertNotEqual(self.run_check().returncode,0)
        (self.root/'example.swift').write_bytes(b'known content')
        self.assertEqual(self.run_check().returncode,0)

if __name__ == '__main__': unittest.main()
