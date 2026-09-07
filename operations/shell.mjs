const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export const groups = [
 ['WORK', null, [['day','My Day','sun'],['map','Map','map'],['status','Zone status','layers']]],
 ['DISPATCH',['lead','admin'],[['dispatch','Board','columns-3'],['people','People','users'],['assets','Assets','tractor']]],
 ['RECORDS',['lead','admin','oversight'],[['records','Service records','clipboard-list'],['evidence','Evidence','camera']]],
 ['ADMIN',['admin'],[['certifications','Certifications','badge-check'],['keep-outs','Keep-outs','octagon-alert'],['mode','Mode','snowflake']]]
];
export const navigationFor = role => groups.filter(([, roles]) => !roles || roles.includes(role));
export const humanError = value => String(value ?? '').replace(/GRND-[\w-]+\s*:\s*/g, '').replace(/GRND-[\w-]+/g, 'This action could not be completed.');
const icon = name => `<i data-lucide="${name}" aria-hidden="true"></i>`;
const saved = (key, fallback) => { try { return localStorage.getItem(key) ?? fallback; } catch { return fallback; } };
const remember = (key, value) => { try { localStorage.setItem(key,value); } catch {} };
export function mountShell(root, {onNavigate, onSignOut}) {
 let state = {}, compact = saved('und-grounds-compact','true') === 'true';
 root.innerHTML = `<header class="g-header"><a class="g-logo" href="https://und.edu" aria-label="University of North Dakota"><img src="assets/und_leaders_rev.png" alt="University of North Dakota"></a><div class="g-title"><span>UND</span><span>GROUNDS</span></div><button class="g-avatar" aria-label="Account" aria-expanded="false" aria-controls="account-menu"></button><div id="account-menu" class="g-account" hidden><p>Local layout preview</p><button data-action="settings">Settings</button><button data-action="theme">Change theme</button><button data-action="signout">Sign out</button></div></header><nav class="g-rail" aria-label="Grounds navigation"></nav><main class="g-main"><div class="inner"><p class="g-demo">LOCAL PREVIEW · Synthetic people and work · No live dispatch or server verification</p><div id="notice" role="status" aria-live="polite"></div><div id="content"></div></div></main><nav class="g-bottom" aria-label="Mobile navigation"></nav><dialog class="g-sheet" aria-label="More navigation"><button class="g-close" data-action="close">Close</button><div class="g-more-content"></div></dialog>`;
 const rail = root.querySelector('.g-rail'), sheet = root.querySelector('.g-sheet'), account = root.querySelector('.g-account'), avatar = root.querySelector('.g-avatar');
 const row = ([id,label,glyph], mobile=false) => `<a class="srow" href="#${id}" data-route="${id}" data-tip="${escape(label)}" aria-label="${escape(label)}" ${state.route===id?'aria-current="page"':''}>${icon(glyph)}<span class="g-label">${mobile&&id==='status'?'Status':label}</span>${['day','dispatch'].includes(id)?`<span class="badge ${(id==='day'?state.unacknowledged:state.reviewCount)>0?'live':''}">${id==='day'?state.unacknowledged||0:state.reviewCount||0}</span>`:''}</a>`;
 function person() {
  const shift = state.shift?.shift_id, stale = shift && state.shift?.location_stale;
  return `<div class="g-person"><div class="g-name">${escape(state.me?.full_name || 'Not signed in')}</div><div class="g-meta">${escape(state.me?.app_role || '')} · ${escape(state.me?.crew_name || 'No crew')}</div><div class="g-shift"><span class="g-dot ${stale?'stale':shift?'on':''}"></span>${stale?'Location stale':shift?'On shift':'Off shift'}</div><span class="g-mode">${state.operatingState?.mode==='snow'?'SNOW':'LANDSCAPING'}</span></div>`;
 }
 function footer() {
  return `<div class="g-foot"><a class="srow" href="#queue" data-route="queue" data-tip="${state.pending?state.pending+' pending':'Synced'}" aria-label="Saved actions, ${state.pending?state.pending+' pending':'Synced'}">${icon('cloud')}<span class="g-label">${state.pending?'Saved actions':'Synced'}</span>${state.pending?`<span class="badge live">${state.pending} pending</span>`:''}</a><button data-action="theme" data-tip="Change theme" aria-label="Change theme">${icon('sun-moon')}<span class="g-label">${document.documentElement.dataset.theme==='dark'?'Light theme':'Dark theme'}</span></button><a class="srow" href="#settings" data-route="settings" data-tip="Settings" aria-label="Settings">${icon('settings')}<span class="g-label">Settings</span></a><button data-action="signout" data-tip="Sign out" aria-label="Sign out">${icon('log-out')}<span class="g-label">Sign out</span></button><button class="g-collapse" data-action="collapse" aria-label="${compact?'Expand':'Collapse'} navigation" aria-expanded="${!compact}" data-tip="${compact?'Expand':'Collapse'} navigation">${icon(compact?'chevron-right':'chevron-left')}<span class="g-label">Collapse</span></button></div>`;
 }
 function draw() {
  const groupsHTML = navigationFor(state.me?.app_role).map(([label,,items])=>`<div class="g-group"><p class="slabel">${label}</p>${items.map(item=>row(item)).join('')}</div>`).join('');
  rail.innerHTML = person()+'<div class="g-links">'+groupsHTML+'</div>'+footer();
  root.querySelector('.g-more-content').innerHTML = person()+`<nav aria-label="More destinations">${groupsHTML}</nav>`+footer();
  const tabs = [...groups[0][2], ...(navigationFor(state.me?.app_role).some(([name])=>name==='DISPATCH')?[groups[1][2][0]]:[])];
  root.querySelector('.g-bottom').innerHTML = tabs.map(item=>row(item,true)).join('')+`<a href="#more" data-action="more" aria-haspopup="dialog">${icon('menu')}<span>More</span></a>`;
  avatar.textContent = (state.me?.full_name || 'Guest').split(' ').map(p=>p[0]).slice(0,2).join('');
  root.querySelector('.inner').classList.toggle('wide',['map','dispatch','people','assets'].includes(state.route));
  resize(); window.lucide?.createIcons();
 }
 function resize() { rail.classList.toggle('compact',window.innerWidth<=1100 && compact); }
 function closeAccount() { account.hidden=true; avatar.setAttribute('aria-expanded','false'); }
 avatar.onclick = () => { account.hidden=!account.hidden; avatar.setAttribute('aria-expanded',String(!account.hidden)); };
 root.addEventListener('click', event => {
  const target=event.target.closest('[data-route],[data-action]'); if(!target)return;
  if(target.dataset.route){event.preventDefault();sheet.close();closeAccount();onNavigate(target.dataset.route);return;}
  event.preventDefault();
  switch(target.dataset.action){
   case 'more': sheet.showModal(); break;
   case 'close': sheet.close(); break;
   case 'collapse': compact=!compact;remember('und-grounds-compact',String(compact));draw();break;
   case 'theme': document.documentElement.dataset.theme=document.documentElement.dataset.theme==='dark'?'light':'dark';remember('und-grounds-theme',document.documentElement.dataset.theme);draw();break;
   case 'settings': closeAccount();onNavigate('settings');break;
   case 'signout': sheet.close();closeAccount();onSignOut();break;
  }
 });
 document.addEventListener('click',event=>{if(!account.contains(event.target)&&!avatar.contains(event.target))closeAccount();});
 document.addEventListener('keydown',event=>{if(event.key==='Escape')closeAccount();});
 window.addEventListener('resize',resize);
 return {update(next){state=next;draw();}};
}
