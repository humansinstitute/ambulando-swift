import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {normalize,denormalize,manifest,digest,canonical} from './model.mjs';
const id='11111111-1111-4111-8111-111111111111';
const source=b=>({workspace_id:id,channel_id:id,owner_npub:'npub1fixture',file_id:id,version_id:id,file_revision:'9',sha256:digest(b),size_bytes:b.length});
for(const file of ['android-written-v1.json','agent-written-v1.json']) test(`lossless normalized recovery ${file}`,()=>{
 const b=readFileSync(new URL(`../../docs/fixtures/goals/${file}`,import.meta.url)); const r=normalize(b,source(b));
 assert.deepEqual(JSON.parse(denormalize(r)),JSON.parse(b)); assert.equal(r.goal.goal_id,id);
 assert.equal(r.checkpoints[0].position,0);assert.equal(r.checkpoints[0].checkpoint_id,JSON.parse(b).checkpoints[0].id);
 assert.deepEqual(manifest([r]),manifest([normalize(b,source(b))]));
});
test('pins/default channel/future fields retain independent lanes and ordered string identities',()=>{
 const g={schema:'ambulando.goal',schema_version:1,name:'Goal',description:'Keep facts',status:'active',focus_rank:{future:true},default_channel_id:id,
 checkpoints:[{id:'cp_string',title:'A',reached:true,future:{a:[1,2]}},{id:'cp-2',title:'B',date:'2027-01-01',reached:false}],
 links:[{type:'chat',record_id:id,channel_id:id}],pinned_refs:[{type:'file',record_id:id,future:42}],future:{nested:[true,2.5]}};
 const b=Buffer.from(JSON.stringify(g));const r=normalize(b,source(b));assert.deepEqual(JSON.parse(denormalize(r)),g);
 assert.equal(r.goal.focus_rank,null);assert.equal(r.associations[1].lane,'pin');
});
test('exact immutable version digest and duplicate heads fail closed',()=>{
 const b=readFileSync(new URL('../../docs/fixtures/goals/android-written-v1.json',import.meta.url));
 assert.throws(()=>normalize(b,{...source(b),sha256:'0'.repeat(64)}),/digest/);
 const r=normalize(b,source(b));assert.throws(()=>manifest([r,r]),/Duplicate/);
});
test('unknown numeric literals beyond IEEE754 and optional null presence survive recovery',()=>{
 const b=Buffer.from('{"schema":"ambulando.goal","schema_version":1,"name":"N","description":"D","status":"active","start_date":null,"checkpoints":[{"id":"a","title":"A","reached":null}],"links":[{"type":"file","record_id":"11111111-1111-4111-8111-111111111111","channel_id":null}],"pinned_refs":null,"future":9007199254740993,"decimal":0.123456789012345678901}');
 const r=normalize(b,source(b)),out=denormalize(r).toString();assert.match(out,/9007199254740993/);assert.match(out,/0\.123456789012345678901/);
 assert.equal(JSON.parse(out).checkpoints[0].reached,null);assert.equal(JSON.parse(out).links[0].channel_id,null);assert.equal(JSON.parse(out).pinned_refs,null);
});
