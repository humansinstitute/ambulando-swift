// Reviewable deterministic cutover protocol. All persistence/ACL/fence operations are supplied by the supported
// server adapter. No production adapter is selected implicitly. Every awaited write must have durable receipts.
import {canonical,digest,manifest,normalize,denormalize} from './model.mjs';
const same=(a,b)=>canonical(a)===canonical(b);
const check=(ok,message)=>{if(!ok)throw new Error(message);};
export function deterministicOperationId(kind, payload) {
 const h=digest(kind+':'+canonical(payload));return `${h.slice(0,8)}-${h.slice(8,12)}-5${h.slice(13,16)}-a${h.slice(17,20)}-${h.slice(20,32)}`;
}
export async function inventory(adapter) {
 const sources=await adapter.inventory();
 check(sources.complete===true && !sources.unreadable?.length,'Incomplete or unreadable source collection');
 return sources.entries.map(({bytes,source})=>normalize(bytes,source));
}
export async function stage(adapter) {
 const rows=await inventory(adapter), m=manifest(rows);
 for(const row of rows) {
  check(same(JSON.parse(denormalize(row)), JSON.parse((await adapter.sourceVersion(row.provenance)).toString('utf8'))),'Round-trip mismatch');
  await adapter.stage(row,deterministicOperationId('import',row.provenance));
 }
 return m;
}
/** This adapter method is deliberately atomic: server owns lock/fence + source CAS + authority epoch. */
export async function activate(adapter, reviewedManifest) {
 check(adapter.production!==true || adapter.managerReviewed===true,'Manager review required for production activation');
 const before=await adapter.authority();
 check(before.mode==='legacy' || before.mode==='frozen','Already relational; reconcile existing receipt');
 const fence=await adapter.freezeSource(before.revision);
 check(fence.active===true,'Source write fence not acknowledged');
 const current=await stage(adapter);
 check(same(current,reviewedManifest),'Post-fence manifest changed; restage and review');
 const operation_id=deterministicOperationId('activate',{manifest:current,epoch:before.epoch+1,fence_revision:fence.revision});
 return adapter.activateAtomic({operation_id,expected_authority_revision:before.revision,source_fence_revision:fence.revision,manifest:current});
}
export async function rollback(adapter) {
 check(adapter.production!==true || adapter.managerReviewed===true,'Manager review required for production rollback');
 const frozen=await adapter.freezeTarget();
 check(frozen.mode==='frozen','Target writes must be frozen');
 const revisions=await adapter.recoveryRevisions();
 check(revisions.complete===true,'Incomplete normalized history');
 const exports=[];
 for(const revision of revisions.rows) {
  const bytes=denormalize(revision), sha256=digest(bytes);
  const operation_id=deterministicOperationId('recovery',{goal_id:revision.goal.goal_id,revision:revision.revision,sha256});
  const receipt=await adapter.exportRecovery({revision,bytes,sha256,operation_id});
  check(receipt.sha256===sha256 && receipt.verified===true,'Recovery export verification failed');exports.push(receipt);
 }
 const manifest_sha256=digest(canonical(exports));
 // Server transaction must keep SQL frozen while releasing source writer; never a dual-writer interval.
 return adapter.restoreLegacyAtomic({expected_authority_revision:frozen.revision,exports,manifest_sha256,
  operation_id:deterministicOperationId('restore',{revision:frozen.revision,manifest_sha256})});
}
