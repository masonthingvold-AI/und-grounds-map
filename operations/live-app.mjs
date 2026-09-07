import {showCertifications} from './certifications.mjs';
import {showBoard,showPeople} from './dispatch.mjs';
import {CommandQueue,LocationQueue} from './queue.mjs';
import {showQueue} from './queue-view.mjs';
import {showProof} from './proof.mjs';
import {ShiftTracker,showDayLog} from './shifts.mjs';
import {load,save} from './store.mjs';
import {taskCards,taskDetail,fieldError} from './worker.mjs';
import {client,login,signOut,readView,rpc} from './api.mjs';
import {mountShell} from './shell.mjs';
import {showMap,clearMap,showMessages,dashboard} from './views.mjs';
const $=s=>document.querySelector(s),esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let me=null,shift=null,mode={},route='day',tasks=[],shell,epoch=0,tracker,dayLog,queue,locations,replayTimer;
const canDispatch=()=>['lead','admin','oversight'].includes(me?.app_role);
const notify=message=>{if($('#notice'))$('#notice').textContent=message;};
function loginScreen(message=''){
 epoch++;tracker?.stop();clearInterval(replayTimer);queue&&(queue.stopped=true);me=null;clearMap();$('#shell').innerHTML=`<main class="login-panel"><img src="assets/und_leaders_rev.png" alt="University of North Dakota"><p class="eyebrow">UND Grounds</p><h1>Sign in to your day</h1><form id="login-form"><label for="email">Email</label><input id="email" type="email" autocomplete="username" required><label for="password">Password</label><input id="password" type="password" autocomplete="current-password" required><button class="primary">Sign in</button><p id="login-error" role="alert">${esc(message)}</p></form><p class="muted">Use your provisioned account. Face ID is not connected yet.</p></main>`;
 $('#login-form').onsubmit=async event=>{event.preventDefault();const button=event.target.querySelector('button');button.disabled=true;try{me=await login($('#email').value.trim(),$('#password').value);await enter();}catch(e){$('#login-error').textContent=e.message;button.disabled=false;}};
}
function updateShell(){shell.update({me,shift,operatingState:mode,route,pending:queue?.items.filter(c=>!['done','canceled'].includes(c.status)).length||0,unacknowledged:tasks.filter(t=>t.state==='assigned').length,reviewCount:tasks.filter(t=>t.state==='review').length});}
async function enter(){
 shell=mountShell($('#shell'),{onNavigate:r=>{route=r;render().catch(showError);},onSignOut:async()=>{tracker?.stop();await queue?.stop();await locations?.running;await signOut();loginScreen();}});
 $('.g-demo').textContent='Connected to UND Grounds · Provisioned test environment';
 const owner=me.id;
 const send=async(fn,args)=>{if(!navigator.onLine)throw Object.assign(Error('Waiting for a connection.'),{code:'NETWORK',retryable:true});const {data:{session}}=await client.auth.getSession();if(session?.user.id!==owner)throw Object.assign(Error('Sign in again to synchronize your work.'),{code:'401'});return rpc(fn,args);};
 queue=await new CommandQueue({owner,load,save,send,currentOwner:()=>me?.id,changed:error=>{if(error)showError(error);else if(me?.id===owner)updateShell();},completed:async item=>{if(item.fn==='shift_end'){await save(owner,'day-log',item.result.data.day_log);if(me?.id===owner)dayLog=item.result.data.day_log;}if(me?.id===owner)await refresh();}}).init();
 locations=await new LocationQueue({owner,load,save,send,currentOwner:()=>me?.id,notify}).init();
 tracker=new ShiftTracker({read:readView,owner,notify,onUpdate:async()=>{await refresh();updateShell();},send:(shift_id,samples)=>locations.add(shift_id,samples)});
 replayTimer=setInterval(()=>{queue.flush();locations.flush();},5000);

 await refresh();dayLog=await load(me.id,'day-log');await render();queue.flush();locations.flush();
}
async function refresh(){const values=await Promise.all([readView('v_my_shift'),readView('v_operating_state')]);shift=values[0][0]||null;mode=values[1][0]||{};await tracker?.update(shift);}
function showError(e){if(['401','GRND-401'].includes(e.code)){signOut();loginScreen('Your session ended. Sign in again.');}else notify(e.message);}
async function act(fn,args,meta={}){const item=await queue.add(fn,args,meta);if(item.status==='done'){await refresh();await render();return item.result;}if(item.status==='validation'||item.status==='review')throw Object.assign(Error(item.error.message),item.error);notify('Action saved on this device. It will synchronize when connected.');return {pending:true};}
const onLocation=async location=>{if(!shift)throw Error('Start your shift before starting work.');return tracker.capture(location);};
async function shiftAction(){try{
 if(shift){tracker.stop();const result=await act('shift_end',{shift_id:shift.shift_id});if(result.pending){notify('Shift end is queued after your pending work.');return;}dayLog=result.data.day_log;await save(me.id,'day-log',dayLog);route='day-log';await render();}
 else{try{await act('shift_start',{device_id:'grounds-web'});}catch(e){if(e.code!=='GRND-410')throw e;await refresh();}tracker.start();await render();}
}catch(e){showError(e);}}
async function render(){
 if(!me)return;const version=++epoch;clearMap();history.replaceState(null,'','#'+route);updateShell();$('#content').innerHTML='<p class="muted">Loading</p>';
 if(['dispatch','people'].includes(route)&&!canDispatch()){route='day';return render();}
 if(route==='certifications'){if(!['lead','admin'].includes(me.app_role)){route='day';return render();}await showCertifications($('#content'),{read:readView,act,me});return;}
 if(route==='dispatch'){tasks=await showBoard($('#content'),{read:readView,call:rpc,act,me});updateShell();return;}
 if(route==='people'){await showPeople($('#content'),{read:readView});return;}
 if(route==='day-log'&&dayLog){await showDayLog($('#content'),dayLog,{owner:me.id,act,onDone:()=>{dayLog=null;route='day';render();}});return;}
 if(route==='queue'){showQueue($('#content'),queue,{review:id=>taskDetail(id,{read:readView,act,me,onLocation,proof:task=>showProof(task,{owner:me.id})})});return;}
 if(route==='settings'){$('#content').innerHTML=`<h1>Your account</h1><article class="card"><h2>${esc(me.full_name)}</h2><p>${esc(me.app_role)} · ${esc(me.crew_name||'No crew')}</p><p class="muted">Signed in through Supabase Auth. Session refresh is automatic.</p></article>`;return;}
 if(route==='map'){await showMap($('#content'));return;}
 if(['messages','crew-lead'].includes(route)){showMessages($('#content'),route==='crew-lead');return;}
 if(route==='day'){
 tasks=await readView('v_my_day',{},'sort_key');if(version!==epoch)return;updateShell();
 $('#content').innerHTML=`<h1>My Day</h1><p>Welcome, ${esc(me.full_name)}.</p>${me.app_role!=='oversight'?`<div class=actions><button id=shift-action class=primary>${shift?'End shift':'Start shift'}</button>${shift?'<button id=track-location>Enable foreground location</button>':''}${dayLog?'<button id=review-time>Review unconfirmed time</button>':''}</div><p class=muted>${shift?(shift.location_stale?'Location stale':'Shift open'):'Off shift'} · Location runs only while this app is visible.</p>`:''}${taskCards(tasks)}`;
 if($('#shift-action'))$('#shift-action').onclick=shiftAction;if($('#track-location'))$('#track-location').onclick=()=>{tracker.start();notify('Foreground location enabled.');};if($('#review-time'))$('#review-time').onclick=()=>{route='day-log';render();};
 document.querySelectorAll('[data-task]').forEach(b=>b.onclick=()=>taskDetail(b.dataset.task,{read:readView,act,me,onLocation,proof:task=>showProof(task,{owner:me.id})}));return;
 }
 $('#content').innerHTML='<h1>Workspace</h1><p class="muted">This screen is being connected to the live contract.</p>';
}
const {data:{session}}=await client.auth.getSession();
if(session){try{[me]=await readView('v_me');if(!me?.active)throw Error('Profile unavailable');await enter();}catch(e){loginScreen(e.message);}}else loginScreen();
client.auth.onAuthStateChange(event=>{if(event==='SIGNED_OUT'&&me)loginScreen('You have signed out.');});
