import {canonical,digest,normalizeContent,denormalize} from './model.mjs';import {editOperations,currentRows} from './wire.mjs';import {deterministicOperationId} from './cutover.mjs';
const check=(ok,message)=>{if(!ok)throw new Error(message);};
export function verifyArchive(archive){const {sha256,...body}=archive;check(archive.format==='ambulando.goals.normalized-recovery'&&archive.version===1&&digest(canonical(body))===sha256,'Recovery archive digest mismatch');
 for(const e of archive.entries)check(digest(Buffer.from(e.bytes_base64,'base64'))===e.sha256,'Recovery revision digest mismatch');
 for(const parent of archive.snapshot.tables.goals)check(archive.entries.some(e=>e.goal_id===parent.id&&e.revision===String(parent.revision)),'Recovery archive incomplete');return archive;
}
/** SQL-native forward repair: restored content becomes a new CAS revision, preserving every prior SQL revision. */
export function repairPlan(archive,choices,{actor,timestamp}) {
 verifyArchive(archive);const tables=archive.snapshot.tables,operations=[];
 for(const choice of choices){const entry=archive.entries.find(e=>e.goal_id===choice.goal_id&&e.revision===String(choice.revision));check(entry,'Requested recovery revision missing');
  const parent=tables.goals.find(g=>g.id===choice.goal_id);check(parent,'Current recovery parent missing');const revision=Number(parent.revision)+1;check(Number.isSafeInteger(revision),'Unsafe recovery revision');
  const n=normalizeContent(Buffer.from(entry.bytes_base64,'base64'),{workspace_id:parent.workspace_id,channel_id:parent.channel_id,owner_npub:parent.owner_npub,goal_id:parent.id});
  const after=currentRows(n,{revision,timestamp,actor});after.goals[0].created_at=parent.created_at;
  const before=Object.fromEntries(['goals','goal_checkpoints','goal_associations'].map(t=>[t,tables[t].filter(r=>t==='goals'?r.id===parent.id:r.goal_id===parent.id)]));operations.push(...editOperations(before,after));
 }
 check(operations.length>0&&operations.length<=3000,'Repair exceeds bounded batch; split reviewed collections');
 const body={version:1,staging:true,channel_id:archive.scope.channel_id,operation_id:deterministicOperationId('sql-forward-repair',{archive:archive.sha256,choices,actor,timestamp}),operations};
 return {format:'ambulando.goals.sql-repair',version:1,archive_sha256:archive.sha256,expected_generation:archive.generation,body,sha256:digest(canonical(body))};
}
