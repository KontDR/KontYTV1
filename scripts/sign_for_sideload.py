#!/usr/bin/env python3
"""Ad-hoc seal with App Group entitlements so re-signers can discover them.
This is NOT an installable Apple development signature. AltStore must re-sign.
"""
from pathlib import Path
import plistlib, subprocess, sys, tempfile
app=Path(sys.argv[1]).resolve()
assert app.is_dir() and app.suffix == '.app'
def sign(path, entitlements=None):
    command=['codesign','--force','--sign','-','--timestamp=none','--generate-entitlement-der']
    if entitlements is not None:
        with tempfile.NamedTemporaryFile(suffix='.plist') as f:
            f.write(plistlib.dumps(entitlements)); f.flush()
            subprocess.run(command+['--entitlements',f.name,str(path)],check=True)
    else: subprocess.run(command+[str(path)],check=True)
for framework in sorted(app.rglob('*.framework'),key=lambda p:len(p.parts),reverse=True): sign(framework)
for dylib in app.rglob('*.dylib'): sign(dylib)
for bundle in list(app.glob('PlugIns/*.appex'))+[app]:
    info=plistlib.loads((bundle/'Info.plist').read_bytes())
    group=info.get('KontYTAppGroup')
    mode=info.get('KontYTShareMode', 'enabled')
    assert mode in ['enabled','standalone'], f'Unexpanded signing mode in {bundle}'
    needs_group=mode == 'enabled'
    if needs_group: assert isinstance(group,str) and group.startswith('group.') and '$(' not in group, f'Missing/invalid group in {bundle}' 
    sign(bundle, {'com.apple.security.application-groups':[group]} if needs_group else {})
    subprocess.run(['codesign','--display','--entitlements',':-',str(bundle)],check=True)
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
print('Ad-hoc signatures sealed; install through AltStore re-signing, not directly.')
