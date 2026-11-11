#!/usr/bin/env python3
"""Optional network probe of public metadata, no media payload downloads."""
import json, re, urllib.request
from pathlib import Path
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
report = ['# Public metadata probe (Python, not Swift/iOS)', 'No media files downloaded. No authentication or challenge bypass.']
def object_after(html, marker, required_key=None):
    for match in re.finditer(marker, html):
        tail=html[match.end():].lstrip()
        if not tail.startswith('{'): continue
        try: value=json.JSONDecoder().raw_decode(tail)[0]
        except json.JSONDecodeError: continue
        if required_key is None or required_key in value: return value
    return None
def find_token(value):
    if isinstance(value, list):
        for child in value:
            token=find_token(child)
            if token: return token
    elif isinstance(value, dict):
        renderer=value.get('continuationItemRenderer', {})
        token=renderer.get('continuationEndpoint',{}).get('continuationCommand',{}).get('token')
        if token: return token
        for child in value.values():
            token=find_token(child)
            if token: return token
    return None
def count_video(value):
    if isinstance(value,list): return sum(map(count_video,value))
    if isinstance(value,dict): return int('videoRenderer' in value)+sum(map(count_video,value.values()))
    return 0
try:
    request=urllib.request.Request('https://www.youtube.com/results?search_query=creative+commons+music&hl=tr',headers={'User-Agent':UA})
    with urllib.request.urlopen(request,timeout=20) as response:
        html=response.read(12*1024*1024).decode(); report.append(f'Initial HTML HTTP: {response.status}')
    data=object_after(html,r'(?:var\s+)?ytInitialData\s*=\s*')
    config=object_after(html,r'ytcfg\.set\(', 'INNERTUBE_CONTEXT')
    token=find_token(data)
    report.append(f'Initial videoRenderer records: {count_video(data)}')
    report.append(f'Continuation and client context present: {bool(token and config and config.get("INNERTUBE_CONTEXT"))}')
    if token and config and config.get('INNERTUBE_CONTEXT'):
        body=json.dumps({'context':config['INNERTUBE_CONTEXT'],'continuation':token}).encode()
        request=urllib.request.Request('https://www.youtube.com/youtubei/v1/search',data=body,headers={'Content-Type':'application/json','Origin':'https://www.youtube.com','User-Agent':'Mozilla/5.0'})
        with urllib.request.urlopen(request,timeout=20) as response:
            page=json.load(response); report.append(f'Continuation HTTP: {response.status}; videoRenderer records: {count_video(page)}')
except Exception as error:
    report.append('Probe stopped without bypass/retry: '+type(error).__name__+': '+str(error))
report+=['','This does not validate the Swift local extractor, media transfer, iPhone network, signing, share extension or AVFoundation.']
text='\n'.join(report)+'\n'
Path(__file__).resolve().parents[1].joinpath('METADATA-PROBE-v0.7.md').write_text(text)
print(text)
