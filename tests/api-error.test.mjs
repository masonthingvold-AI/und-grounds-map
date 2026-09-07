import test from 'node:test';
import assert from 'node:assert/strict';
globalThis.supabase={createClient:()=>({})};
const {apiError}=await import('../operations/api.mjs');
test('permission and database errors are not treated as transient server failures',()=>{
 for(const code of ['42501','23505','403','404'])assert.equal(apiError({code,message:'Rejected'}).retryable,false);
 for(const status of [500,502,503])assert.equal(apiError({message:'Unavailable'},status).retryable,true);
 assert.equal(apiError({message:'GRND-422: Fix the fields',details:'{"fields":["reason"]}'},400).code,'GRND-422');
 assert.equal(apiError({message:'GRND-422: Fix the fields'},400).message,'Fix the fields');
});
