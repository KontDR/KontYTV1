import pathlib
import re
import shutil
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]

class WiFiUploadChecks(unittest.TestCase):
    def test_browser_uploads_sequentially_and_stops_on_error(self):
        if not shutil.which('node'):
            self.skipTest('Node required for browser fixture')
        source = (ROOT / 'App/WiFiUpload.swift').read_text()
        script = re.search(r'<script>(.*?)</script>', source, re.S).group(1)
        fixture = r'''
const vm = require('vm'), assert = require('assert');
(async () => {
const nodes={code:{value:'123456'},files:{files:[{name:'Müzik #1.mp3'},{name:'next.m4a'}]},send:{},progress:{},status:{}};
let sent=[], fail=false;
class XHR { constructor(){this.upload={};this.headers={}} open(method,url){assert.equal(method,'POST');assert.equal(url,'/upload')}
setRequestHeader(k,v){this.headers[k]=v} send(file){sent.push({file,headers:this.headers});this.status=fail?403:200;this.responseText='Kod geçersiz';queueMicrotask(()=>this.onload())}}
const context={document:{getElementById:id=>nodes[id]},XMLHttpRequest:XHR};
vm.runInNewContext(SCRIPT,context);
await nodes.send.onclick();assert.equal(sent.length,2);assert.equal(sent[0].headers['X-KontYT-Code'],'123456');
assert.equal(sent[0].headers['X-File-Name'],encodeURIComponent('Müzik #1.mp3'));
assert.equal(nodes.send.disabled,false);assert.equal(nodes.status.textContent,'Dosyalar arşive eklendi.');
sent=[];fail=true;await nodes.send.onclick();assert.equal(sent.length,1);assert.equal(nodes.status.textContent,'Kod geçersiz');assert.equal(nodes.send.disabled,false);
sent=[];nodes.code.value='';await nodes.send.onclick();assert.equal(sent.length,0);
})().catch(e=>{console.error(e);process.exit(1)});
'''
        import json
        result = subprocess.run(['node', '-e', 'const SCRIPT=' + json.dumps(script) + ';' + fixture], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_receiver_safety_guards_and_privacy_description(self):
        source = (ROOT / 'App/WiFiUpload.swift').read_text()
        for guard in ['parameters.requiredInterfaceType = .wifi', 'fields["x-kontyt-code"] == code', 'fields["transfer-encoding"] == nil', 'length <= 2_147_483_648', 'boundary.lowerBound <= 16384', 'try handle?.write(contentsOf: data)', 'try await onFile(file, name)', 'importTask?.cancel()', 'static let shared', 'func setForeground', 'closeListener(keepEnabled: true)']:
            self.assertIn(guard, source)
        self.assertIn('NSLocalNetworkUsageDescription', (ROOT / 'App/Info.plist').read_text())
