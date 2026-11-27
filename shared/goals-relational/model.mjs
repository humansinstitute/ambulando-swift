// App-owned normalized representation. No credentials, networking, or authority inference.
import { createHash } from 'node:crypto';
import { parse } from '../../scripts/goals-lib.mjs';
export const MAPPER_VERSION = 'ambulando-goals-relational-1';
export const digest = bytes => createHash('sha256').update(bytes).digest('hex');
export const canonical = value => JSON.stringify(sort(value));
function sort(v) { if(JSON.isRawJSON?.(v)) return v; return Array.isArray(v) ? v.map(sort) : v && typeof v === 'object' ? Object.fromEntries(Object.keys(v).sort().map(k => [k, sort(v[k])])) : v; }
export const parseLossless = bytes => JSON.parse(Buffer.from(bytes).toString('utf8'), (key,value,context) => typeof value === 'number' && context?.source && JSON.stringify(value)!==context.source ? JSON.rawJSON(context.source) : value);
const presence=(o,keys)=>Object.keys(o).filter(k=>keys.includes(k)).flatMap(k=>o[k]===null?[k,`@null:${k}`]:[k]).sort();
const uuid = v => typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(v);
const need = (ok, message) => { if (!ok) throw new Error(message); };
const extra = (o, keys) => Object.fromEntries(Object.entries(o).filter(([k]) => !keys.includes(k)));
const cpKeys = ['id','title','date','description','reached'];
const refKeys = ['type','record_id','channel_id'];
const topKeys = ['schema','schema_version','name','description','start_date','target_date','status','focus_rank','default_channel_id','checkpoints','links','pinned_refs'];
const rank = v => typeof v === 'string' && /^[0-9A-Za-z]{1,64}$/.test(v) && !v.endsWith('0');
function refs(list, lane, scope) {
  need(Array.isArray(list) && list.length <= (lane === 'pin' ? 100 : 500), 'Invalid references');
  const seen = new Set();
  return list.map((r, position) => {
    need(r && ['chat','task','doc','file'].includes(r.type) && uuid(r.record_id) && (r.channel_id == null || uuid(r.channel_id)), 'Invalid reference');
    need(lane !== 'pin' || ['doc','file'].includes(r.type), 'Only Docs and Files can be pinned');
    const key = `${r.type}:${r.record_id}`; need(!seen.has(key), 'Duplicate reference'); seen.add(key);
    return {...scope, lane, kind:r.type, record_id:r.record_id, target_channel_id:r.channel_id ?? null, position, extensions:extra(r,refKeys),present_fields:presence(r,refKeys)};
  });
}
/** Input provenance must come from an authorized immutable File-version read, never a guessed head. */
export function normalize(bytes, source) {
  need(bytes.byteLength <= 262144, 'Goal too large');
  for (const k of ['workspace_id','channel_id','file_id','version_id']) need(uuid(source[k]), `Invalid ${k}`);
  need(typeof source.owner_npub === 'string' && source.owner_npub.startsWith('npub1'), 'Invalid owner');
  need(/^[0-9]+$/.test(String(source.file_revision)), 'Invalid source revision');
  need(source.sha256 === digest(bytes) && source.size_bytes === bytes.byteLength, 'Source digest/size mismatch');
  const content = normalizeContent(bytes,{workspace_id:source.workspace_id,channel_id:source.channel_id,owner_npub:source.owner_npub,goal_id:source.file_id});
  const provenance = {...source, mapper_version:MAPPER_VERSION};
  const normalized = {...content, provenance};
  return {...normalized, normalized_sha256:digest(canonical(normalized))};
}
/** New relational writes share content mapping without inventing a legacy File version/provenance. */
export function normalizeContent(bytes,scope) {
  need(bytes.byteLength<=262144,'Goal too large');
  for(const k of ['workspace_id','channel_id','goal_id'])need(uuid(scope[k]),`Invalid ${k}`);
  parse(bytes); // Existing shared v1 validation, including unknown-field preservation.
  const g = parseLossless(bytes);
  need(g.default_channel_id == null || uuid(g.default_channel_id), 'Invalid default channel');
  const extensions = extra(g,topKeys);
  // Invalid focus_rank was historically retained as an extension; it has no ordering meaning.
  if (g.focus_rank != null && !rank(g.focus_rank)) extensions.focus_rank = g.focus_rank;
  const goal = {...scope, name:g.name, description:g.description, start_date:g.start_date ?? null, target_date:g.target_date ?? null,
    status:g.status, focus_rank:rank(g.focus_rank) ? g.focus_rank : null, default_channel_id:g.default_channel_id ?? null, extensions,
    // Presence is compatibility metadata, not an opaque copy of known state.
    present_fields:presence(g,topKeys)};
  const checkpoints = (g.checkpoints ?? []).map((c,position) => ({...scope, checkpoint_id:c.id, title:c.title, date:c.date ?? null,
    description:c.description ?? null, reached:c.reached ?? false, position, extensions:extra(c,cpKeys), present_fields:presence(c,cpKeys)}));
  const associations = [...refs(g.links ?? [],'link',scope), ...refs(g.pinned_refs ?? [],'pin',scope)];
  return {goal,checkpoints,associations};
}
/** Recovery export uses normalized facts; retained source bytes/history remain independently available. */
const extensionObject = value => typeof value === 'string' ? parseLossless(value) : value;
export function denormalize(rows) {
  const g = rows.goal, present = new Set(g.present_fields);
  const out = {...extensionObject(g.extensions), schema:'ambulando.goal',schema_version:1,name:g.name,description:g.description,status:g.status};
  for (const k of ['start_date','target_date','focus_rank','default_channel_id']) if(g[k] != null) out[k]=g[k]; else if(present.has(k) && !(k in out)) out[k]=null;
  const ordered = values => [...values].sort((a,b)=>a.position-b.position);
  out.checkpoints=ordered(rows.checkpoints).map(c=>{
    const o={...extensionObject(c.extensions),id:c.checkpoint_id,title:c.title};
    for(const k of ['date','description']) if(c[k]!=null || c.present_fields.includes(k)) o[k]=c[k];
    if(c.present_fields.includes('reached')) o.reached=c.present_fields.includes('@null:reached')?null:c.reached;
    return o;
  });
  const link = r=>({...extensionObject(r.extensions),type:r.kind,record_id:r.record_id,...(r.target_channel_id!=null?{channel_id:r.target_channel_id}:r.present_fields?.includes('channel_id')?{channel_id:null}:{})});
  out.links=ordered(rows.associations.filter(r=>r.lane==='link')).map(link);
  const pins=ordered(rows.associations.filter(r=>r.lane==='pin')).map(link);
  if(pins.length || present.has('pinned_refs')) out.pinned_refs=pins;
  for(const k of ['checkpoints','links']) if(!present.has(k) && out[k].length===0) delete out[k];
  for(const k of ['checkpoints','links','pinned_refs']) if(present.has(`@null:${k}`))out[k]=null;
  return Buffer.from(canonical(out));
}
export function manifest(rows) {
  const entries=rows.map(r=>({file_id:r.provenance.file_id,version_id:r.provenance.version_id,sha256:r.provenance.sha256,
    file_revision:String(r.provenance.file_revision),normalized_sha256:r.normalized_sha256})).sort((a,b)=>a.file_id.localeCompare(b.file_id));
  need(new Set(entries.map(e=>e.file_id)).size===entries.length,'Duplicate source head');
  return {mapper_version:MAPPER_VERSION,entries,sha256:digest(canonical(entries))};
}
