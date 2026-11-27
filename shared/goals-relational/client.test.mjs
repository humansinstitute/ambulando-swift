import {test} from 'node:test';import assert from 'node:assert/strict';import {readFileSync} from 'node:fs';
import {relationalClient} from './client.mjs';import * as lib from '../../scripts/goals-lib.mjs';
function fixture(){const f=JSON.parse(readFileSync(new URL('./current-rows-v1.json',import.meta.url))),sent=[];let pending=null;
 const request=async(method,path,body)=>{if(path.endsWith('/status'))return {version:1,authority:{mode:'active',revision:'1'}};
  if(path.endsWith('/query'))return {version:1,generation:'12',rows:f.tables[body.table],has_more:false,next_after:null};
  if(path.endsWith('/batch')){sent.push(body);return {version:1,operation_id:body.operation_id};}throw new Error(path);};
 const client=relationalClient({request,legacyClient:{request:async()=>{throw new Error('No new target lookup expected');}},workspace:f.tables.goals[0].workspace_id,channel:f.tables.goals[0].channel_id,owner:'npub1namespace',app:'npub1app',actor:'npub1agent',pending:{load:async()=>pending,save:async p=>{pending=p;}}});return {client,sent,f};
}
test('agent edit preserves existing goal owner distinct from namespace owner and signer',async()=>{const x=fixture();const goal=x.f.tables.goals[0];await x.client.edit(goal.id,[{op:'set_name',expected:goal.name,value:'Agent edit'}]);
 assert.equal(x.sent.length,1);for(const op of x.sent[0].operations)if(op.data?.owner_npub)assert.equal(op.data.owner_npub,'npub1fixture');assert.equal(x.sent[0].operations[0].expected_revision,7);
});
test('agent creation uses manager-protected channel marker owner',async()=>{const x=fixture();await x.client.create(lib.create({name:'Created by agent',description:'Separate owner'}));
 assert.equal(x.sent[0].operations.find(o=>o.table==='goals').data.owner_npub,'npub1fixture');
});
test('creation refuses unknown normalized schema before any mutation',async()=>{const x=fixture();x.f.tables.goals_authority[0].schema_version='future-2';await assert.rejects(x.client.create(lib.create({name:'No write',description:'Unsupported schema'})),/Unsupported/);assert.equal(x.sent.length,0);});
