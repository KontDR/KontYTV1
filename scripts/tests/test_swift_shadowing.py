"""A bare `catch { }` binds the thrown value to `error`, shadowing a property with the same name.
CI caught `error = error.localizedDescription` in App/IncomingLinks.swift: inside the catch block that
`error` is an immutable `any Error`, so the module failed to compile. This test keeps that class of
mistake out of the tree without needing Xcode."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCES = sorted(ROOT.glob('App/*.swift')) + sorted(ROOT.glob('Shared/*.swift')) + sorted(ROOT.glob('ShareExtension/*.swift'))
BARE_CATCH = re.compile(r'catch\s*\{')
BARE_ASSIGN = re.compile(r'(?<![.\w])error\s*=(?!=)')


class CatchShadowing(unittest.TestCase):
    def test_no_property_assignment_through_a_shadowed_catch_error(self):
        offenders = []
        for path in SOURCES:
            lines = path.read_text(encoding='utf-8').splitlines()
            depth = 0
            block_start = None
            for number, line in enumerate(lines, 1):
                match = BARE_CATCH.search(line) if block_start is None else None
                if match:
                    # only braces after `catch` count: the leading `}` closes the try block
                    block_start, depth = number, line[match.start():].count('{') - line[match.start():].count('}')
                if block_start is not None:
                    if not match:
                        depth += line.count('{') - line.count('}')
                    if BARE_ASSIGN.search(line):
                        offenders.append(f'{path.relative_to(ROOT)}:{number}: {line.strip()}')
                    if depth <= 0:
                        block_start = None
        self.assertEqual([], offenders, 'a bare catch shadows `error`; name it: catch let failure {')
        self.assertGreater(len(SOURCES), 30)


if __name__ == '__main__':
    unittest.main()
