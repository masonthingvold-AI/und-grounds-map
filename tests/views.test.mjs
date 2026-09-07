import test from 'node:test';
import assert from 'node:assert/strict';
import {campusParcels,remainingInZone} from '../operations/views.mjs';
test('zone remaining work excludes other zones and terminal tasks',()=>{assert.deepEqual(remainingInZone([{zone_id:'A',state:'assigned'},{zone_id:'B',state:'assigned'},{zone_id:'A',state:'done'},{zone_id:'A',state:'canceled'}],'A'),[{zone_id:'A',state:'assigned'}]);});
test('campus excludes unrelated ownership and distant parcels',()=>{const f=(x,owner='und_state')=>({properties:{site:'main',owner_class:owner},geometry:{coordinates:[[[x,1],[x+.1,1],[x,1.1],[x,1]]]}});const inside=f(1);assert.deepEqual(campusParcels([inside,f(50),f(1,'greek')],{geometry:{coordinates:[[[0,0],[3,0],[3,3],[0,3],[0,0]]]}}),[inside]);});
