export const workerId='0d2d3f2e-1111-4a5b-9c3e-000000000001';
export const samId='0d2d3f2e-1111-4a5b-9c3e-000000000003';
export const adminId='0d2d3f2e-1111-4a5b-9c3e-000000000002';
export function seed(){return {mode:'snow',revision:17,shift:null,results:{},people:[
 {profile_id:workerId,full_name:'Jordan Test',capabilities:['TOOLCAT','SALT_SPREADER','SMALL_TOOLS'],on_shift:false},
 {profile_id:samId,full_name:'Sam Test',capabilities:['SMALL_TOOLS','SALT_SPREADER'],on_shift:true}],tasks:[
 {task_id:'3c3c0000-0000-4000-8000-000000000201',assignment_id:'7b7b0000-0000-4000-8000-000000000101',task_revision:2,task_type:'shovel',outcome:'Clear and treat the assigned walk, then document the result.',zone_name:'Walk route 2',zone_id:'SW-2',state:'assigned',season:'snow',priority:1,assignee_id:workerId,asset_name:'Toolcat (synthetic assignment)',required_capabilities:['TOOLCAT'],evidence_required:['photo_before','photo_after','material_qty','location']},
 {task_id:'3c3c0000-0000-4000-8000-000000000202',assignment_id:null,task_revision:1,task_type:'inspect',outcome:'Inspect the marked pedestrian area and report hazards.',zone_name:'Practice inspection area',zone_id:'SW-4',state:'unassigned',season:'snow',priority:2,assignee_id:null,asset_name:null,required_capabilities:['SMALL_TOOLS'],evidence_required:['photo_before','photo_after','material_qty','location']},
 {task_id:'3c3c0000-0000-4000-8000-000000000203',assignment_id:'7b7b0000-0000-4000-8000-000000000103',task_revision:1,task_type:'inspect',outcome:'Inspect turf and record areas needing follow-up.',zone_name:'Summer carryover example',zone_id:'MOW-03',state:'assigned',season:'landscaping',priority:3,assignee_id:workerId,asset_name:null,required_capabilities:['SMALL_TOOLS'],evidence_required:['photo_after','location']}]};}
export class ContractError extends Error{constructor(code,message,fields=[]){super(message);this.code=code;this.fields=fields;}}
export const fail=(code,message,fields)=>{throw new ContractError(code,message,fields);};
export function candidates(state,task){return state.people.map(p=>({...p,missing_capabilities:task.required_capabilities.filter(c=>!p.capabilities.includes(c)),current_task:state.tasks.find(t=>t.assignee_id===p.profile_id&&t.state==='in_progress')?.outcome||null}));}
export function execute(state,fn,args,caller){
 const cacheKey=caller+':'+args.idempotency_key;
 if(state.results[cacheKey]){if(state.results[cacheKey].fn!==fn)fail('GRND-422','Key used for another command');return {...state.results[cacheKey].result,replayed:true};}
 const admin=caller===adminId;
 let data,task;
 if(fn==='shift_start'){if(admin)fail('GRND-403','Choose the worker preview');if(state.shift)fail('GRND-410','Shift is already open');state.shift={shift_id:crypto.randomUUID(),started_at:new Date().toISOString()};state.people[0].on_shift=true;data=state.shift;}
 else if(fn==='shift_end'){if(caller!==workerId||!state.shift||state.shift.shift_id!==args.shift_id)fail('GRND-410','No matching open shift');data={...state.shift,ended_at:new Date().toISOString(),open_task_ids:state.tasks.filter(t=>t.assignee_id===caller&&!['done','review'].includes(t.state)).map(t=>t.task_id)};state.shift=null;state.people[0].on_shift=false;}
 else if(fn==='operating_state_pivot'){if(!admin)fail('GRND-403','Supervisor only');if(args.expected_revision!==state.revision)fail('GRND-409','Mode changed. Refresh before trying again.');state.mode=args.to_mode;state.revision++;data={mode:state.mode,revision:state.revision};}
 else {
 task=state.tasks.find(t=>t.task_id===args.task_id||t.assignment_id===args.assignment_id);if(!task)fail('GRND-404','Task not found');
 if(args.expected_revision!==task.task_revision)fail('GRND-409','Assignment changed. Review the current task before trying again.');
 if(['task_assign','assignment_reassign','task_approve'].includes(fn)){if(!admin)fail('GRND-403','Supervisor only');}
 else if(task.assignee_id!==caller)fail('GRND-403','This task belongs to someone else');
 if(fn==='task_assign'||fn==='assignment_reassign'){
 if(fn==='task_assign'&&task.state!=='unassigned')fail('GRND-410','Task is already assigned');
 if(fn==='assignment_reassign'&&!['assigned','accepted','in_progress'].includes(task.state))fail('GRND-410','Task cannot be reassigned in this state');
 const person=candidates(state,task).find(p=>p.profile_id===(args.profile_id||args.to_profile_id));if(!person)fail('GRND-404','Person not found');if(person.missing_capabilities.length)fail('GRND-423','Missing qualification: '+person.missing_capabilities.join(', '));if(!person.on_shift)fail('GRND-425','Person is off shift');
 task.assignee_id=person.profile_id;task.assignment_id=crypto.randomUUID();task.state='assigned';
 }else if(fn==='assignment_acknowledge'){if(task.state!=='assigned')fail('GRND-410','Task is not awaiting acknowledgment');task.state='accepted';}
 else if(fn==='task_start'){if(!state.shift)fail('GRND-425','Start your shift first');if(task.state!=='accepted')fail('GRND-410','Accept the assignment first');if(!args.location)fail('GRND-422','Location is required');task.state='in_progress';task.started_at=new Date().toISOString();}
 else if(fn==='task_block'){if(!args.reason?.trim())fail('GRND-422','Add a reason');task.state='blocked';task.blocked_reason=args.reason;}
 else if(fn==='service_finalize'){
 if(!state.shift)fail('GRND-425','Shift is closed');if(task.state!=='in_progress')fail('GRND-410','Task is not in progress');
 const missing=task.evidence_required.filter(r=>r==='location'?!args.location:r==='material_qty'?!args.materials?.length:!args.photos?.some(p=>p.kind===r.replace('photo_','')));
 if(missing.length)fail('GRND-422','Complete the required evidence',missing);
 if(args.materials?.some(m=>!Number.isFinite(m.qty)||m.qty<0))fail('GRND-422','Quantity must be zero or greater');
 task.state='review';task.service_record={...args,service_record_id:crypto.randomUUID(),assessment:{result:'unavailable'},preview_only:true};
 }else if(fn==='task_approve'){if(task.state!=='review')fail('GRND-410','Task is not ready for review');task.state='done';}
 else fail('GRND-404','Unsupported preview command');
 task.task_revision++;data={task_id:task.task_id,revision:task.task_revision,state:task.state,assignment_id:task.assignment_id};
 }
 const result={ok:true,data,revision:data.revision,replayed:false};state.results[cacheKey]={fn,result};return result;
}
export async function drain(queue,state,save,notify){
 const blocked=new Set();
 for(const command of queue){const key=command.args.task_id||command.args.assignment_id||'shift';
 if(command.status==='done')continue;
 if(command.status==='attention'){blocked.add(key);continue;}
 if(blocked.has(key))continue;
 try{execute(state,command.fn,command.args,command.caller);command.status='done';}
 catch(e){command.status='attention';command.error=e.message;command.code=e.code;blocked.add(key);notify?.(e.message);}
 await save();
 }
 return queue.filter(c=>c.status!=='done');
}
