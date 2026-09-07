import {escape,displayTime,fieldError,getLocation} from './worker.mjs';
import {load,save} from './store.mjs';
export class ShiftTracker{
 constructor({read,send,owner,notify,onUpdate}){Object.assign(this,{read,send,owner,notify,onUpdate});this.shift=null;this.samples=[];this.enabled=false;this.timer=null;this.busy=false;}
 async update(shift){this.shift=shift;if(!shift)this.stop();}
 start(){if(this.enabled||!this.shift)return;this.enabled=true;this.tick();this.timer=setInterval(()=>this.tick(),30000);}
 stop(){this.enabled=false;clearInterval(this.timer);this.timer=null;}
 async flushSamples(){if(this.samples.length&&this.shift){const samples=this.samples;this.samples=[];await this.send(this.shift.shift_id,samples);}}
 async capture(location){if(!this.shift)throw Error('Start your shift first.');await this.send(this.shift.shift_id,[{...location,source:'gps'}]);}
 async tick(){if(!this.enabled||!this.shift||document.hidden||this.busy)return;this.busy=true;try{const location=await getLocation();if(!this.enabled||!this.shift||document.hidden)return;this.samples.push({...location,source:'gps'});if(!this.lastSent||Date.now()-this.lastSent>=60000){await this.send(this.shift.shift_id,this.samples);this.samples=[];this.lastSent=Date.now();await this.onUpdate();}}catch(e){this.notify(e.message);}finally{this.busy=false;}}
}
export async function showDayLog(target,log,{owner,act,onDone}){
 await save(owner,'day-log',log);
 const entries=(log.tasks||[]).map(t=>({task_id:t.task_id,work_order_id:t.work_order_id,zone_id:t.zone_id,external_ref:t.external_ref,suggested_minutes:t.suggested_minutes,minutes:Math.max(0,Math.round(t.suggested_minutes||0)),label:t.work_order_number||t.zone_name||'Task'}));
 if(!entries.length)entries.push({minutes:0,label:'Other work',note:''});
 target.innerHTML=`<h1>Review your shift</h1><p>${escape(displayTime(log.started_at))} to ${escape(displayTime(log.ended_at))}</p><p class="muted">Shift duration: ${escape(log.shift_minutes)} minutes. Edit suggested task time to reflect your actual work, including breaks and travel.</p><form id="confirm-time">${entries.map((e,i)=>`<label for="minutes-${i}">${escape(e.label)} · Minutes</label><input id="minutes-${i}" type="number" min="0" step="1" value="${e.minutes}" required><label for="time-note-${i}">Note</label><input id="time-note-${i}" value="">`).join('')}<button class="primary" ${log.confirmed?.length?'disabled':''}>${log.confirmed?.length?'Time already confirmed':'Confirm my time'}</button><div id="time-error" role="alert"></div></form><h2>Zone presence</h2><p class="muted">Location suggests time; it does not confirm time worked.</p>${(log.zones||[]).map(z=>`<p>${escape(z.zone_name)} · ${escape(z.minutes)} minutes</p>`).join('')||'<p>No zone presence samples.</p>'}`;
 target.querySelector('form').onsubmit=async event=>{event.preventDefault();const button=event.target.querySelector('button');button.disabled=true;try{const confirmed=entries.map(({label,...e},i)=>({...e,minutes:Number(target.querySelector('#minutes-'+i).value),note:target.querySelector('#time-note-'+i).value}));if(confirmed.some(e=>!Number.isInteger(e.minutes)||e.minutes<0))throw Error('Enter whole minutes of zero or greater.');const result=await act('time_entries_confirm',{shift_id:log.shift_id,entries:confirmed});if(result.pending){button.textContent='Confirmation queued';return;}await save(owner,'day-log',null);onDone();}catch(e){fieldError(target.querySelector('#time-error'),e);button.disabled=false;}};
}
