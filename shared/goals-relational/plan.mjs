import {canonical,digest,normalize,manifest,denormalize,parseLossless} from './model.mjs';
import {importRows,editOperations,insertOperations} from './wire.mjs';
import {mapper_sha256,migration,policies} from './deployment.mjs';
import {deterministicOperationId} from './cutover.mjs';
import {normalizedAt} from './client.mjs';
const check=(ok,message)=>{if(!ok)throw new Error(message);};
export function sourceManifest(inventory) {
 check(inventory.complete===true && !inventory.unreadable?.length,'Incomplete source inventory');
 const normalized=inventory.entries.map(e=>normalize(Buffer.from(e.bytes_base64,'base64'),e.source));
 return {normalized,manifest:{...manifest(normalized),grants_sha256:digest(canonical([...inventory.grants].sort((a,b)=>canonical(a).localeCompare(canonical(b))))),history_sha256:digest(canonical(inventory.entries.map(e=>({file_id:e.source.file_id,versions:[...e.versions].sort((a,b)=>String(a.id).localeCompare(String(b.id)))})).sort((a,b)=>a.file_id.localeCompare(b.file_id))))}};
}
/** Seal after fencing; stale staged parents are reconciled by expected revisions, never a new conflicting insert. */
export function sealPlan({inventory,staged,schema,actor,timestamp,authority,fence}) {
 check(authority.mode==='staging','Only staging authority can be planned');check(fence.active===true,'Fence before planning actual imports');
 check(Number.isSafeInteger(Number(authority.revision)) && Number.isSafeInteger(Number(fence.revision)),'Invalid authority/fence revision');
 const {normalized,manifest:m}=sourceManifest(inventory);const batches=[];
 for(const n of normalized) {
  const id=n.goal.goal_id, previous=staged.tables.goals.find(g=>g.id===id), imported=staged.tables.goal_imports.find(r=>r.goal_id===id&&r.source_version_id===n.provenance.version_id);
  if(imported) {
   check(imported.source_sha256===n.provenance.sha256 && imported.normalized_sha256===n.normalized_sha256 && imported.mapper_sha256===mapper_sha256,'Existing immutable provenance mismatch');
   check(previous && canonical(parseLossless(denormalize(normalizedAt(staged.tables,id))))===canonical(parseLossless(denormalize(n))),'Imported source differs from staged current content');continue;
  }
  const revision=previous?Number(previous.revision)+1:1;check(Number.isSafeInteger(revision),'Unsafe staged revision');
  const rows=importRows(n,{revision,timestamp,actor,mapper_sha256});if(previous)rows.goals[0].created_at=previous.created_at;
  const before=Object.fromEntries(['goals','goal_checkpoints','goal_associations'].map(t=>[t,staged.tables[t].filter(r=>t==='goals'?r.id===id:r.goal_id===id)]));
  const operations=previous?[...editOperations(before,rows),...insertOperations({goal_imports:rows.goal_imports})]:insertOperations(rows);
  batches.push({version:1,staging:true,operation_id:deterministicOperationId('sealed-import',{source:n.provenance,mapper_sha256,revision,timestamp}),channel_id:n.goal.channel_id,operations});
 }
 const identities=new Set(normalized.map(n=>`${n.goal.workspace_id}:${n.goal.channel_id}:${n.goal.owner_npub}`));check(identities.size<=1,'Plan spans authority collections');
 check(staged.tables.goals.every(g=>normalized.some(n=>n.goal.goal_id===g.id)),'Staged collection contains unexpected goal identities');
 const first=normalized[0]?.goal??inventory.scope;check(first,'Inventory scope required for empty collection');
 const marker={id:first.channel_id,workspace_id:first.workspace_id,channel_id:first.channel_id,revision:1,owner_npub:first.owner_npub,mode:'relational',epoch:Number(authority.revision)+1,contract_version:1,schema_version:'ambulando-goals-relational-1',mapper_sha256,manifest_sha256:m.sha256,source_fence_revision:Number(fence.revision),updated_at:timestamp,updated_by_npub:actor};
 const oldMarker=staged.tables.goals_authority.find(r=>r.id===marker.id);
 const markerOp=insertOperations({goals_authority:[marker]})[0];
 if(oldMarker){markerOp.kind='update';markerOp.expected_revision=Number(oldMarker.revision);}
 batches.push({version:1,staging:true,operation_id:deterministicOperationId('manifest-marker',{manifest:m,marker}),channel_id:first.channel_id,operations:[markerOp]});
 const plan={format:'ambulando.goals.sealed-migration',version:1,scope:{workspace_id:first.workspace_id,channel_id:first.channel_id,owner_npub:first.owner_npub},actor,timestamp,authority,fence,manifest:m,mapper_sha256,migration:migration(schema),policies:policies(),batches,sources:inventory};
 return {...plan,sha256:digest(canonical(plan))};
}
export function verifyPlan(plan,expectedDigest) {
 const {sha256,...body}=plan;check(sha256===expectedDigest&&digest(canonical(body))===sha256,'Sealed plan digest mismatch');
 check(plan.mapper_sha256===mapper_sha256,'Mapper changed since candidate review');check(plan.version===1&&plan.format==='ambulando.goals.sealed-migration','Unsupported plan');return plan;
}
export function verifyStaged(plan,snapshot) {
 const {normalized}=sourceManifest(plan.sources),ids=normalized.map(n=>n.goal.goal_id).sort();
 check(canonical(snapshot.tables.goals.map(g=>g.id).sort())===canonical(ids),'Staged goal count/identity mismatch');
 for(const n of normalized) {
  const id=n.goal.goal_id,current=normalizedAt(snapshot.tables,id);
  check(canonical(parseLossless(denormalize(current)))===canonical(parseLossless(denormalize(n))),`Staged content mismatch ${id}`);
  const ledger=snapshot.tables.goal_imports.find(r=>r.goal_id===id&&r.source_version_id===n.provenance.version_id);
  check(ledger?.source_sha256===n.provenance.sha256&&ledger.normalized_sha256===n.normalized_sha256&&ledger.mapper_sha256===plan.mapper_sha256,'Staged provenance mismatch');
  const revision=String(current.goal.revision);const history=snapshot.tables.goal_history.find(r=>r.goal_id===id&&String(r.content_revision)===revision);
  check(history,'Missing normalized recovery revision');
  const saved={goal:{...history,goal_id:id},checkpoints:snapshot.tables.goal_checkpoint_history.filter(r=>r.history_id===history.id),associations:snapshot.tables.goal_association_history.filter(r=>r.history_id===history.id)};
  check(canonical(parseLossless(denormalize(saved)))===canonical(parseLossless(denormalize(n))),'Recovery revision mismatch');
 }
 const marker=snapshot.tables.goals_authority.find(r=>r.id===plan.scope.channel_id);
 check(marker?.manifest_sha256===plan.manifest.sha256&&marker.mapper_sha256===plan.mapper_sha256,'Manifest marker mismatch');return true;
}
