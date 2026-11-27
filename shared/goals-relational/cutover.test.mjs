import {test} from 'node:test';import assert from 'node:assert/strict';import {readFileSync} from 'node:fs';
import {activate,stage,rollback,deterministicOperationId} from './cutover.mjs';import {normalize,digest} from './model.mjs';
const id='11111111-1111-4111-8111-111111111111';
function fixture(){
 const bytes=readFileSync(new URL('../../docs/fixtures/goals/android-written-v1.json',import.meta.url));
 const source={workspace_id:id,channel_id:id,file_id:id,version_id:id,file_revision:1,owner_npub:'npub1fixture',sha256:digest(bytes),size_bytes:bytes.length};
 const n=normalize(bytes,source), staged=new Map();let mode='legacy',targetFrozen=false,sourceFrozen=false;
 return {staged,get mode(){return mode;},get sourceFrozen(){return sourceFrozen;},
  inventory:async()=>({complete:true,entries:[{bytes,source}]}),sourceVersion:async()=>bytes,
  stage:async(row,op)=>{if(staged.has(op))assert.equal(staged.get(op).normalized_sha256,row.normalized_sha256);staged.set(op,row);},
  authority:async()=>({mode,revision:1,epoch:1}),freezeSource:async()=>{sourceFrozen=true;return {active:true,revision:2};},
  activateAtomic:async req=>{assert.ok(sourceFrozen);mode='relational';return req;},
  freezeTarget:async()=>{targetFrozen=true;mode='frozen';return {mode,revision:3};},
  recoveryRevisions:async()=>({complete:true,rows:[{...n,revision:1},{...n,revision:2,goal:{...n.goal,name:'Edited after SQL cutover'}}]}),
  exportRecovery:async r=>{assert.ok(targetFrozen);assert.equal(mode,'frozen');return {sha256:r.sha256,verified:true,operation_id:r.operation_id};},
  restoreLegacyAtomic:async req=>{assert.ok(targetFrozen);assert.equal(req.exports.length,2);mode='legacy';sourceFrozen=false;return req;}
 };
}
test('deterministic stage retries exact version without duplicate imports',async()=>{const a=fixture();assert.deepEqual(await stage(a),await stage(a));assert.equal(a.staged.size,1);});
test('activation rechecks exact manifest after create+mutation fence',async()=>{const a=fixture(),m=await stage(a);const receipt=await activate(a,m);assert.equal(a.mode,'relational');assert.ok(receipt.operation_id);});
test('changed source after fence retains fence and refuses activation',async()=>{const a=fixture();await assert.rejects(activate(a,{sha256:'wrong'}),/manifest changed/);assert.equal(a.mode,'legacy');assert.equal(a.sourceFrozen,true);});
test('rollback after relational edit exports and verifies every revision while SQL frozen',async()=>{const a=fixture();const m=await stage(a);await activate(a,m);const result=await rollback(a);assert.equal(a.mode,'legacy');assert.equal(a.sourceFrozen,false);assert.equal(result.exports.length,2);});
test('failed export never releases either authority',async()=>{const a=fixture();a.exportRecovery=async()=>({verified:false});await assert.rejects(rollback(a),/verification/);assert.equal(a.mode,'frozen');});
test('production activation and rollback require concrete manager review',async()=>{const a=fixture();a.production=true;await assert.rejects(activate(a,{}),/review/);await assert.rejects(rollback(a),/review/);});
