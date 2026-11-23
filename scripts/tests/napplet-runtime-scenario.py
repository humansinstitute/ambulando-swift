#!/usr/bin/env python3
"""Generate unknown v3 cartridges after a frozen host build, for synthetic native WK checks."""
import hashlib
import json
import pathlib
import sys
import uuid

output, executable = map(pathlib.Path, sys.argv[1:])
app_root = executable.resolve().parents[2]
files = {str(p.relative_to(app_root)): hashlib.sha256(p.read_bytes()).hexdigest()
         for p in sorted(app_root.rglob('*')) if p.is_file()}
binary = b''.join(p.read_bytes() for p in executable.parent.iterdir() if p.is_file())
apps = []
for index in range(2):
    name = 'cartridge-' + uuid.uuid4().hex
    collection = 'c_' + uuid.uuid4().hex[:16]
    assert name.encode() not in binary and collection.encode() not in binary
    repo = pathlib.Path(__file__).resolve().parents[2]
    for directory in ['Ambulando', 'AmbulandoMac', 'AmbulandoCore/Sources']:
        assert all(name.encode() not in p.read_bytes() for p in (repo / directory).rglob('*.swift'))
    manifest = {'version': 3, 'napplet_id': name, 'bundle_version': '1', 'title': 'Post-build app ' + str(index + 1),
                'icon': '🌱', 'runtime': {'protocol': 3, 'min_host': 3},
                'collections': {collection: {'scope': 'personal', 'schema_version': 1, 'operations': ['list', 'get', 'create', 'update']}}, 'capabilities': {}}
    def html(m, title):
        return '''<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{font:18px system-ui;padding:18px;overflow-wrap:anywhere}button{font:inherit;padding:12px}pre{white-space:pre-wrap}</style>
<script id="wingman-napplet-manifest" type="application/json">MANIFEST</script>
<h1>TITLE</h1><p id="status">Loading</p><button onclick="save()">Save</button><pre id="value"></pre><script>
const collection=COLLECTION;let n=0,loaded=false;const common={type:'wingman-napplet-data',version:3,session:window.nappletSession};
const send=(operation,extra)=>parent.postMessage({...common,requestId:'r'+(++n),operation,...extra},'*');
const read=()=>send('list',{collection,limit:20,cursor:null});
const save=()=>{if(!loaded){setTimeout(save,25);return;}send('create',{collection,record_id:'entry',base_revision:0,value:{marker:MARKER,answered:false,zero:0,unanswered:null}});};
addEventListener('message',e=>{if(e.source!==parent)return;const d=e.data;if(d?.type==='wingman-napplet-result'&&d.session===window.nappletSession){loaded=d.status==='ready';document.getElementById('status').textContent=d.status;document.getElementById('value').textContent=JSON.stringify(d.result);}
if(d?.command==='probe')parent.postMessage({probe:{loaded,ui:document.querySelector('h1').textContent,rendered:document.getElementById('value').textContent}},'*');if(d?.command==='save')save();if(d?.command==='dirty')send('dirty',{dirty:true});});read();</script>'''.replace('MANIFEST', json.dumps(m, ensure_ascii=False)).replace('TITLE', title).replace('COLLECTION', json.dumps(collection)).replace('MARKER', json.dumps(name))
    updated = dict(manifest, bundle_version='2', title='Updated post-build app ' + str(index + 1))
    apps.append({'id': name, 'collection': collection, 'collectionID': str(uuid.uuid4()), 'file': str(uuid.uuid4()), 'version': str(uuid.uuid4()), 'updateVersion': str(uuid.uuid4()), 'html': html(manifest, manifest['title']), 'updated': html(updated, updated['title']), 'history': []})
output.write_text(json.dumps({'apps': apps, 'bundleFiles': files, 'screenshot': str(output.with_suffix('.png'))}, ensure_ascii=False))
print(json.dumps({'scenario': str(output), 'hostFiles': len(files), 'hostSHA256': hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()}))
