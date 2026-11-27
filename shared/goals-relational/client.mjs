import {randomUUID} from 'node:crypto';
import {canonical,normalizeContent,denormalize,parseLossless} from './model.mjs';
import {snapshot,currentRows,historyRows,insertOperations,editOperations} from './wire.mjs';
import * as lib from '../../scripts/goals-lib.mjs';
import {verifyLinkTarget} from '../../scripts/goals-ops.mjs';
export const CURRENT_TABLES=['goals_authority','goals','goal_checkpoints','goal_associations'];
export function normalizedAt(tables,id) {
 const parent=tables.goals.find(g=>g.id===id);if(!parent)throw new Error('Goal unavailable');
 return {goal:{...parent,goal_id:parent.id},checkpoints:tables.goal_checkpoints.filter(c=>c.goal_id===id),associations:tables.goal_associations.filter(r=>r.goal_id===id)};
}
export function validateMarker(tables) {
 const marker=tables.goals_authority?.[0];
 if(tables.goals_authority?.length!==1 || marker.contract_version!==1 || marker.schema_version!=='ambulando-goals-relational-1')throw new Error('Unsupported normalized Goals schema; update before editing');
 return marker;
}
export function decode(tables,id) {
 validateMarker(tables);
 const normalized=normalizedAt(tables,id);
 return {...normalized,goal:lib.parse(denormalize(normalized)),id,versionId:`sql:${normalized.goal.revision}`,revision:normalized.goal.revision};
}
/** Inject broker-signed request and a durable binding-scoped outbox; no private identity enters this module. */
export function relationalClient({request,legacyClient,workspace,owner,app,channel,actor,pending}) {
 const base=`/api/v4/workspaces/${owner}/apps/${app}/db/native-v1/${workspace}`;
 for(const value of [owner,app])if(!/^npub1[a-z0-9]+$/.test(value))throw new Error('Invalid namespace identity');
 for(const value of [workspace,channel])if(!/^[a-f0-9-]{36}$/.test(value))throw new Error('Invalid workspace/channel');
 async function call(action,body){return request('POST',`${base}/${action}`,body);}
 async function state() {
  const value=await call('status',{channel_id:channel,content_type:lib.MIME});
  if(value.version!==1)throw new Error('Unsupported authority contract');
  if(value.authority?.mode==='active') {await pending?.observe?.();return 'relational';}
  if(value.authority?.mode==='staging'&&value.fence?.active!==true&&!(await pending?.observed?.()))return 'legacy';
  if(value.authority)throw new Error('Goals are frozen for migration; retained content is read-only');
  if(await pending?.observed?.())throw new Error('Goals authority unavailable; retained content is read-only');
  return 'legacy';
 }
 async function readSnapshot(){if(await state()!=='relational')return null;return snapshot((table,q)=>call('query',{...q,table}),channel,3,CURRENT_TABLES);}
 async function send(operations) {
  if(!pending)throw new Error('Relational writes require a durable scoped pending-request store');
  const previous=await pending.load();
  if(previous){await call('batch',previous);await pending.save(null);throw new Error('Previous save recovered. Reload before another edit.');}
  const body={version:1,operation_id:randomUUID(),channel_id:channel,operations};await pending.save(body);
  try{const result=await call('batch',body);await pending.save(null);return result;}
  catch(e){if(e.code==='row_conflict'||e.status===400||e.status===422)await pending.save(null);throw e;}
 }
 async function verify(before,after){
  const previous=[...(before?.links??[]),...(before?.pinned_refs??[])];
  for(const ref of [...after.links,...(after.pinned_refs??[])].filter(r=>!previous.some(p=>p.type===r.type&&p.record_id===r.record_id)))await verifyLinkTarget(legacyClient,workspace,ref);
  if(after.default_channel_id && after.default_channel_id!==before?.default_channel_id){
   const row=(await legacyClient.request('GET',`${legacyClient.root}/channels/${after.default_channel_id}`)).channel;
   if(row?.id!==after.default_channel_id||row.workspace_id!==workspace||row.deleted_at||row.archived_at)throw new Error('Discussion channel unavailable');
  }
 }
 return {state,readSnapshot,
  async list(){const s=await readSnapshot();return s? s.tables.goals.filter(g=>!g.tombstoned_at).map(g=>decode(s.tables,g.id)):null;},
  async read(id){const s=await readSnapshot();return s?decode(s.tables,id):null;},
  async create(goal){const initial=await readSnapshot();if(!initial)return null;const marker=validateMarker(initial.tables);await verify(null,goal);const id=randomUUID(),timestamp=new Date().toISOString();
   const n=normalizeContent(lib.encode(goal),{workspace_id:workspace,channel_id:channel,owner_npub:marker.owner_npub,goal_id:id});const rows=currentRows(n,{revision:1,timestamp,actor});
   await send(insertOperations({...rows,...historyRows(rows)}));return {id,versionId:'sql:1',goal};},
  async edit(id,edits){
   for(let attempt=0;attempt<4;attempt++) {
    const s=await readSnapshot();if(!s)return null;const current=decode(s.tables,id);
    const next=edits.reduce(lib.applyEdit,current.goal);if(canonical(next)===canonical(current.goal))return {...current,changed:false};await verify(current.goal,next);
    const revision=Number(current.revision);if(!Number.isSafeInteger(revision))throw new Error('Revision exceeds client safe range');
    const n=normalizeContent(lib.encode(next),{workspace_id:workspace,channel_id:channel,owner_npub:s.tables.goals.find(g=>g.id===id).owner_npub,goal_id:id});
    const after=currentRows(n,{revision:revision+1,timestamp:new Date().toISOString(),actor});after.goals[0].created_at=s.tables.goals.find(g=>g.id===id).created_at;
    const before=Object.fromEntries(['goals','goal_checkpoints','goal_associations'].map(t=>[t,s.tables[t].filter(r=>t==='goals'?r.id===id:r.goal_id===id)]));
    try{await send(editOperations(before,after));return {id,versionId:`sql:${revision+1}`,goal:next,changed:true};}
    catch(e){if(e.code!=='row_conflict'||attempt===3)throw e;}
   }
  }
 };
}
