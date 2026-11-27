// Stable operation IDs are shared by sealed import and SQL-native recovery plans.
// Executable staging/activation/recovery uses operations.mjs, not abstract legacy writer-switch adapters.
import {canonical,digest} from './model.mjs';
export function deterministicOperationId(kind,payload) {
 const h=digest(kind+':'+canonical(payload));return `${h.slice(0,8)}-${h.slice(8,12)}-5${h.slice(13,16)}-a${h.slice(17,20)}-${h.slice(20,32)}`;
}
