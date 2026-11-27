import {readFileSync} from 'node:fs';
import {digest} from './model.mjs';
import {importRows,insertOperations} from './wire.mjs';
import {deterministicOperationId} from './cutover.mjs';
export const mapper_sha256=digest(['./model.mjs','./wire.mjs','../../scripts/goals-lib.mjs'].map(name=>name+'\n'+readFileSync(new URL(name,import.meta.url),'utf8')).join('\n')); 
/** Render only the verified allocated schema; checksums are over the exact submitted SQL. */
export function migration(schema) {
 if(!/^[a-z][a-z0-9_]{0,62}$/.test(schema))throw new Error('Invalid allocated schema');
 const template=readFileSync(new URL('./001-goals.sql',import.meta.url),'utf8');
 const sql=template.replace(/\b(CREATE TABLE) ([a-z_]+)/g,(_,verb,name)=>`${verb} "${schema}"."${name}"`)
  .replace(/\bREFERENCES ([a-z_]+)/g,(_,name)=>`REFERENCES "${schema}"."${name}"`)
  .replace(/\bON ([a-z_]+) \(/g,(_,name)=>`ON "${schema}"."${name}" (`);
 return {version:'ambulando-goals-relational-1',checksum:`sha256:${digest(sql)}`,sql};
}
export function policies() {
 const template=readFileSync(new URL('./001-goals.sql',import.meta.url),'utf8');
 const tables=[...template.matchAll(/CREATE TABLE (\w+) \(([\s\S]*?)\n\);/g)];
 return tables.map(([,table,body])=>{
  // Explicit column declarations are line- or comma-separated; constraints are ignored.
  const columns=[...body.matchAll(/(?:^|[,\n])\s*([a-z_][a-z0-9_]*)\s+(?:text|uuid|bigint|integer|date|boolean|jsonb|timestamptz)\b/g)].map(m=>m[1]).filter(c=>!['id','workspace_id','channel_id','revision'].includes(c));
  const parent=table==='goal_checkpoint_history'||table==='goal_association_history'?{table:'goal_history',column:'history_id'}:
    ['goal_checkpoints','goal_associations','goal_imports','goal_history'].includes(table)?{table:'goals',column:'goal_id'}:null;
  return {table,policy:{version:1,columns,...(parent?{parent}:{}),...(['goal_imports','goals_authority'].includes(table)?{manager_only_writes:true}:{}),...(table.includes('history')||table==='goal_imports'?{append_only:true}:{}),managed_content_type:'application/vnd.ambulando.goal+json'}};
 });
}
export function importBatch(normalized,{timestamp,actor}) {
 const rows=importRows(normalized,{revision:1,timestamp,actor,mapper_sha256});
 return {version:1,staging:true,operation_id:deterministicOperationId('import',{provenance:normalized.provenance,mapper_sha256}),channel_id:normalized.goal.channel_id,operations:insertOperations(rows)};
}
