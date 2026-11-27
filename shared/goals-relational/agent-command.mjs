import {readFile,writeFile,mkdir,rename,unlink,open} from 'node:fs/promises';import path from 'node:path';import os from 'node:os';
import {digest,canonical} from './model.mjs';import {relationalClient} from './client.mjs';import * as lib from '../../scripts/goals-lib.mjs';
const read=async file=>{try{return JSON.parse(await readFile(file,'utf8'));}catch(e){if(e.code==='ENOENT')return null;throw e;}};
/** Upgrade the existing agent CLI at its repository seam; legacy is used only while server authority allows it. */
export async function nativeAgentCommand(c,options,command,out) {
 if(!['list','show','create','edit','move'].includes(command))return false;
 const descriptor=await c.request('GET',`${c.root}/descriptor`),identity=descriptor.identity;
 if(identity?.workspace_id!==options.workspace)throw new Error('Workspace descriptor mismatch');
 const owner=identity.workspace_owner_npub,app=identity.app_npub,base=`/api/v4/workspaces/${owner}/apps/${app}/db/native-v1/${options.workspace}`;
 let channel=options.channel;
 if(!channel&&options.file){
  try{channel=(await c.getFile(options.file)).file.channel_id;}
  catch(e){if(e.status!==404)throw e;const found=await c.request('POST',`${base}/read`,{version:1,table:'goals',id:options.file});channel=found.channel_id;}
 }
 if(!channel)return false;
 const me=await c.request('GET',`${c.root}/me`),actor=me.actor?.npub??me.npub??me.membership?.npub;
 if(!actor)throw new Error('Current signing actor unavailable');
 const binding=digest(canonical({tower:options.tower??process.env.WINGMAN_TOWER_URL,workspace:options.workspace,owner,app,channel,actor}));
 const directory=options['state-dir']??path.join(os.homedir(),'.local/state/ambulando/goals');await mkdir(directory,{recursive:true,mode:0o700});
 const file=path.join(directory,binding+'.json'),lockfile=file+'.lock';
 async function acquire(){try{const handle=await open(lockfile,'wx',0o600);await handle.writeFile(String(process.pid));return handle;}catch(e){if(e.code!=='EEXIST')throw e;const pid=Number(await readFile(lockfile,'utf8'));if(!Number.isSafeInteger(pid))throw new Error('Pending Goals lock requires inspection');try{process.kill(pid,0);}catch(err){if(err.code==='ESRCH'){await unlink(lockfile);return acquire();}throw err;}throw new Error('Another Goals command owns this pending request store');}}
 const lock=await acquire();let state=(await read(file))??{binding,observed:false,pending:null};if(state.binding!==binding)throw new Error('Pending request binding mismatch');
 async function save(){const temp=file+'.'+process.pid+'.tmp';await writeFile(temp,JSON.stringify(state),{mode:0o600});await rename(temp,file);}
 try {
  const repository=relationalClient({request:c.request.bind(c),legacyClient:c,workspace:options.workspace,owner,app,channel,actor,pending:{load:async()=>state.pending,save:async body=>{state.pending=body;await save();},observe:async()=>{state.observed=true;await save();},observed:async()=>state.observed}});
  let mode;try{mode=await repository.state();}catch(e){if(e.status===404&&!state.observed)return false;throw e;}if(mode==='legacy')return false;
  if(command==='list'){const values=await repository.list();out({goals:lib.focusOrder(values.map(v=>({...v,id:v.id}))).map(v=>({file_id:v.id,version_id:v.versionId,focus_rank:lib.focusRank(v.goal),...v.goal}))});}
  else if(command==='show'){if(!options.file)throw new Error('--file required');const value=await repository.read(options.file);out({file_id:value.id,channel_id:channel,version_id:value.versionId,goal:value.goal});}
  else if(command==='create'){if(!options.name||!options.description)throw new Error('--name and --description required');const value=await repository.create(lib.create({name:options.name,description:options.description,start_date:options.start,target_date:options.target}));out({file_id:value.id,version_id:value.versionId,goal:value.goal});}
  else if(command==='edit'){if(!options.file||!options.ops)throw new Error('--file and --ops required');const edits=JSON.parse(options.ops);if(!Array.isArray(edits)||!edits.length)throw new Error('Nonempty --ops required');const value=await repository.edit(options.file,edits);out({file_id:value.id,version_id:value.versionId,changed:value.changed,goal:value.goal});}
  else {if(!options.file||options.to===undefined)throw new Error('--file and --to required');const values=await repository.list();const writes=lib.planMove(lib.focusOrder(values.filter(v=>v.goal.status==='active')),options.file,Number(options.to));for(const w of writes)await repository.edit(w.id,[{op:'set_focus_rank',expected:w.expected,value:w.value}]);out({moved:options.file,writes});}
  return true;
 } finally {await lock.close();await unlink(lockfile);}
}
