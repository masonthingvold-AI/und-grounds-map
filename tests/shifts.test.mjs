import test from 'node:test';
import assert from 'node:assert/strict';
import {ShiftTracker} from '../operations/shifts.mjs';
test('buffered GPS stays on the original shift when the active shift changes',async()=>{const sent=[];const tracker=new ShiftTracker({send:async(id,samples)=>sent.push({id,samples}),notify:()=>{}});await tracker.update({shift_id:'old'});tracker.samples=[{lat:1,lng:2}];await tracker.update({shift_id:'new'});assert.equal(sent[0].id,'old');assert.equal(tracker.samples.length,0);assert.equal(tracker.shift.shift_id,'new');});
test('local GPS persistence failure retains buffered samples for retry',async()=>{const tracker=new ShiftTracker({send:async()=>{throw Error('Storage unavailable');},notify:()=>{}});await tracker.update({shift_id:'s'});tracker.samples=[{lat:1}];await assert.rejects(tracker.flushSamples(),/Storage unavailable/);assert.equal(tracker.samples.length,1);});
