import json
from pathlib import Path
import shutil
import subprocess
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]


def harvest_script() -> str:
    source = (ROOT / 'App/YouTubeBrowser.swift').read_text()
    assert 'private var harvestScript: String {' in source
    body = source.split('private var harvestScript: String {', 1)[1]
    return textwrap.dedent(body.split('#"""', 1)[1].split('"""#', 1)[0])


def run_node(harness: str, timeout: int = 30) -> subprocess.CompletedProcess:
    node = shutil.which('node')
    assert node, 'Node is needed for the browser harvester regression'
    return subprocess.run([node, '-e', harness.replace('SCRIPT', json.dumps(harvest_script()))],
                          capture_output=True, text=True, timeout=timeout)


PRELUDE = r'''
const vm = require('node:vm'); const assert = require('node:assert/strict');
const script = SCRIPT;
const wrapper = '(async () => {\n' + script + '\n})()';
function row(href, title) {
  return {querySelector(selector) {
    if (selector.indexOf('video-title') >= 0) return {getAttribute(){ return null; }, textContent: title};
    return {getAttribute(name){ return name === 'href' ? href : null; }, textContent: title};
  }, querySelectorAll() {
    return [{getAttribute(){ return null; }, textContent: title}];
  }};
}
function pageHtml(data) { return '<html><script>var ytInitialData = ' + JSON.stringify(data) + ';</script></html>'; }
function mobilePageHtml(data) { const quoted = JSON.stringify(data).replace(/"/g, '\\x22').replace(/:/g, '\\x3a'); return '<html><script>var ytInitialData = \'' + quoted + '\';</script></html>'; }
function envWith(href, rows, data, html) {
  return {window: {ytInitialData: data}, ytInitialData: data, URL, JSON, Map, console,
    location: new URL(href),
    encodeURIComponent,
    fetch: async (url, options) => { assert.ok(String(url).indexOf('/playlist?list=') >= 0, 'fetch targets the playlist page'); return {status: 200, text: async () => html || ''}; },
    document: {title: 'Sayfa', documentElement: {innerHTML: ''}, querySelectorAll(){ return rows || []; },
               querySelectorAllUnused(){ return []; }},
    querySelectorAll(){ return rows || []; }};
}
'''


class BrowserHarvest(unittest.TestCase):
    """The in-app browser must read the playlist that is open, whatever page it lands on."""

    def test_playlist_page_reads_rows_data_and_the_playlist_request(self):
        prelude = PRELUDE
        harness = prelude + r'''
const rows = [row('/watch?v=abcdefghijk', 'Row one'), {querySelector(){ return null; }}];
const data = {contents: {items: [
  {playlistVideoRenderer: {videoId: 'dQw4w9WgXcQ', title: {runs: [{text: 'Data '}, {text: 'row'}]}}},
  {videoRenderer: {videoId: 'recommend01', title: {simpleText: 'Recommendation'}}}
]}};
const fetched = {contents: {items: [
  {lockupViewModel: {contentId: 'M7lc1UVf-VE', metadata: {lockupMetadataViewModel: {title: {content: 'Fetched row'}}}}},
  {playlistVideoRenderer: {videoId: 'abcdefghijk', title: {simpleText: 'Row one'}}}
]}};
(async () => {
  const env = envWith('https://m.youtube.com/playlist?list=PLtest', rows, data, pageHtml(fetched));
  const parsed = JSON.parse(await vm.runInNewContext(wrapper, env));
  const ids = parsed.items.map((i) => i.id).sort();
  assert.deepEqual(ids, ['M7lc1UVf-VE', 'abcdefghijk', 'dQw4w9WgXcQ'].sort());
  assert.ok(!ids.includes('recommend01'), 'recommendations stay out');
  assert.equal(parsed.meta.rows, 1);
  assert.equal(parsed.meta.fromData, 1);
  assert.equal(parsed.meta.fromFetch, 1);
  assert.equal(parsed.meta.status, 200);
  assert.ok(parsed.meta.html > 0);
  assert.equal(parsed.meta.list, 'PLtest');
  assert.equal(parsed.meta.playlist, true);
  console.log('playlist page passed');
})();
'''
        result = run_node(harness)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_watch_page_inside_a_list_is_read_from_the_panel(self):
        harness = PRELUDE + r'''
const data = {contents: {singleColumnWatchNextResults: {playlist: {playlistPanelRenderer: {contents: [
  {playlistPanelVideoRenderer: {videoId: 'Qwfl2M67xCI', title: {simpleText: 'Panel row'}}}
]}}}}};
const fetched = {contents: {items: [{playlistVideoRenderer: {videoId: 'abcdefghijk', title: {simpleText: 'Second'}}}]}};
(async () => {
  const env = envWith('https://m.youtube.com/watch?v=zzzzzzzzzzz&list=PLtest', [], data, pageHtml(fetched));
  const parsed = JSON.parse(await vm.runInNewContext(wrapper, env));
  const ids = parsed.items.map((i) => i.id).sort();
  assert.deepEqual(ids, ['Qwfl2M67xCI', 'abcdefghijk'].sort());
  assert.equal(parsed.meta.playlist, true, 'a video inside a list still counts');
  console.log('watch page panel passed');
})();
'''
        result = run_node(harness)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_page_without_a_list_is_ignored(self):
        harness = PRELUDE + r'''
const data = {contents: {items: [{videoRenderer: {videoId: 'dQw4w9WgXcQ', title: {simpleText: 'Feed'}}}]}};
(async () => {
  for (const href of ['https://m.youtube.com/', 'https://m.youtube.com/results?search_query=x']) {
    const env = envWith(href, [row('/watch?v=abcdefghijk', 'Feed row')], data, '');
    const parsed = JSON.parse(await vm.runInNewContext(wrapper, env));
    assert.equal(parsed.items.length, 0, 'nothing outside a list: ' + href);
    assert.equal(parsed.meta.playlist, false);
  }
  console.log('scope gate passed');
})();
'''
        result = run_node(harness)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rows_are_capped_at_500(self):
        harness = PRELUDE + r'''
const rows = Array.from({length: 900}, (_, i) => row('/watch?v=a' + String(i).padStart(10, '0'), 'Row ' + i));
(async () => {
  const env = envWith('https://m.youtube.com/playlist?list=', rows, null, '');
  const parsed = JSON.parse(await vm.runInNewContext(wrapper, env));
  assert.equal(parsed.items.length, 500);
  assert.equal(new Set(parsed.items.map((i) => i.id)).size, 500);
  console.log('cap passed');
})();
'''
        result = run_node(harness)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_harvester_touches_nothing_private(self):
        script = harvest_script()
        for forbidden in ['document.cookie', 'localStorage', 'sessionStorage', 'XMLHttpRequest',
                          'indexedDB', '.click(', 'webkit.messageHandlers']:
            self.assertNotIn(forbidden, script)
        # Only the same-origin playlist request is allowed, from inside the logged-in web view.
        self.assertIn("fetch(location.origin + '/playlist?list='", script)
        self.assertIn('callAsyncJavaScript', (ROOT / 'App/YouTubeBrowser.swift').read_text())

class MobilePayloadAndTitles(unittest.TestCase):
    """Mobile YouTube ships ytInitialData as a quoted string full of \\x22 escapes and keeps the song
    name under lockupMetadataViewModel. Both were missed, so rows imported as bare watch ids."""

    def test_mobile_quoted_payload_and_lockup_titles(self):
        harness = PRELUDE + r'''
const fetched = {contents: {items: [
  {lockupViewModel: {contentId: 'Qwfl2M67xCI', metadata: {lockupMetadataViewModel: {title: {content: 'Mabel Matiz - Umrumdisi'}}}}},
  {lockupViewModel: {contentId: 'q2IMrkhSjSA', metadata: {metadataRows: []}}}
]}};
(async () => {
  const env = envWith('https://m.youtube.com/playlist?list=PLmobil', [], null, mobilePageHtml(fetched));
  const parsed = JSON.parse(await vm.runInNewContext(wrapper, env));
  assert.equal(parsed.items.length, 2, 'the quoted payload must parse');
  assert.equal(parsed.meta.fromFetch, 2);
  const named = parsed.items.find((i) => i.id === 'Qwfl2M67xCI');
  assert.equal(named.title, 'Mabel Matiz - Umrumdisi', 'lockup titles must survive');
  console.log('mobile payload passed');
})();
'''
        result = run_node(harness)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_the_browser_is_not_limited_to_youtube(self):
        browser = (ROOT / 'App/YouTubeBrowser.swift').read_text(encoding='utf-8')
        self.assertIn('static func browsable(_ url: URL) -> Bool', browser)
        self.assertIn('static func isYouTube(_ url: URL) -> Bool', browser)
        policy = browser.split('static func browsable', 1)[1].split('static func isYouTube', 1)[0]
        self.assertNotIn('youtube', policy.lower(), 'browsing must not be filtered by host')
        harvest = browser.split('func harvest(offer: Bool)', 1)[1].split('private static let harvestPollRead', 1)[0]
        self.assertIn('YouTubeBrowserPolicy.isYouTube', harvest, 'only the list reader stays YouTube-only')
        self.assertIn('private var addressRow: some View', browser)
        self.assertIn('model.open(address: address)', browser)

    def test_browser_has_back_forward_and_reload(self):
        browser = (ROOT / 'App/YouTubeBrowser.swift').read_text(encoding='utf-8')
        self.assertIn('@Published private(set) var canGoBack = false', browser)
        self.assertIn('@Published private(set) var canGoForward = false', browser)
        self.assertIn('func goBack() { guard webView.canGoBack else { return }; webView.goBack() }', browser)
        self.assertIn('func goForward() { guard webView.canGoForward else { return }; webView.goForward() }', browser)
        self.assertIn('func reloadPage() { webView.reload() }', browser)
        self.assertIn('observe(\\.canGoBack', browser)
        self.assertIn('chevron.backward', browser)
        self.assertIn('chevron.forward', browser)
        self.assertIn('.disabled(!model.canGoBack)', browser)
        self.assertIn('webViewWebContentProcessDidTerminate', browser)
