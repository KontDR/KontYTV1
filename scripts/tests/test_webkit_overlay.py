"""WebKit's Swift overlay is `NS_REFINED_FOR_SWIFT`. With an iOS 16 deployment target the linker binds
those symbols to /usr/lib/swift/libswiftWebKit.dylib, which iOS 18.4+ runtimes no longer ship, so dyld
kills the app before launch. The harvest code now uses plain Objective-C calls plus a poll of a page
global; this test keeps the refined APIs out of the tree."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
FORBIDDEN = ('callAsyncJavaScript', 'takeSnapshot', 'createPDF', 'inContentWorld', 'in: .page', 'in: nil, in:')


def without_comments(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return '\n'.join(re.sub(r'//.*$', '', line) for line in text.splitlines())


class WebKitOverlay(unittest.TestCase):
    def test_sources_never_use_the_webkits_swift_overlay(self):
        hits = []
        for path in sorted(ROOT.glob('App/*.swift')) + sorted(ROOT.glob('Shared/*.swift')) + sorted(ROOT.glob('ShareExtension/*.swift')):
            text = without_comments(path.read_text(encoding='utf-8'))
            for token in FORBIDDEN:
                if token in text:
                    hits.append(f'{path.name}: {token}')
        self.assertEqual([], hits, 'these APIs autolink libswiftWebKit and break iOS 18.4+ launches')

    def test_harvest_runs_through_plain_calls(self):
        browser = (ROOT / 'App/YouTubeBrowser.swift').read_text(encoding='utf-8')
        self.assertIn('window.__kontytHarvest', browser)
        self.assertIn('private func pollHarvest(', browser)
        self.assertIn('webView.evaluateJavaScript(kick)', browser)
        self.assertIn('webView.evaluateJavaScript(Self.harvestPollRead)', browser)

    def test_workflow_refuses_a_binary_that_links_the_overlay(self):
        workflow = (ROOT / '.github/workflows/ios.yml').read_text(encoding='utf-8')
        self.assertIn('otool -L', workflow)
        self.assertIn('libswiftWebKit', workflow)


if __name__ == '__main__':
    unittest.main()
