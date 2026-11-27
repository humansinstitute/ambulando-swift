#!/usr/bin/env bun
// Broker-only operational CLI. No key files, environment secrets or implicit production activation.
import {readFile,writeFile,mkdir,rename} from 'node:fs/promises';
import path from 'node:path';import os from 'node:os';
import {parseLossless,canonical,digest} from '../shared/goals-relational/model.mjs';
import {sealPlan,verifyPlan} from '../shared/goals-relational/plan.mjs';
import {snapshot} from '../shared/goals-relational/wire.mjs';
import * as goalFormat from './goals-lib.mjs';
import {migrationOperations} from '../shared/goals-relational/operations.mjs';
const [command,...args]=process.argv.slice(2),opts={};for(let i=0;i<args.length;i+=2)opts[args[i].replace(/^--/,'')]=args[i+1];
const need=(...keys)=>keys.forEach(k=>{if(!opts[k])throw new Error(`--${k} required`);});
async function save(file,value){await mkdir(path.dirname(file),{recursive:true});await writeFile(file,canonical(value)+'\n',{flag:'wx',mode:0o600});}
async function connections(){
 need('tower','workspace','owner','app','channel');const {brokerSigner,towerClient}=await import(path.join(process.env.AMBULANDO_SOL||path.join(os.homedir(),'code/ambulando/sol'),'scripts/html-artifact/tower.mjs'));
 const origin=new URL(opts.tower);if(origin.protocol!=='https:'||origin.pathname!=='/'||origin.search||origin.hash||origin.username||origin.password)throw new Error('Exact HTTPS NStack origin required');
 for(const k of ['owner','app'])if(!/^npub1[a-z0-9]+$/.test(opts[k]))throw new Error('Invalid identity');
 for(const k of ['workspace','channel'])if(!/^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/.test(opts[k]))throw new Error('Invalid scope UUID');
 const sign=brokerSigner();
 const request=async(method,pathname,body)=>{
  if(!pathname.startsWith('/api/v4/')||pathname.includes('..'))throw new Error('Unsafe route');
  const url=origin.origin+pathname,bytes=body===undefined?null:Buffer.from(canonical(body));const {authorization}=await sign(url,method,bytes);
  const response=await fetch(url,{method,headers:{Authorization:authorization,'Content-Type':'application/json','x-flightdeck-pg-app-npub':opts.app},body:bytes});
  const raw=await response.text();const value=raw?parseLossless(raw):null;
  if(!response.ok)throw Object.assign(new Error(`${response.status} ${value?.code??value?.error??'request failed'}`),{status:response.status,code:value?.code??value?.error?.code});return value;
 };
 const root=`/api/v4/flightdeck-pg/workspaces/${opts.workspace}`,base=`/api/v4/workspaces/${opts.owner}/apps/${opts.app}/db/native-v1/${opts.workspace}`;
 const descriptor=await request('GET',`${root}/descriptor`);if(descriptor.identity?.workspace_id!==opts.workspace||descriptor.identity?.workspace_owner_npub!==opts.owner||descriptor.identity?.app_npub!==opts.app)throw new Error('Descriptor binding mismatch');
 const legacy=towerClient({baseUrl:origin.origin,workspaceId:opts.workspace,sign});legacy.root=root;
 async function pages(route,key){const out=[],seen=new Set();let cursor;
  do{const page=await request('GET',`${route}${route.includes('?')?'&':'?'}limit=200${cursor?'&cursor='+encodeURIComponent(cursor):''}`);if(!Array.isArray(page[key]))throw new Error('Incomplete source page');out.push(...page[key]);const next=page.next_cursor;if(!next){if(page[key].length>=200)throw new Error('Full source page without cursor');return out;}if(seen.has(next))throw new Error('Repeated source cursor');seen.add(next);cursor=next;}while(out.length<100000);throw new Error('Source limit');
 }
 async function inventory(){
  const grants=(await request('GET',`${root}/channels/${opts.channel}/grants`)).grants;if(!Array.isArray(grants))throw new Error('Missing grants');
  const channel=(await request('GET',`${root}/channels/${opts.channel}`)).channel;
  const members=(await request('GET',`${root}/members`)).members.map(m=>({actor_id:m.actor?.actor_id??m.actor?.id,npub:m.actor?.npub,kind:m.actor?.kind}));
  const ownerOnly=channel?.kind==='dm'&&canonical(channel.participant_npubs)===canonical([opts.owner]);
  if(!ownerOnly && (!goalFormat.isOwnedChannel(channel,opts.owner)||!goalFormat.classifyGrants({grants,members,owner:opts.owner}).safe))throw new Error('Unverified personal Goals boundary');
  const files=(await pages(`${root}/channels/${opts.channel}/files`,'files')).filter(f=>!f.archived_at&&!f.deleted_at&&f.record_state!=='deleted'&&f.content_type?.split(';')[0].trim().toLowerCase()==='application/vnd.ambulando.goal+json');
  const entries=[];
  for(const listed of files){const {file}=await request('GET',`${root}/files/${listed.id}`);const versions=await pages(`${root}/files/${file.id}/versions`,'versions');const version=versions.find(v=>v.id===file.current_version_id);if(!version||!version.sha256_hex)throw new Error('Missing exact current version/hash');
   const bytes=await legacy.readVersionBytes(file.id,version.id,{maxBytes:262144});if(digest(bytes)!==version.sha256_hex.toLowerCase()||bytes.length!==Number(version.size_bytes))throw new Error('Exact source digest/size mismatch');
   entries.push({source:{workspace_id:opts.workspace,channel_id:opts.channel,owner_npub:opts.owner,file_id:file.id,version_id:version.id,file_revision:String(file.row_version),file_created_at:file.created_at,file_updated_at:file.updated_at,sha256:digest(bytes),size_bytes:bytes.length},bytes_base64:bytes.toString('base64'),versions});
  }
  return {complete:true,scope:{workspace_id:opts.workspace,channel_id:opts.channel,owner_npub:opts.owner},grants,entries};
 }
 return {request,root,base,inventory};
}
try {
 if(command==='plan'){need('input','out');const plan=sealPlan(parseLossless(await readFile(opts.input)));await save(opts.out,plan);console.log(JSON.stringify({path:opts.out,sha256:plan.sha256,goals:plan.manifest.entries.length,batches:plan.batches.length}));}
 else if(command==='inspect'){
  need('out');const c=await connections();const status=await c.request('POST',`${c.base}/status`,{channel_id:opts.channel,content_type:'application/vnd.ambulando.goal+json'});
  const inventory=await c.inventory();const staged=await snapshot((table,q)=>c.request('POST',`${c.base}/query`,{...q,table,staging:true}),opts.channel);
  const me=await c.request('GET',`${c.root}/me`);const actor=me.actor?.npub??me.npub;if(!actor)throw new Error('Missing current actor identity');need('schema');
  await save(opts.out,{inventory,staged,schema:opts.schema,actor,timestamp:new Date().toISOString(),authority:status.authority,fence:status.fence});console.log(JSON.stringify({path:opts.out,goals:inventory.entries.length,source_fence:status.fence,authority:status.authority}));
 }else if(['stage','activate','export-recovery'].includes(command)){
  need('plan','reviewed-sha','evidence-dir');const plan=verifyPlan(parseLossless(await readFile(opts.plan)),opts['reviewed-sha']);const c=await connections();
  if(plan.scope.workspace_id!==opts.workspace||plan.scope.channel_id!==opts.channel||plan.scope.owner_npub!==opts.owner)throw new Error('Plan target mismatch');
  const ops=migrationOperations({...c,saveEvidence:async(name,value)=>{const file=path.join(opts['evidence-dir'],name+'.json');try{await save(file,value);}catch(e){if(e.code!=='EEXIST'||canonical(parseLossless(await readFile(file)))!==canonical(value))throw e;}}});
  const result=command==='stage'?await ops.stage(plan,opts['reviewed-sha']):command==='activate'?await ops.activate(plan,opts['reviewed-sha']):await ops.exportRecovery(plan,opts['reviewed-sha']);
  console.log(JSON.stringify({operation:command,sha256:result.sha256??null,generation:result.generation??null,authority:result.authority??null}));
 }else throw new Error('Usage: goals-relational.mjs inspect|plan|stage|activate|export-recovery (see shared/goals-relational/README.md)');
}catch(e){console.error(e.message);process.exitCode=1;}
