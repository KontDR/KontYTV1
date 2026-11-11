#!/usr/bin/env python3
"""Configuration and source checks ONLY; not an iOS compiler or runtime test."""
from pathlib import Path
import json, plistlib, re
import yaml
from PIL import Image
import tree_sitter_swift
from tree_sitter import Language, Parser

root = Path(__file__).resolve().parents[1]
parser = Parser(Language(tree_sitter_swift.language()))
files = [p for directory in ['App', 'Shared', 'ShareExtension', 'Tests'] for p in (root/directory).glob('*.swift')]
for path in files:
    tree = parser.parse(path.read_bytes())
    assert not tree.root_node.has_error, f'Swift grammar parser error: {path}'
config = yaml.safe_load((root/'project.yml').read_text())
fallback = yaml.safe_load((root/'project-standalone.yml').read_text())
assert 'KontYTShare' in config['targets'] and 'KontYTShare' not in fallback['targets']
assert 'CODE_SIGN_ENTITLEMENTS' not in fallback['targets']['KontYT']['settings']['base']
def validate_versions(spec, label, names):
    """Accept any Apple-style numeric version; require embedded targets to match."""
    versions = {}
    for name in names:
        settings = spec.get('targets', {}).get(name, {}).get('settings', {}).get('base', {})
        values = []
        for key in ['MARKETING_VERSION', 'CURRENT_PROJECT_VERSION']:
            value = str(settings.get(key, '')).strip()
            if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', value):
                raise ValueError(f'{label}: {name}.{key}={value!r} invalid; use a numeric version such as 0.8.0 / 10.')
            values.append(value)
        versions[name] = tuple(values)
        print(f'Version: {label} / {name}: marketing={values[0]}, build={values[1]}')
    if len(set(versions.values())) > 1:
        details = '; '.join(f'{name}={marketing} (build {build})' for name, (marketing, build) in versions.items())
        raise ValueError(f'{label}: app and embedded extension versions must match: {details}. Update both target settings in the same YAML file.')
    return versions

try:
    primary_versions = validate_versions(config, 'project.yml', ['KontYT', 'KontYTShare'])
    fallback_versions = validate_versions(fallback, 'project-standalone.yml', ['KontYT'])
except ValueError as error:
    print(f'::error title=Version configuration::{error}')
    raise SystemExit(1)
if primary_versions['KontYT'] != fallback_versions['KontYT']:
    print('::warning::Standalone and with-share release versions differ. Align the YAML files before switching variants.')
assert config['packages']['YouTubeKit']['path'] == 'Vendor/YouTubeKit'
for path in list(root.rglob('*.plist')) + list(root.rglob('*.entitlements')):
    plistlib.loads(path.read_bytes())
app_info = plistlib.loads((root/'App/Info.plist').read_bytes())
assert app_info['CFBundleDisplayName'] == 'KontYT'
assert app_info['UIBackgroundModes'] == ['audio']
assert app_info['CFBundleURLTypes'][0]['CFBundleURLSchemes'] == ['kontyt']
asset = root/'App/Assets.xcassets/AppIcon.appiconset'
entries = json.loads((asset/'Contents.json').read_text())['images']
for entry in entries:
    im = Image.open(asset/entry['filename'])
    size = round(float(entry['size'].split('x')[0]) * float(entry['scale'][:-1]))
    assert im.size == (size,size) and im.mode == 'RGB'
source = (root/'Vendor/YouTubeKit/Sources/YouTubeKit/YouTube.swift').read_text()
# The deployment target is iOS 16: symbols introduced in iOS 17 compile locally on newer
# tooling but fail for the installed app. Keep an explicit deny list.
_IOS17_ONLY = ('.topBarLeading', '.topBarTrailing', 'ContentUnavailableView', '@Observable',
               '.symbolEffect(', '.scrollBounceBehavior(', 'containerRelativeFrame(',
               '.sensoryFeedback(', '.scrollTargetBehavior(', '.onChange(of: initial:')
for _path in sorted((root / 'App').glob('*.swift')):
    _text = _path.read_text()
    for _symbol in _IOS17_ONLY:
        assert _symbol not in _text, f'{_path.name}: {_symbol} needs iOS 17, deployment target is 16.0'
# Collections take UUIDs; passing the whole MediaItem compiles fine in Python-based review but
# fails in Xcode ("cannot convert value of type 'MediaItem' to expected argument type 'UUID'").
_ID_API = ('favorite', 'setFavorite', 'toggleFavorite', 'playlistCount', 'removePlaylist', 'renamePlaylist')
_ID_RE = re.compile(r'\b(' + '|'.join(_ID_API) + r')\(([^()]*)\)')
for _path in sorted((root / 'App').glob('*.swift')):
    for _number, _text in enumerate(_path.read_text().splitlines(), 1):
        if 'func ' in _text or _text.lstrip().startswith('//'):
            continue
        for _match in _ID_RE.finditer(_text):
            _args = _match.group(2)
            if re.search(r'\b(item|video|current|media|playlist)\b(?!\.id)', _args):
                assert '.id' in _args, (
                    f'{_path.name}:{_number}: {_match.group(1)}({_args}) looks like it passes a model '
                    'object where a UUID is expected; use .id')
# SwiftUI type-checking blows up on very large single expressions; the R15 CI run failed with
# "unable to type-check this expression in reasonable time" in a ~160 line body. Keep bodies and
# their modifiers decomposed so the compiler stays fast.
import re as _re
_limit = 60
for _path in sorted((root / 'App').glob('*.swift')):
    _lines = _path.read_text().splitlines()
    for _index, _line in enumerate(_lines):
        if not _re.search(r'var body: some View \{', _line):
            continue
        _depth = 0
        _end = _index
        for _scan in range(_index, len(_lines)):
            _depth += _lines[_scan].count('{') - _lines[_scan].count('}')
            if _depth <= 0 and _scan > _index:
                _end = _scan
                break
        assert _end - _index + 1 <= _limit, (
            f'{_path.name}:{_index + 1}: body is {_end - _index + 1} lines; split it into subviews '
            f'(limit {_limit}) to avoid Swift type-checker timeouts')
assert 'bypassAgeGate' not in source
assert 'case .remote:\n' in source
assert 'async throws' in (root/'App/KontYTApp.swift').read_text()
clipboard = (root/'App/ClipboardMonitor.swift').read_text()
assert 'try await pasteboard.detectPatterns' not in clipboard, 'UIPasteboard.detectPatterns requires its completionHandler callback.'
assert 'continuation.resume(with: result)' in clipboard
assert 'asset.isPlayable' not in (root/'App/KontYTApp.swift').read_text()
assert 'Seal App Group entitlements' in (root/'.github/workflows/ios.yml').read_text()
if 'Bu içeriği indirme hakkım var' in (root/'App/YouTubeMedia.swift').read_text():
    print('::error title=Mixed source versions::App/YouTubeMedia.swift still contains the old rights checkbox. Upload ALL updated App/, Shared/, ShareExtension/, Tests/, scripts/, Vendor/ and .github/ files at repository root, not only the CI patch. Do not remove this check to keep stale UI code.')
    raise SystemExit(1)
assert 'methods: [.local]' in (root/'App/LocalStreamExtractor.swift').read_text()
assert 'Data("</plist>".utf8), in:' in (root/'Shared/AppGroupResolver.swift').read_text(), 'AppGroupResolver: Data.range requires the in: parameter label, not range:'
assert 'https://youtube.com/watch?v=\\(videoID)&bpctr=' not in source
for path in (root/'App').glob('*.swift'):
    assert '.fileSizeKey' not in path.read_text(), f'{path}: use uncached DiskFile.size for live byte counts'
assert '.stopRequestingMediaData(' not in (root/'Tests/VideoFixtureWriter.swift').read_text(), 'AVAssetWriterInput does not implement stopRequestingMediaData; finish the input or cancel the writer.'
count = sum(len(re.findall(r'func test\w+\(', p.read_text())) for p in (root/'Tests').glob('*.swift'))
print(f'PASS: {len(files)} first-party Swift files parsed by grammar; {len(entries)} opaque icons; XML/YAML, dependency, signing variants checked.')
print(f'{count} XCTest methods written, NOT executed. iOS type checking/build, AVFoundation runtime and device validation still required.')
