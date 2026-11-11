"""Swift can only hand a plain C function pointer to C APIs. A closure that touches anything at all
fails the build with "a C function pointer cannot be formed from a closure that captures context" -
which is exactly how one CI run died at CrashLog.swift. These call sites must take a bare function
reference, and the function itself must be a file-level one that captures nothing."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCES = sorted(ROOT.glob('App/*.swift')) + sorted(ROOT.glob('Shared/*.swift')) + sorted(ROOT.glob('ShareExtension/*.swift'))
C_POINTER_SINKS = ['NSSetUncaughtExceptionHandler', 'atexit', 'signal']
CLOSURE_START = re.compile(r'^\s*[{(]\s*$|^\s*[{(]\s*(\[|\()')


def source(name):
    return (ROOT / name).read_text(encoding='utf-8')


class CFunctionPointers(unittest.TestCase):
    def test_sinks_get_a_bare_function_reference(self):
        problems = []
        for path in SOURCES:
            text = path.read_text(encoding='utf-8')
            for line_number, line in enumerate(text.splitlines(), 1):
                stripped = line.strip()
                if stripped.startswith('//') or stripped.startswith('///'):
                    continue
                for sink in C_POINTER_SINKS:
                    if not re.search(r'\b' + sink + r'\b\s*[(,]', stripped):
                        continue
                    if sink == 'signal' and 'SIG_DFL' in stripped:
                        continue  # only the re-raise inside the handler, no Swift closure involved
                    after = stripped.split(sink, 1)[1]
                    if '{' in after:
                        problems.append(f'{path.name}:{line_number} {sink} is given a closure')
        self.assertEqual([], problems, 'pass a file-level function instead: a closure is rejected by the compiler')

    def test_the_handlers_themselves_capture_nothing(self):
        crash_log = source('App/CrashLog.swift')
        for handler in ['kontytCrashHandler', 'kontytRecordException']:
            self.assertIn(f'private func {handler}', crash_log, f'{handler} must be a file-level function')
        # a file-level handler is `private func name(...) {` at column 0
        for line in crash_log.splitlines():
            if line.startswith('private func kontyt'):
                self.assertTrue(line.endswith('{') or line.rstrip().endswith(') {'), 'handler must be a top level function')
        self.assertNotIn('NSSetUncaughtExceptionHandler {', crash_log)
        self.assertIn('NSSetUncaughtExceptionHandler(kontytRecordException)', crash_log)

    def test_signal_handler_avoids_allocation(self):
        body = source('App/CrashLog.swift').split('private func kontytCrashHandler', 1)[1]
        for forbidden in ['String(', 'print(', 'Date(', 'FileHandle']:
            self.assertNotIn(forbidden, body, 'signal handlers must not allocate or lock')
        self.assertIn('write(', body)
        self.assertIn('raise(', body)


if __name__ == '__main__':
    unittest.main()
