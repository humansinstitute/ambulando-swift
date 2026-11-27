import {test} from 'node:test';import assert from 'node:assert/strict';
import {migration,policies,importBatch} from './deployment.mjs';import {normalize,digest} from './model.mjs';import {readFileSync} from 'node:fs';
test('deployment qualifies exact allocated schema and pins exact checksum',()=>{
 const m=migration('app_fixture');assert.match(m.sql,/REFERENCES "app_fixture"\."goals"/);assert.match(m.sql,/ON "app_fixture"\."goals"/);
 assert.equal(m.checksum,'sha256:'+digest(m.sql));assert.throws(()=>migration('public;DROP SCHEMA public'));
});
test('every import field is registered including sha256 columns and immutable history',()=>{
 const ps=policies();assert.equal(ps.length,8);assert.ok(ps.find(p=>p.table==='goal_imports').policy.columns.includes('source_sha256'));
 assert.ok(ps.find(p=>p.table==='goal_imports').policy.append_only);assert.ok(ps.find(p=>p.table==='goal_history').policy.append_only);
 const b=readFileSync(new URL('../../docs/fixtures/goals/android-written-v1.json',import.meta.url)),id='11111111-1111-4111-8111-111111111111';
 const n=normalize(b,{workspace_id:id,channel_id:id,file_id:id,version_id:id,file_revision:1,owner_npub:'npub1fixture',sha256:digest(b),size_bytes:b.length});
 const batch=importBatch(n,{timestamp:'2026-11-27T00:00:00Z',actor:'npub1fixture'});
 for(const op of batch.operations)for(const k of Object.keys(op.data))assert.ok(ps.find(p=>p.table===op.table).policy.columns.includes(k),`${op.table}.${k}`);
 assert.deepEqual(batch,importBatch(n,{timestamp:'2026-11-27T00:00:00Z',actor:'npub1fixture'}));
});
