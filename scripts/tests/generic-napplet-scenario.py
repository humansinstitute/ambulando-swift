#!/usr/bin/env python3
"""Generate two unknown synthetic File bundles after building a native test runtime.

Usage: generic-napplet-scenario.py <ignored-output.json> <built-app-executable>
No production account, keys, network or app catalogue is involved.
"""
import hashlib
import json
import pathlib
import sys
import uuid

output, executable = map(pathlib.Path, sys.argv[1:])
app_root = executable.resolve().parents[2]
bundle_hashes = {str(path.relative_to(app_root)): hashlib.sha256(path.read_bytes()).hexdigest()
                 for path in sorted(app_root.rglob('*')) if path.is_file()}
binary = b''.join(path.read_bytes() for path in executable.parent.iterdir() if path.is_file())
bundle_digest = hashlib.sha256(json.dumps(bundle_hashes, sort_keys=True).encode()).hexdigest()
files = []
for index in range(2):
    app_id = 'app-' + uuid.uuid4().hex
    binding = 'b_' + uuid.uuid4().hex[:20]
    assert app_id.encode() not in binary and binding.encode() not in binary
    repo = pathlib.Path(__file__).resolve().parents[2]
    for folder in ['Ambulando', 'AmbulandoMac', 'AmbulandoCore/Sources']:
        for source in (repo / folder).rglob('*.swift'):
            body = source.read_bytes()
            assert app_id.encode() not in body and binding.encode() not in body
    code_id, data_id = str(uuid.uuid4()), str(uuid.uuid4())
    manifest = {'version': 2, 'app_id': app_id, 'title': f'Synthetic app {index + 1}', 'icon': '🌱',
                'bindings': {binding: {'capability': 'private-json-file', 'version': 1, 'operations': ['read', 'save']}}}
    html = '''<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{font:16px system-ui;padding:16px;margin:0;overflow-wrap:anywhere;box-sizing:border-box}input,button{font:inherit;padding:12px;max-width:100%;box-sizing:border-box}pre{white-space:pre-wrap}</style>
<script id="wingman-napplet-manifest" type="application/json">MANIFEST</script>
<h1>Initial UI</h1><p id="status">Loading</p><label>Entry <input id="entry" value="synthetic"></label><button id="save">Save</button><pre id="value"></pre>
<script>
const binding=BINDING;let base=null,count=0,loaded=false;
const read={type:'wingman-napplet-data',version:2,session:window.nappletSession,requestId:'initial',operation:'read',binding};
const send=d=>parent.postMessage(d,'*');const request=(operation,extra={})=>send({...read,requestId:'r'+(++count),operation,...extra});
const dirty=()=>send({type:'wingman-napplet-data',version:2,session:window.nappletSession,requestId:'d'+(++count),operation:'dirty',dirty:true});
function save(){request('save',{baseVersionId:base,value:{date:new Date()}});request('save',{baseVersionId:base,value:{map:new Map([['x',1]])}});request('save',{baseVersionId:base,value:{sparse:new Array(2)}});request('save',{baseVersionId:base,value:{hugeSparse:new Array(50001)}});request('save',{baseVersionId:base,value:{negativeZero:-0}});request('save',{baseVersionId:base,value:{answered:false,zero:0,unanswered:null,entry:document.getElementById('entry').value,marker:MARKER}})}
document.getElementById('entry').oninput=dirty;document.getElementById('save').onclick=save;
addEventListener('message',e=>{if(e.source!==parent)return;const d=e.data;
 if(d?.type==='wingman-napplet-result'&&d.session===window.nappletSession){document.getElementById('status').textContent=d.status;if(d.status==='ready'){base=d.baseVersionId;loaded=true;document.getElementById('value').textContent=JSON.stringify(d.value);}}
 if(d?.command==='save')save();if(d?.command==='dirty')dirty();if(d?.command==='replay')send(read);
 if(d?.command==='probe')parent.postMessage({probe:{loaded,overflow:document.documentElement.scrollWidth>innerWidth,ui:document.querySelector('h1').textContent}},'*');
});send(read);
</script>'''.replace('MANIFEST', json.dumps(manifest, ensure_ascii=False)).replace('BINDING', json.dumps(binding)).replace('MARKER', json.dumps(app_id))
    for file_id, mime, text, metadata in [
        (code_id, 'text/html', html, {'html_artifact': True, 'artefact': {'schema_version': 1, 'type': 'html', 'format_version': 1, 'editor_id': 'builtin.html'},
         'napplet': {'version': 2, 'app_id': app_id, 'bindings': {binding: {'file_id': data_id}}}}),
        (data_id, 'application/json', '{}', {})
    ]:
        head = str(uuid.uuid4())
        files.append({'id': file_id, 'content_type': mime, 'display_name': manifest['title'] + ('.html' if mime == 'text/html' else '.json'),
                      'metadata': metadata, 'text': text, 'head': head, 'history': {head: text}})
output.write_text(json.dumps({'files': files, 'pins': [], 'binarySHA256': hashlib.sha256(binary).hexdigest(), 'bundleSHA256': bundle_digest, 'bundleFiles': bundle_hashes}, ensure_ascii=False))
print(json.dumps({'scenario': str(output), 'binarySHA256': hashlib.sha256(binary).hexdigest(), 'bundleSHA256': bundle_digest, 'bundleFiles': bundle_hashes, 'apps': [f['metadata']['napplet']['app_id'] for f in files if f['content_type'] == 'text/html']}))
