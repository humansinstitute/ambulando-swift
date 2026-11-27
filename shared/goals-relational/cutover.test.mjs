import {test} from 'node:test';import assert from 'node:assert/strict';import {deterministicOperationId} from './cutover.mjs';
test('operation identity is deterministic across object key order and differs for another exact version',()=>{
 const a=deterministicOperationId('import',{file:'goal',version:'v1',sha256:'digest'});
 assert.equal(a,deterministicOperationId('import',{sha256:'digest',version:'v1',file:'goal'}));
 assert.notEqual(a,deterministicOperationId('import',{file:'goal',version:'v2',sha256:'digest'}));assert.match(a,/^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/);
});
