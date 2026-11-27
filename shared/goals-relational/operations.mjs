import {canonical,digest,denormalize,parseLossless} from './model.mjs';
import {snapshot} from './wire.mjs';import {verifyPlan,sourceManifest,verifyStaged} from './plan.mjs';
const check=(ok,message)=>{if(!ok)throw new Error(message);};
/** Concrete native-v1 operations; caller supplies broker request and authorized source inventory reader. */
export function migrationOperations({request,base,inventory,saveEvidence}) {
 const call=(action,body)=>request('POST',`${base}/${action}`,body);
 const status=plan=>call('status',{channel_id:plan.scope.channel_id,content_type:'application/vnd.ambulando.goal+json'});
 const stagedSnapshot=plan=>snapshot((table,q)=>call('query',{...q,table,staging:true}),plan.scope.channel_id);
 async function sourcesMatch(plan){const current=sourceManifest(await inventory()).manifest;check(canonical(current)===canonical(plan.manifest),'Post-fence source heads/grants/history changed; review a new candidate');}
 async function currentFence(plan){const s=await status(plan);check(s.fence?.active===true && String(s.fence.revision)===String(plan.fence.revision),'Reviewed source fence changed');return s;}
 return {
  async stage(plan,reviewedDigest){verifyPlan(plan,reviewedDigest);await sourcesMatch(plan);const s=await currentFence(plan);check(s.authority?.mode==='staging','Staging authority required');
   for(const body of plan.batches){const result=await call('batch',body);await saveEvidence(`operation-${body.operation_id}`,result);}
   const saved=await stagedSnapshot(plan);verifyStaged(plan,saved);await saveEvidence('staged-snapshot',saved);return saved;
  },
  async activate(plan,reviewedDigest){verifyPlan(plan,reviewedDigest);await sourcesMatch(plan);const s=await currentFence(plan);check(s.authority?.mode==='staging','Staging authority required');
   const saved=await stagedSnapshot(plan);verifyStaged(plan,saved);
   const receipt=await call('authority',{channel_id:plan.scope.channel_id,content_type:'application/vnd.ambulando.goal+json',mode:'active',expected_revision:Number(s.authority.revision),expected_generation:saved.generation,expected_fence_revision:Number(plan.fence.revision)});
   await saveEvidence('active-authority',receipt);return receipt;
  },
  async exportRecovery(plan,reviewedDigest){verifyPlan(plan,reviewedDigest);const s=await status(plan);check(s.authority?.mode==='frozen','Freeze SQL before recovery export');
   const saved=await stagedSnapshot(plan),entries=[];
   for(const history of saved.tables.goal_history) {
    const rows={goal:{...history,goal_id:history.goal_id},checkpoints:saved.tables.goal_checkpoint_history.filter(r=>r.history_id===history.id),associations:saved.tables.goal_association_history.filter(r=>r.history_id===history.id)};
    const bytes=denormalize(rows);entries.push({goal_id:history.goal_id,revision:String(history.content_revision),sha256:digest(bytes),bytes_base64:bytes.toString('base64')});
   }
   for(const parent of saved.tables.goals)check(entries.some(e=>e.goal_id===parent.id&&e.revision===String(parent.revision)),'Latest SQL revision missing from recovery archive');
   const archive={format:'ambulando.goals.normalized-recovery',version:1,scope:plan.scope,generation:saved.generation,authority:s.authority,entries,snapshot:saved};
   const sealed={...archive,sha256:digest(canonical(archive))};await saveEvidence('recovery-archive',sealed);return sealed;
  }
 };
}
