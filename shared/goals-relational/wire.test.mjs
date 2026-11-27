import {test} from 'node:test';import assert from 'node:assert/strict';
import {snapshot,editOperations,historyRows,insertOperations} from './wire.mjs';
test('coherent snapshot restarts whole read when generation changes between tables',async()=>{
 let changed=false,calls=0;
 const result=await snapshot(async(table,q)=>{calls++;if(table==='goal_checkpoints'&&!changed){changed=true;throw Object.assign(new Error(),{code:'snapshot_changed'});}return {version:1,generation:changed?'2':'1',rows:[],has_more:false,next_after:null};},'fixture');
 assert.equal(result.generation,'2');assert.equal(Object.keys(result.tables).length,8);assert.ok(calls > 8);
});
test('repeated pagination cursor and denied reads never publish partial snapshots',async()=>{
 await assert.rejects(snapshot(async()=>({version:1,generation:'1',rows:[{id:'a'}],has_more:true,next_after:'a'}),'fixture'),/Repeated/);
 await assert.rejects(snapshot(async()=>{throw new Error('permission_denied');},'fixture'),/permission_denied/);
});
test('parent CAS and normalized immutable history are one transaction',()=>{
 const before={goals:[{id:'goal',revision:4,name:'old',created_at:'t'}],goal_checkpoints:[{id:'cp',goal_id:'goal',revision:2,title:'old'}],goal_associations:[]};
 const after={goals:[{id:'goal',revision:5,name:'new',created_at:'t'}],goal_checkpoints:[{id:'cp',goal_id:'goal',revision:3,title:'new'}],goal_associations:[]};
 const ops=editOperations(before,after);assert.equal(ops[0].expected_revision,4);assert.equal(ops[1].expected_revision,2);
 assert.equal(ops[1].data.goal_id,undefined);assert.equal(ops[2].table,'goal_history');assert.equal(ops[3].table,'goal_checkpoint_history');
 assert.equal(ops[3].data.content_revision,5);assert.equal(ops[2].data.revision,undefined);
});
