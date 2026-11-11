"""Ad blocking inside the YouTube tab is a script that runs before the page does. These tests prove the
script is valid JavaScript and - more importantly - that it really strips the ad blocks out of a player
response, leaves other responses alone, and skips a running ad. The harness is a tiny fake DOM in node."""
import json
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'App/SiteAdBlock.swift'

HARNESS = r'''
const fs = require('fs');
const vm = require('vm');
const script = fs.readFileSync(process.argv[2], 'utf8');
const intervals = [];
const styles = [];
class FakeXHR {
  constructor() { this.readyState = 0; this._l = {}; this.responseText = ''; }
  open(method, url) { this.url = url; }
  send() {}
  addEventListener(type, fn) { (this._l[type] = this._l[type] || []).push(fn); }
  fire() { this.readyState = 4; (this._l['readystatechange'] || []).forEach(f => f()); }
}
const video = {
  duration: 42,
  currentTime: 0,
  muted: false,
  classList: { contains: (name) => name === 'ad-showing' }
};
const document = {
  readyState: 'complete',
  getElementById: (id) => styles.find(s => s.id === id) || null,
  createElement: (tag) => ({ tagName: tag, id: '', textContent: '' }),
  querySelector: () => video,
  querySelectorAll: () => [],
  addEventListener: () => {},
  documentElement: { appendChild: (el) => styles.push(el) },
  head: { appendChild: (el) => styles.push(el) }
};
const sandbox = {
  document,
  XMLHttpRequest: FakeXHR,
  Response: class { constructor(body, init) { this.body = body; this.status = init.status; } },
  setInterval: (fn) => { intervals.push(fn); return intervals.length; },
  JSON, Object, String, Number, isFinite, console, Array
};
sandbox.window = sandbox;
sandbox.globalThis = sandbox;
sandbox.fetch = undefined;
vm.createContext(sandbox);
vm.runInContext(script, sandbox);

const result = {};

// 1. a player call loses its ad blocks, keeps everything else
const player = new sandbox.XMLHttpRequest();
player.open('POST', 'https://m.youtube.com/youtubei/v1/player?key=abc');
player.responseText = JSON.stringify({
  adPlacements: [{ ad: 1 }],
  playerAds: [{ ad: 2 }],
  adSlots: [{ ad: 3 }],
  streamingData: { formats: [{ itag: 140 }] },
  videoDetails: { title: 'x' }
});
player.send();
player.fire();
const cleaned = JSON.parse(player.responseText);
result.ad_keys_gone = !('adPlacements' in cleaned) && !('playerAds' in cleaned) && !('adSlots' in cleaned);
result.content_kept = cleaned.streamingData.formats[0].itag === 140 && cleaned.videoDetails.title === 'x';

// 2. an unrelated call is untouched
const other = new sandbox.XMLHttpRequest();
other.open('GET', 'https://m.youtube.com/youtubei/v1/browse?key=abc');
other.responseText = JSON.stringify({ adPlacements: [{ ad: 9 }] });
other.send();
other.fire();
result.other_untouched = 'adPlacements' in JSON.parse(other.responseText);

// 3. the skip pass fast-forwards a running ad
intervals.forEach((fn) => fn());
result.ad_skipped = video.currentTime === video.duration;
result.ad_muted = video.muted === true;

// 4. the ad furniture is hidden with an injected style
result.style_injected = styles.length === 1 && /promoted|ad-slot/.test(styles[0].textContent);
result.flag = sandbox.__kontytAdBlock === true;

process.stdout.write(JSON.stringify(result));
'''



SKIP_HARNESS = r"""
const fs = require('fs');
const vm = require('vm');
const script = fs.readFileSync(process.argv[2], 'utf8');
const intervals = [];
const styles = [];
const player = { classList: { contains: (name) => name === 'ad-showing' }, closest: () => player };
function button(text, extra) {
  const el = Object.assign({
    disabled: false, innerText: text, textContent: text,
    getAttribute: (name) => (name === 'aria-label' ? (extra && extra.label) || '' : ''),
    getBoundingClientRect: () => ({ width: extra && extra.hidden ? 0 : 80, height: extra && extra.hidden ? 0 : 24 }),
    closest: () => (extra && extra.outside ? null : player),
    click: () => { el.clicked = (el.clicked || 0) + 1; }
  }, extra || {});
  return el;
}
const skipButton = button('Reklamı atla');
const skipByLabel = button('', { label: 'Skip ad' });
const hiddenButton = button('Atla', { hidden: true });
const outsideButton = button('Atlayıp geç', { outside: true });
const countdown = button('Değil', {});
const noise = button('Beğen');
const video = { duration: 30, currentTime: 0, muted: false };
const document = {
  readyState: 'complete',
  getElementById: (id) => styles.find((s) => s.id === id) || null,
  createElement: (tag) => ({ tagName: tag, id: '', textContent: '' }),
  querySelector: (sel) => {
    if (sel === 'video') { return video; }
    if (sel.indexOf('movie_player') >= 0) { return player; }
    return null;
  },
  querySelectorAll: () => [skipButton, skipByLabel, hiddenButton, outsideButton, countdown, noise],
  addEventListener: () => {},
  documentElement: { appendChild: (el) => styles.push(el) },
  head: { appendChild: (el) => styles.push(el) }
};
const sandbox = {
  document,
  XMLHttpRequest: function () {},
  setInterval: (fn) => { intervals.push(fn); return intervals.length; },
  getComputedStyle: () => ({ visibility: 'visible', display: 'block', opacity: '1' }),
  JSON, Object, String, Number, isFinite, Date, console, Array
};
sandbox.window = sandbox;
sandbox.globalThis = sandbox;
sandbox.fetch = undefined;
vm.createContext(sandbox);
vm.runInContext(script, sandbox);
intervals.forEach((fn) => fn());
process.stdout.write(JSON.stringify({
  text_button: skipButton.clicked || 0,
  aria_button: skipByLabel.clicked || 0,
  hidden: hiddenButton.clicked || 0,
  outside: outsideButton.clicked || 0,
  noise: noise.clicked || 0,
  muted: video.muted === true,
  exposed: typeof sandbox.__kontytSkip === 'function'
}));
"""


"""Ad blocking inside the YouTube tab is a script that runs before the page does. These tests prove the
script is valid JavaScript and - more importantly - that it really strips the ad blocks out of a player
response, leaves other responses alone, and skips a running ad. The harness is a tiny fake DOM in node."""
import json
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'App/SiteAdBlock.swift'

HARNESS = r'''
const fs = require('fs');
const vm = require('vm');
const script = fs.readFileSync(process.argv[2], 'utf8');
const intervals = [];
const styles = [];
class FakeXHR {
  constructor() { this.readyState = 0; this._l = {}; this.responseText = ''; }
  open(method, url) { this.url = url; }
  send() {}
  addEventListener(type, fn) { (this._l[type] = this._l[type] || []).push(fn); }
  fire() { this.readyState = 4; (this._l['readystatechange'] || []).forEach(f => f()); }
}
const video = {
  duration: 42,
  currentTime: 0,
  muted: false,
  classList: { contains: (name) => name === 'ad-showing' }
};
const document = {
  readyState: 'complete',
  getElementById: (id) => styles.find(s => s.id === id) || null,
  createElement: (tag) => ({ tagName: tag, id: '', textContent: '' }),
  querySelector: () => video,
  querySelectorAll: () => [],
  addEventListener: () => {},
  documentElement: { appendChild: (el) => styles.push(el) },
  head: { appendChild: (el) => styles.push(el) }
};
const sandbox = {
  document,
  XMLHttpRequest: FakeXHR,
  Response: class { constructor(body, init) { this.body = body; this.status = init.status; } },
  setInterval: (fn) => { intervals.push(fn); return intervals.length; },
  JSON, Object, String, Number, isFinite, console, Array
};
sandbox.window = sandbox;
sandbox.globalThis = sandbox;
sandbox.fetch = undefined;
vm.createContext(sandbox);
vm.runInContext(script, sandbox);

const result = {};

// 1. a player call loses its ad blocks, keeps everything else
const player = new sandbox.XMLHttpRequest();
player.open('POST', 'https://m.youtube.com/youtubei/v1/player?key=abc');
player.responseText = JSON.stringify({
  adPlacements: [{ ad: 1 }],
  playerAds: [{ ad: 2 }],
  adSlots: [{ ad: 3 }],
  streamingData: { formats: [{ itag: 140 }] },
  videoDetails: { title: 'x' }
});
player.send();
player.fire();
const cleaned = JSON.parse(player.responseText);
result.ad_keys_gone = !('adPlacements' in cleaned) && !('playerAds' in cleaned) && !('adSlots' in cleaned);
result.content_kept = cleaned.streamingData.formats[0].itag === 140 && cleaned.videoDetails.title === 'x';

// 2. an unrelated call is untouched
const other = new sandbox.XMLHttpRequest();
other.open('GET', 'https://m.youtube.com/youtubei/v1/browse?key=abc');
other.responseText = JSON.stringify({ adPlacements: [{ ad: 9 }] });
other.send();
other.fire();
result.other_untouched = 'adPlacements' in JSON.parse(other.responseText);

// 3. the skip pass fast-forwards a running ad
intervals.forEach((fn) => fn());
result.ad_skipped = video.currentTime === video.duration;
result.ad_muted = video.muted === true;

// 4. the ad furniture is hidden with an injected style
result.style_injected = styles.length === 1 && /promoted|ad-slot/.test(styles[0].textContent);
result.flag = sandbox.__kontytAdBlock === true;

process.stdout.write(JSON.stringify(result));
'''



def script_text():
    """The first raw string in the file is the ad filter; the second one is the playback announcement."""
    text = SOURCE.read_text(encoding='utf-8')
    return text.split('#"""', 1)[1].split('"""#', 1)[0]

def script_text_playback():
    """The second raw string in the file is the playback/media-session announcement."""
    text = SOURCE.read_text(encoding='utf-8')
    parts = text.split('#"""')
    return parts[2].split('"""#', 1)[0]


class AdBlockScript(unittest.TestCase):
    def test_the_script_is_valid_javascript(self):
        node = shutil.which('node')
        if node is None:
            self.skipTest('node is not installed')
        with tempfile.NamedTemporaryFile('w', suffix='.js', delete=False) as handle:
            handle.write(script_text())
            path = handle.name
        check = subprocess.run([node, '--check', path], capture_output=True, text=True)
        self.assertEqual(0, check.returncode, check.stderr[:400])

    def test_it_strips_ads_and_skips_them(self):
        node = shutil.which('node')
        if node is None:
            self.skipTest('node is not installed')
        with tempfile.TemporaryDirectory() as folder:
            js = pathlib.Path(folder) / 'adblock.js'
            js.write_text(script_text(), encoding='utf-8')
            harness = pathlib.Path(folder) / 'harness.js'
            harness.write_text(HARNESS, encoding='utf-8')
            run = subprocess.run([node, str(harness), str(js)], capture_output=True, text=True, timeout=60)
        self.assertEqual(0, run.returncode, run.stderr[:600])
        result = json.loads(run.stdout)
        self.assertTrue(result['ad_keys_gone'], 'the player must never receive adPlacements/playerAds/adSlots')
        self.assertTrue(result['content_kept'], 'stripping ads must not damage the real streams')
        self.assertTrue(result['other_untouched'], 'only player calls are rewritten')
        self.assertTrue(result['ad_skipped'], 'a leftover ad is fast-forwarded')
        self.assertTrue(result['ad_muted'], 'the ad audio is muted while it is skipped')
        self.assertTrue(result['style_injected'], 'ad slots are hidden with CSS')
        self.assertTrue(result['flag'], 'the page can see that the script ran')

    def test_the_script_is_wrapped_so_a_change_cannot_break_playback(self):
        source = SOURCE.read_text(encoding='utf-8')
        self.assertIn('try {\n          if (xhr.__kontytAd)', source.replace('            ', '          '))
        self.assertIn('} catch (e) {}', source)
        self.assertIn('/youtubei/v1/player', source)
        for key in ['adPlacements', 'playerAds', 'adSlots', 'adBreakHeartbeatParams']:
            self.assertIn(key, source)
        # local only: no network, no cookies, no redirects
        for forbidden in ['XMLHttpRequest().open', 'navigator.sendBeacon', 'document.cookie', 'localStorage']:
            self.assertNotIn(forbidden, source)

    def test_now_playing_info_is_published_for_the_lock_screen(self):
        playback = script_text_playback()
        self.assertIn('navigator.mediaSession', playback)
        self.assertIn('session.metadata', playback)
        self.assertIn('i.ytimg.com/vi/', playback)
        self.assertNotIn('setPositionState', playback)
        self.assertNotIn('seekto', playback)
        self.assertIn('"nexttrack"', playback)
        self.assertIn('"previoustrack"', playback)


class AutoSkip(unittest.TestCase):
    """When YouTube hands out an ad with a Skip button, the app presses it - by what the button says, not by
    a class name that changes with every redesign."""

    def test_a_visible_skip_button_is_pressed(self):
        node = shutil.which('node')
        if node is None:
            self.skipTest('node is not installed')
        with tempfile.TemporaryDirectory() as folder:
            js = pathlib.Path(folder) / 'adblock.js'
            js.write_text(script_text(), encoding='utf-8')
            harness = pathlib.Path(folder) / 'skip.js'
            harness.write_text(SKIP_HARNESS, encoding='utf-8')
            run = subprocess.run([node, str(harness), str(js)], capture_output=True, text=True, timeout=60)
        self.assertEqual(0, run.returncode, run.stderr[:600])
        result = json.loads(run.stdout)
        self.assertEqual(1, result['text_button'], 'a button reading "Reklamı atla" must be pressed')
        self.assertEqual(1, result['aria_button'], 'aria-label="Skip ad" inside player counts too')
        self.assertEqual(0, result['hidden'], 'an invisible button is not a skip button')
        self.assertEqual(0, result['outside'], 'buttons outside the player are never pressed')
        self.assertEqual(0, result['noise'], 'unrelated buttons are left alone')
        self.assertTrue(result['muted'], 'the leftover ad is muted while it is skipped')
        self.assertTrue(result['exposed'], 'the page can call the skip pass itself')

    def test_the_watcher_reacts_the_moment_the_button_appears(self):
        source = SOURCE.read_text(encoding='utf-8')
        self.assertIn('new MutationObserver(pressSoon)', source)
        self.assertIn('if (now - lastPress < 100) { return; }', source, 'the watcher is throttled')
        self.assertIn('setInterval(skip, 150)', source)
        self.assertIn('setInterval(hideSlots, 800)', source)
        self.assertIn('adCues', source)
        self.assertIn('adPodIds', source)
        for word in ['skip', 'atla', 'ge[cç]']:
            self.assertIn(word, source)


class AdBlockWiring(unittest.TestCase):
    def test_off_by_default_is_not_the_case_but_the_switch_exists(self):
        site = (ROOT / 'App/YouTubeSite.swift').read_text(encoding='utf-8')
        studio = (ROOT / 'App/StudioViews.swift').read_text(encoding='utf-8')
        self.assertIn('@AppStorage("blockYouTubeAds") private var blockAds = true', site)
        self.assertIn('@AppStorage("blockYouTubeAds") private var blockYouTubeAds = true', studio)
        self.assertIn('Toggle("YouTube reklamlarını engelle", isOn: $blockYouTubeAds)', studio)
        self.assertIn('WKUserScript(source: SiteAdBlock.script,', site)
        self.assertIn('injectionTime: .atDocumentStart', site)
        self.assertIn('forMainFrameOnly: false', site)

    def test_switching_the_setting_reloads_the_page(self):
        site = (ROOT / 'App/YouTubeSite.swift').read_text(encoding='utf-8')
        self.assertIn('adBlock: blockAds', site)
        update = site.split('func updateUIView', 1)[1].split('static func dismantleUIView', 1)[0]
        self.assertIn('if context.coordinator.adBlock != adBlock', update)
        self.assertIn('webView.reload()', update)


if __name__ == '__main__':
    unittest.main()
