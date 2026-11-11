"""CI caught `invalid redeclaration of 'webView(_:didFinish:)'` after an edit landed twice - a plain
Swift compile error only Xcode could see. This walks the sources without Xcode: two functions with the
same name and the same parameter list inside the same type are a compile error, while the same name in
two different types is perfectly legal (that is why the check is scope aware)."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCES = sorted(ROOT.glob('App/*.swift')) + sorted(ROOT.glob('Shared/*.swift')) + sorted(ROOT.glob('ShareExtension/*.swift'))
TYPE_PATTERN = re.compile(r'\b(class|struct|enum|extension|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)')
FUNC_PATTERN = re.compile(r'\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)')


def strip_comments_and_strings(text: str) -> str:
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    text = re.sub(r'"""(?:.|\n)*?"""', '""', text)
    text = re.sub(r'#"(?:.|\n)*?"#', '""', text)
    text = re.sub(r'"(?:\\.|[^"\\])*"', '""', text)
    return '\n'.join(re.sub(r'//.*$', '', line) for line in text.splitlines())


def depths(text: str):
    """Brace depth just before every character index."""
    result, depth = [], 0
    for character in text:
        result.append(depth)
        if character == '{':
            depth += 1
        elif character == '}':
            depth = max(0, depth - 1)
    return result


def parameters_at(text: str, index: int) -> str:
    start = text.find('(', index)
    if start < 0:
        return ''
    depth = 0
    for position in range(start, len(text)):
        if text[position] == '(':
            depth += 1
        elif text[position] == ')':
            depth -= 1
            if depth == 0:
                joined = ' '.join(text[start:position + 1].split())
                return re.sub(r'=\s*[^,)]+', '', joined)  # default values do not affect redeclaration
    return ''


def scoped_declarations(text: str):
    """Yields (owner, name, parameters) for functions declared directly in a type body."""
    depth_map = depths(text)
    types = []
    for match in TYPE_PATTERN.finditer(text):
        brace = text.find('{', match.end())
        if brace < 0:
            continue
        types.append((match.group(2), depth_map[brace] + 1, match.start()))
    types.sort(key=lambda item: item[2])
    for match in FUNC_PATTERN.finditer(text):
        here = depth_map[match.start()]
        owner = None
        for name, body_depth, position in types:
            if position < match.start() and body_depth == here:
                owner = name
        if owner is None:
            continue
        yield owner, match.group(1), parameters_at(text, match.end())


class DuplicateDeclarations(unittest.TestCase):
    def test_no_function_is_declared_twice_in_the_same_type(self):
        problems = []
        for path in SOURCES:
            seen = set()
            text = strip_comments_and_strings(path.read_text(encoding='utf-8'))
            for owner, name, parameters in scoped_declarations(text):
                key = f'{owner}.{name}{parameters}'
                if key in seen:
                    problems.append(f'{path.name}: {key} is declared twice')
                seen.add(key)
        self.assertEqual([], problems, 'Swift refuses to compile a redeclared function; fix the duplicate')

    def test_the_scan_reaches_the_browser_and_the_library(self):
        browser = list(scoped_declarations(strip_comments_and_strings((ROOT / 'App/YouTubeBrowser.swift').read_text(encoding='utf-8'))))
        names = {name for _, name, _ in browser}
        for expected in ['goBack', 'goForward', 'reloadPage', 'harvest']:
            self.assertIn(expected, names)
        library = list(scoped_declarations(strip_comments_and_strings((ROOT / 'App/KontYTApp.swift').read_text(encoding='utf-8'))))
        self.assertIn('updateNowPlaying', {name for _, name, _ in library})
        # the extension methods on one type appear once each
        finishes = [entry for entry in browser if entry[1] == 'webView']
        self.assertTrue(finishes, 'the WKWebView delegate methods must be found')


if __name__ == '__main__':
    unittest.main()
