const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export const remainingInZone=(tasks,id)=>tasks.filter(t=>t.zone_id===id&&!['done','canceled'].includes(t.state));
export const campusParcels=features=>features.filter(f=>f.properties.site==='main'&&f.properties.owner_class==='und_state');
let dataPromise;
const data=()=>dataPromise??=Promise.all(['parcels','mowing_areas','snow_routes'].map(async n=>{const r=await fetch('../data/'+n+'.geojson');if(!r.ok)throw Error('Map data could not be loaded.');return r.json();}));
let activeMap;
export function clearMap(){activeMap?.remove();activeMap=null;}
function mapInto(element,features){
 const map=L.map(element,{attributionControl:false,scrollWheelZoom:false});activeMap=map;
 const layer=L.geoJSON(features,{style:{color:'#009A44',fillColor:'#009A44',fillOpacity:.14,weight:2},onEachFeature:(f,l)=>l.bindTooltip(esc(f.properties.name||f.properties.id))}).addTo(map);
 const bounds=layer.getBounds();if(bounds.isValid()){map.fitBounds(bounds,{padding:[24,24]});map.setMaxBounds(bounds.pad(.15));map.setMinZoom(map.getZoom()-1);}
 return map;
}
export async function showMap(target){
 target.innerHTML='<p class="eyebrow">Your campus</p><h1>UND campus</h1><p class="muted">UND state-owned campus parcels. City streets and surrounding property are not shown. Parcel outlines are not the final grounds service boundary.</p><div id="campus-focus" class="focus-map" aria-label="UND campus parcel map"></div><p class="muted">Source: City of Grand Forks parcel inventory. Campus service boundary still needs tracing.</p>';
 try{const [parcels]=await data();if(!target.querySelector('#campus-focus'))return;mapInto(target.querySelector('#campus-focus'),campusParcels(parcels.features));}catch(e){target.textContent=e.message;}
}
export async function showZone(target,tasks,openTask,ask){
 const zones=[...new Map(tasks.map(t=>[t.zone_id,t.zone_name])).entries()];
 target.innerHTML=`<p class="eyebrow">One area at a time</p><h1>Zone status</h1><label for="zone-choice">Choose a zone</label><select id="zone-choice">${zones.map(([id,name])=>`<option value="${esc(id)}">${esc(name)}</option>`).join('')}</select><div id="zone-work"></div>`;
 const select=target.querySelector('select');if(!zones.length){target.querySelector('#zone-work').textContent='No assigned zones to show.';return;}
 let request=0;
 async function draw(){const version=++request,id=select.value,remaining=remainingInZone(tasks,id),body=target.querySelector('#zone-work');clearMap();
 body.innerHTML=`<div class="zone-layout"><div><div id="zone-focus" class="focus-map small"></div><p class="muted">Zone geometry is a tracing placeholder. Confirm the actual work area with your lead.</p></div><section><h2>${remaining.length} tasks left</h2>${remaining.map(t=>`<article class="card"><span class="tag">Priority ${t.priority}</span><h3>${esc(t.outcome)}</h3><p class="muted">${esc(t.state.replaceAll('_',' '))}</p><button data-task="${esc(t.task_id)}">View task</button></article>`).join('')||'<p>No remaining assigned tasks in this zone.</p>'}<h2>Other ways to help</h2><p class="muted">Ask your lead before changing assignments. These are suggestions, not assigned work.</p>${['Report a hazard','Check for litter or obstructions','Ask for another task in this zone'].map(label=>`<button class="suggestion" data-suggest="${esc(label)}">${label}</button>`).join('')}</section></div>`;
 body.querySelectorAll('[data-task]').forEach(b=>b.onclick=()=>openTask(b.dataset.task));body.querySelectorAll('[data-suggest]').forEach(b=>b.onclick=()=>ask(b.dataset.suggest+' · '+select.selectedOptions[0].textContent));
 try{const [,mowing,snow]=await data();if(version!==request||!body.isConnected)return;const feature=[...mowing.features,...snow.features].find(f=>f.properties.id===id);if(feature)mapInto(body.querySelector('#zone-focus'),[feature]);else body.querySelector('#zone-focus').textContent='No geometry available for this zone.';}catch(e){if(body.isConnected)body.querySelector('#zone-focus').textContent=e.message;}
 }
 select.onchange=draw;await draw();
}
export function showMessages(target,crewLead=false,prefill=''){
 target.innerHTML=`<p class="eyebrow">Stay connected</p><h1>${crewLead?'Ask my crew lead':'Messages'}</h1><div class="card"><h2>${crewLead?'Your crew lead':'Crew messages'}</h2><p class="muted">Messaging is not connected yet. You can prepare a draft here; nothing is sent.</p><label for="message-draft">${crewLead?'What do you need help with?':'Draft message'}</label><textarea id="message-draft" placeholder="Describe the task, location, or help you need"></textarea><button id="save-message">Save draft on this device</button><p id="draft-status" role="status"></p></div>`;
 const input=target.querySelector('textarea');try{input.value=prefill||sessionStorage.getItem('grounds-message-draft')||'';}catch{input.value=prefill;}
 target.querySelector('#save-message').onclick=()=>{try{sessionStorage.setItem('grounds-message-draft',input.value);target.querySelector('#draft-status').textContent='Draft saved for this preview session. Not sent.';}catch{target.querySelector('#draft-status').textContent='Draft could not be saved. Keep this screen open.';}};
}
export function dashboard(target,state){
 const content=document.createElement('section');content.className='day-dashboard';
 content.innerHTML=`<div class="day-hero"><p class="eyebrow">${new Intl.DateTimeFormat('en-US',{weekday:'long',month:'long',day:'numeric'}).format(new Date())}</p><h2>Your day, ready to go</h2><p>Check your schedule, see what matters, and head to your first task.</p><span class="g-mode">${state.mode==='snow'?'SNOW':'LANDSCAPING'}</span></div><div class="day-context"><article class="card"><p class="eyebrow">Grand Forks forecast</p><div id="day-weather">Loading forecast</div><a href="https://forecast.weather.gov/MapClick.php?lat=47.922&lon=-97.073" target="_blank" rel="noopener">National Weather Service</a></article><article class="card"><p class="eyebrow">Your schedule</p><h3>Meetings and events</h3><p class="muted">Your schedule is not connected yet. Meetings and events will appear here alongside your work.</p></article></div>`;
 target.prepend(content);loadWeather(content.querySelector('#day-weather'));
}
let weatherCache;
async function loadWeather(target){
 try{if(!weatherCache||Date.now()-weatherCache.at>600000){const point=await fetch('https://api.weather.gov/points/47.922,-97.073',{signal:AbortSignal.timeout(10000)});if(!point.ok)throw Error();const p=await point.json();const response=await fetch(p.properties.forecast,{signal:AbortSignal.timeout(10000)});if(!response.ok)throw Error();const forecast=await response.json();weatherCache={at:Date.now(),period:forecast.properties.periods.find(p=>Date.parse(p.endTime)>Date.now()),updated:forecast.properties.updated};}
 const p=weatherCache.period;if(!p)throw Error();target.innerHTML=`<h3>${esc(p.temperature)}°${esc(p.temperatureUnit)} · ${esc(p.shortForecast)}</h3><p>${esc(p.name)} · Wind ${esc(p.windSpeed)} ${esc(p.windDirection)}</p><p class="muted">Forecast updated ${esc(new Date(weatherCache.updated).toLocaleString())}</p>`;
 }catch{target.textContent='Forecast unavailable. Check the National Weather Service for current conditions.';}
}
export function promptShift(start){
 const dialog=document.createElement('dialog');dialog.className='arrival';dialog.setAttribute('aria-label','Start your day');
 dialog.innerHTML='<p class="eyebrow">UND Grounds</p><h1>Ready to start your shift?</h1><p>Sign in, confirm your shift, and see your day.</p><button id="arrival-start" class="primary">Start shift</button><button id="arrival-later">Just reviewing</button><div id="arrival-auth"></div>';
 document.body.append(dialog);dialog.querySelector('#arrival-later').onclick=()=>{dialog.close();dialog.remove();};
 dialog.querySelector('#arrival-start').onclick=()=>{dialog.querySelector('#arrival-auth').innerHTML='<h2>Confirm it is you</h2><p>Face ID sign-in is planned. This preview cannot authenticate with Face ID or clock you into a real shift.</p><button disabled>Face ID not connected</button><button id="preview-entry" class="primary">Continue with test shift</button>';dialog.querySelector('#arrival-start').hidden=true;dialog.querySelector('#preview-entry').onclick=async()=>{await start();dialog.close();dialog.remove();};};
 dialog.showModal();
}
