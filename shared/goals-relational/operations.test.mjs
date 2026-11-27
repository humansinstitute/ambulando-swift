import {test} from 'node:test';import assert from 'node:assert/strict';import {readFileSync} from 'node:fs';
import {TABLES,currentRows,editOperations} from './wire.mjs';import {digest,canonical,normalizeContent} from './model.mjs';import {sealPlan} from './plan.mjs';import {migrationOperations} from './operations.mjs';import {verifyArchive,repairPlan} from './recovery.mjs';
const id='11111111-1111-4111-8111-111111111111';
function fixture(){
 const bytes=readFileSync(new URL('../../docs/fixtures/goals/android-written-v1.json',import.meta.url));const source={workspace_id:id,channel_id:id,owner_npub:'npub1fixture',file_id:id,version_id:id,file_revision:1,sha256:digest(bytes),size_bytes:bytes.length};
 const inventory={complete:true,grants:[],entries:[{source,bytes_base64:bytes.toString('base64'),versions:[{id,sha256_hex:digest(bytes)}]}]};
 const tables=Object.fromEntries(TABLES.map(t=>[t,[]])),authority={mode:'staging',revision:'1'},fence={active:true,revision:'2'},receipts=new Map(),evidence=new Map();let generation=0,drop=true;
 const plan=sealPlan({inventory,staged:{tables},schema:'app_fixture',actor:'npub1fixture',timestamp:'2026-11-27T00:00:00Z',authority:{...authority},fence});
 async function request(method,path,body){const action=path.split('/').at(-1);
  if(action==='status')return {version:1,authority:{...authority},fence};
  if(action==='query'){if(body.generation!==undefined&&body.generation!==String(generation))throw Object.assign(new Error('changed'),{code:'snapshot_changed'});return {version:1,generation:String(generation),rows:structuredClone(tables[body.table]),has_more:false,next_after:null};}
  if(action==='batch'){
   if(receipts.has(body.operation_id)){assert.equal(receipts.get(body.operation_id).digest,digest(canonical(body)));return receipts.get(body.operation_id).result;}
   for(const op of body.operations){const values=tables[op.table],index=values.findIndex(r=>r.id===op.id);if(op.kind==='insert'){assert.equal(index,-1);values.push({...op.data,id:op.id,workspace_id:id,channel_id:id,revision:'1'});}else{assert.equal(Number(values[index].revision),op.expected_revision);if(op.kind==='delete')values.splice(index,1);else values[index]={...values[index],...op.data,revision:String(Number(values[index].revision)+1)};}}
   generation++;const result={version:1,operation_id:body.operation_id,generation:String(generation)};receipts.set(body.operation_id,{digest:digest(canonical(body)),result});if(drop){drop=false;throw new Error('response dropped after commit');}return result;
  }
  if(action==='authority'){assert.equal(body.expected_generation,String(generation));assert.equal(body.expected_fence_revision,2);authority.mode=body.mode;authority.revision=String(Number(authority.revision)+1);return {version:1,authority:{...authority}};}
  throw new Error(action);
 }
 const ops=migrationOperations({request,base:'/native',inventory:async()=>inventory,saveEvidence:async(k,v)=>evidence.set(k,v)});
 return {plan,tables,authority,ops,receipts,evidence,request,inventory};
}
test('actual sealed operations reconcile committed dropped reply and activate only exact staged generation/fence',async()=>{const f=fixture();await assert.rejects(f.ops.stage(f.plan,f.plan.sha256),/dropped/);await f.ops.stage(f.plan,f.plan.sha256);assert.equal(f.tables.goals.length,1);assert.equal(f.tables.goal_history.length,1);await f.ops.activate(f.plan,f.plan.sha256);assert.equal(f.authority.mode,'active');});
test('frozen archive exports every normalized revision, then SQL-native repair appends rather than rewinds',async()=>{const f=fixture();await assert.rejects(f.ops.stage(f.plan,f.plan.sha256));await f.ops.stage(f.plan,f.plan.sha256);
 const g=f.tables.goals[0],before=Object.fromEntries(['goals','goal_checkpoints','goal_associations'].map(t=>[t,structuredClone(f.tables[t])]));
 const n=normalizeContent(Buffer.from(JSON.stringify({schema:'ambulando.goal',schema_version:1,name:'Edited SQL goal',description:'Edited description',status:'active',checkpoints:[],links:[]})),{workspace_id:id,channel_id:id,owner_npub:'npub1fixture',goal_id:id});
 const after=currentRows(n,{revision:2,timestamp:'2026-11-27T01:00:00Z',actor:'npub1fixture'});await f.request('POST','/native/batch',{version:1,staging:true,channel_id:id,operation_id:'edit-fixture',operations:editOperations(before,after)});
 f.authority.mode='frozen';const archive=await f.ops.exportRecovery(f.plan,f.plan.sha256);assert.equal(archive.entries.length,2);verifyArchive(archive);const repair=repairPlan(archive,[{goal_id:id,revision:'1'}],{actor:'npub1fixture',timestamp:'2026-11-27T02:00:00Z'});assert.equal(repair.body.operations[0].expected_revision,2);assert.ok(repair.body.operations.some(o=>o.table==='goal_history'&&o.id===`${id}:v:3`));assert.equal(f.authority.mode,'frozen');
});
