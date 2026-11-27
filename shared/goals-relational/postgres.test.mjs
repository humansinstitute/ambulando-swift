import {test} from 'node:test';import assert from 'node:assert/strict';import {readFileSync} from 'node:fs';
import {migration,importBatch} from './deployment.mjs';import {normalize,digest} from './model.mjs';
const enabled=!!process.env.GOALS_TEST_DATABASE_URL;
test('PostgreSQL normalized import, atomic child failure, stale CAS, reorder and retained history recovery',{skip:!enabled},async()=>{
 const {default:postgres}=await import(process.env.GOALS_TEST_POSTGRES_MODULE??'postgres');
 const sql=postgres(process.env.GOALS_TEST_DATABASE_URL,{max:4});const schema='goals_test_'+Date.now();
 const table=t=>`"${schema}"."${t}"`;
 try {
  await sql.unsafe(`CREATE SCHEMA "${schema}"`);await sql.unsafe(migration(schema).sql);
  const b=readFileSync(new URL('../../docs/fixtures/goals/android-written-v1.json',import.meta.url)),id='11111111-1111-4111-8111-111111111111';
  const n=normalize(b,{workspace_id:id,channel_id:id,file_id:id,version_id:id,file_revision:1,owner_npub:'npub1fixture',sha256:digest(b),size_bytes:b.length});
  const batch=importBatch(n,{timestamp:'2026-11-27T00:00:00Z',actor:'npub1fixture'});
  async function apply(tx,op){const data={...op.data,id:op.id,workspace_id:id,channel_id:id,revision:1};const keys=Object.keys(data);const values=keys.map(k=>data[k]&&typeof data[k]==='object'?tx.json(data[k]):data[k]);
   return tx.unsafe(`INSERT INTO ${table(op.table)} (${keys.map(k=>`"${k}"`).join(',')}) VALUES (${keys.map((_,i)=>'$'+(i+1)).join(',')})`,values);}
  await sql.begin(async tx=>{for(const op of batch.operations)await apply(tx,op);});
  const [g]=await sql.unsafe(`SELECT name,revision FROM ${table('goals')}`);assert.equal(g.name,n.goal.name);assert.equal(g.revision,'1');
  const cps=await sql.unsafe(`SELECT checkpoint_id FROM ${table('goal_checkpoints')} ORDER BY position`);assert.deepEqual(cps.map(c=>c.checkpoint_id),n.checkpoints.map(c=>c.checkpoint_id));
  await assert.rejects(sql.begin(async tx=>{await tx.unsafe(`UPDATE ${table('goals')} SET name='Should rollback',revision=2 WHERE id=$1`,[id]);await tx.unsafe(`UPDATE ${table('goal_checkpoints')} SET title='' WHERE goal_id=$1`,[id]);}));
  assert.equal((await sql.unsafe(`SELECT name FROM ${table('goals')}`))[0].name,n.goal.name);
  const results=await Promise.all([1,2].map(()=>sql.unsafe(`UPDATE ${table('goals')} SET revision=revision+1 WHERE id=$1 AND revision=1 RETURNING revision`,[id])));assert.equal(results.filter(r=>r.length===1).length,1);
  await sql.begin(async tx=>{await tx.unsafe(`UPDATE ${table('goal_checkpoints')} SET position=CASE position WHEN 0 THEN 1 WHEN 1 THEN 0 ELSE position END WHERE goal_id=$1`,[id]);});
  assert.equal((await sql.unsafe(`SELECT checkpoint_id FROM ${table('goal_checkpoints')} ORDER BY position`))[0].checkpoint_id,n.checkpoints[1].checkpoint_id);
  // Immutable normalized import revision survives current edits; source Files were never touched.
  assert.equal((await sql.unsafe(`SELECT name FROM ${table('goal_history')} WHERE content_revision=1`))[0].name,n.goal.name);
  assert.equal((await sql.unsafe(`SELECT count(*)::int AS n FROM ${table('goal_checkpoint_history')}`))[0].n,n.checkpoints.length);
  await assert.rejects(sql.unsafe(`UPDATE ${table('goal_checkpoints')} SET channel_id='22222222-2222-4222-8222-222222222222' WHERE goal_id=$1`,[id]));
 }finally{await sql.unsafe(`DROP SCHEMA IF EXISTS "${schema}" CASCADE`);await sql.end();}
});
