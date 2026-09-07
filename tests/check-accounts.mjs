import {readFileSync} from 'node:fs';
import {runInThisContext} from 'node:vm';
runInThisContext(readFileSync(new URL('../operations/vendor/supabase.js',import.meta.url),'utf8'));
const {login,signOut}=await import('../operations/api.mjs');
for(const account of ['boss','chad','lead','jordan','sam','other']){const me=await login(account+'@test.invalid',process.env.GROUNDS_TEST_PASSWORD);console.log(JSON.stringify({account,role:me.app_role,crew:me.crew_name,name:me.full_name}));await signOut();}
