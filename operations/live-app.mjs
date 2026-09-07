import {client,login,signOut,readView,rpc} from './api.mjs';
import {mountShell} from './shell.mjs';
import {showMap,clearMap,showMessages,dashboard} from './views.mjs';
const $=s=>document.querySelector(s),esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let me=null,shift=null,mode={},route='day',tasks=[],shell,epoch=0;
const canDispatch=()=>['lead','admin','oversight'].includes(me?.app_role);
const notify=message=>{if($('#notice'))$('#notice').textContent=message;};
function loginScreen(message=''){
 epoch++;me=null;clearMap();$('#shell').innerHTML=`<main class="login-panel"><img src="assets/und_leaders_rev.png" alt="University of North Dakota"><p class="eyebrow">UND Grounds</p><h1>Sign in to your day</h1><form id="login-form"><label for="email">Email</label><input id="email" type="email" autocomplete="username" required><label for="password">Password</label><input id="password" type="password" autocomplete="current-password" required><button class="primary">Sign in</button><p id="login-error" role="alert">${esc(message)}</p></form><p class="muted">Use your provisioned account. Face ID is not connected yet.</p></main>`;
 $('#login-form').onsubmit=async event=>{event.preventDefault();const button=event.target.querySelector('button');button.disabled=true;try{me=await login($('#email').value.trim(),$('#password').value);await enter();}catch(e){$('#login-error').textContent=e.message;button.disabled=false;}};
}
function updateShell(){shell.update({me,shift,operatingState:mode,route,pending:0,unacknowledged:tasks.filter(t=>t.state==='assigned').length,reviewCount:tasks.filter(t=>t.state==='review').length});}
async function enter(){
 shell=mountShell($('#shell'),{onNavigate:r=>{route=r;render().catch(showError);},onSignOut:async()=>{await signOut();loginScreen();}});
 $('.g-demo').textContent='Connected to UND Grounds · Provisioned test environment';
 await refresh();await render();
}
async function refresh(){const values=await Promise.all([readView('v_my_shift'),readView('v_operating_state')]);shift=values[0][0]||null;mode=values[1][0]||{};}
function showError(e){if(['401','GRND-401'].includes(e.code)){signOut();loginScreen('Your session ended. Sign in again.');}else notify(e.message);}
async function render(){
 if(!me)return;const version=++epoch;clearMap();history.replaceState(null,'','#'+route);updateShell();$('#content').innerHTML='<p class="muted">Loading</p>';
 if(route==='settings'){$('#content').innerHTML=`<h1>Your account</h1><article class="card"><h2>${esc(me.full_name)}</h2><p>${esc(me.app_role)} · ${esc(me.crew_name||'No crew')}</p><p class="muted">Signed in through Supabase Auth. Session refresh is automatic.</p></article>`;return;}
 if(route==='map'){await showMap($('#content'));return;}
 if(['messages','crew-lead'].includes(route)){showMessages($('#content'),route==='crew-lead');return;}
 if(route==='day'){$('#content').innerHTML=`<h1>My Day</h1><p>Welcome, ${esc(me.full_name)}.</p><p class="muted">Your live profile is connected. Task controls are being connected next.</p>`;return;}
 $('#content').innerHTML='<h1>Workspace</h1><p class="muted">This screen is being connected to the live contract.</p>';
}
const {data:{session}}=await client.auth.getSession();
if(session){try{[me]=await readView('v_me');if(!me?.active)throw Error('Profile unavailable');await enter();}catch(e){loginScreen(e.message);}}else loginScreen();
client.auth.onAuthStateChange(event=>{if(event==='SIGNED_OUT'&&me)loginScreen('You have signed out.');});
