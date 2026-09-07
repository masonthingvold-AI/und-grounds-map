import test from 'node:test';
import assert from 'node:assert/strict';
import {navigationFor,humanError} from '../operations/shell.mjs';
const routes=role=>navigationFor(role).flatMap(([, ,items])=>items.map(([id])=>id));
test('worker and unknown roles cannot see dispatch or records',()=>{for(const role of ['worker','temp2',undefined])assert.deepEqual(routes(role),['day','map','status']);});
test('lead has dispatch and records without admin destinations',()=>{assert.ok(routes('lead').includes('dispatch'));assert.ok(routes('lead').includes('evidence'));assert.ok(!routes('lead').includes('certifications'));});
test('oversight has records without dispatch or admin',()=>{assert.ok(routes('oversight').includes('records'));assert.ok(!routes('oversight').includes('dispatch'));assert.ok(!routes('oversight').includes('mode'));});
test('admin sees all eleven destinations',()=>assert.equal(routes('admin').length,11));
test('API errors show human text and never a bare code',()=>{assert.equal(humanError('GRND-403: You cannot assign this task.'),'You cannot assign this task.');assert.equal(humanError('GRND-409'),'This action could not be completed.');});
