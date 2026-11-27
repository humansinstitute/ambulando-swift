import {canonical,digest} from './model.mjs';
export const TABLES = ['goals_authority','goals','goal_checkpoints','goal_associations','goal_imports','goal_history','goal_checkpoint_history','goal_association_history'];
const omit = (o,keys) => Object.fromEntries(Object.entries(o).filter(([k])=>!keys.includes(k)));
export function currentRows(normalized, {revision, timestamp, actor}) {
 const {goal,checkpoints,associations}=normalized;
 return {
 goals:[{...omit(goal,['goal_id']),extensions:canonical(goal.extensions),id:goal.goal_id,revision,created_at:timestamp,updated_at:timestamp,updated_by_npub:actor,tombstoned_at:null}],
 goal_checkpoints:checkpoints.map(c=>({...c,extensions:canonical(c.extensions),id:`${goal.goal_id}:cp:${c.checkpoint_id}`,revision})),
 goal_associations:associations.map(r=>({...r,extensions:canonical(r.extensions),id:`${goal.goal_id}:${r.lane}:${r.kind}:${r.record_id}`,present_fields:r.present_fields??[],revision}))
 };
}
export function historyRows(rows) {
 const g=rows.goals[0], history_id=`${g.id}:v:${g.revision}`;
 return {
 goal_history:[{...omit(g,['created_at']),id:history_id,goal_id:g.id,content_revision:g.revision,revision:1}],
 goal_checkpoint_history:rows.goal_checkpoints.map(c=>({...c,id:`${history_id}:cp:${c.checkpoint_id}`,history_id,content_revision:g.revision,revision:1})),
 goal_association_history:rows.goal_associations.map(r=>({...r,id:`${history_id}:${r.lane}:${r.kind}:${r.record_id}`,history_id,content_revision:g.revision,revision:1}))
 };
}
export function importRows(n, options) {
 const rows=currentRows(n,options), p=n.provenance;
 rows.goals[0].created_at=p.file_created_at??options.timestamp;rows.goals[0].updated_at=p.file_updated_at??options.timestamp;
 return {...rows,...historyRows(rows),goal_imports:[{
 id:`${p.file_id}:source:${p.version_id}`,workspace_id:p.workspace_id,channel_id:p.channel_id,owner_npub:p.owner_npub,goal_id:p.file_id,
 source_version_id:p.version_id,source_file_revision:p.file_revision,source_sha256:p.sha256,source_size_bytes:p.size_bytes,
 mapper_version:p.mapper_version,mapper_sha256:options.mapper_sha256,normalized_sha256:n.normalized_sha256,
 imported_revision:options.revision,imported_at:options.timestamp,revision:1
 }]};
}
/** Generic batch data never sets server-controlled scope, id or row revision. */
export function insertOperations(rows) {
 return TABLES.flatMap(table=>(rows[table]??[]).map(row=>({kind:'insert',table,id:row.id,data:omit(row,['id','workspace_id','channel_id','revision'])})));
}
/** All current-state changes and immutable revision children share one parent CAS transaction. */
export function editOperations(before, after) {
 const operations=[];
 for(const table of ['goals','goal_checkpoints','goal_associations']) {
  const old=new Map(before[table].map(r=>[r.id,r]));
  for(const row of after[table]) {
   const prior=old.get(row.id);old.delete(row.id);
   const data=omit(row,['id','workspace_id','channel_id','revision','created_at']);
   if(prior) {if(table!=='goals') delete data.goal_id; operations.push({kind:'update',table,id:row.id,expected_revision:Number(prior.revision),data});}
   else operations.push({kind:'insert',table,id:row.id,data:omit(row,['id','workspace_id','channel_id','revision'])});
  }
  for(const row of old.values()) operations.push({kind:'delete',table,id:row.id,expected_revision:Number(row.revision)});
 }
 return [...operations,...insertOperations(historyRows(after))];
}
/** Snapshot identity is shared across every page and every table; no partial snapshot is published. */
export async function snapshot(query,channel_id,maxRestarts=3,requestedTables=TABLES) {
 for(let attempt=0;attempt<maxRestarts;attempt++) {
  let generation;const tables={};
  try {
   for(const table of requestedTables) {
    const rows=[];let after;const seen=new Set();
    do {
     const page=await query(table,{version:1,channel_id,limit:200,...(generation!==undefined?{generation}:{}),...(after!==undefined?{after}:{})});
     if(page.version!==1 || typeof page.generation!=='string' || !Array.isArray(page.rows)) throw new Error('Invalid snapshot');
     if(generation!==undefined && generation!==page.generation) throw Object.assign(new Error('Snapshot changed'),{code:'snapshot_changed'});
     generation=page.generation;
     for(const row of page.rows) {if(seen.has(row.id)) throw new Error('Repeated snapshot row');seen.add(row.id);rows.push(row);}
     if(page.has_more && (!page.next_after || page.next_after===after || !page.rows.length)) throw new Error('Invalid snapshot cursor');
     after=page.has_more?page.next_after:undefined;
    } while(after!==undefined);
    tables[table]=rows;
   }
   // Final check catches writes after last child page. A failed authority check keeps prior local cache.
   await query('goals',{version:1,channel_id,limit:1,generation});
   return {version:1,generation,tables};
  } catch(e) {if(e.code!=='snapshot_changed' || attempt===maxRestarts-1) throw e;}
 }
}
