export const backoff=attempt=>[5000,15000,60000][attempt-1]||300000;
export class CommandQueue{
 constructor({owner,load,save,send,currentOwner,changed=()=>{},completed=()=>{}}){Object.assign(this,{owner,load,save,send,currentOwner,changed,completed});this.items=[];this.running=null;this.stopped=false;}
 async init(){this.items=await this.load(this.owner,'commands',[]);return this;}
 async persist(){await this.save(this.owner,'commands',this.items);this.changed();}
 async add(fn,args,meta={}){
 const taskId=meta.taskId||args.task_id,previous=taskId?[...this.items].reverse().find(c=>c.taskId===taskId&&c.status!=='canceled'):null;
 const item={id:crypto.randomUUID(),fn,args:{...args,idempotency_key:crypto.randomUUID()},taskId,dependsOn:previous?.status!=='done'?previous?.id:undefined,created_at:new Date().toISOString(),attempts:0,status:'pending',nextAt:0};
 this.items.push(item);await this.persist();await this.flush();return item;
 }
 async flush(){if(this.running)return this.running;if(this.stopped)return;this.running=this.drain().finally(()=>this.running=null);return this.running;}
 async drain(){
 for(const item of this.items){
 if(this.stopped||this.currentOwner()!==this.owner)return;
 if(item.status!=='pending'||item.nextAt>Date.now())continue;
 const dependency=this.items.find(c=>c.id===item.dependsOn);
 if(dependency&&dependency.status!=='done')continue;
 if(item.fn==='shift_end'&&this.items.slice(0,this.items.indexOf(item)).some(c=>!['done','canceled'].includes(c.status)))continue;
 if(item.fn==='service_finalize'&&(item.args.photos||[]).some(p=>!p.path)){item.status='validation';item.error={message:'Photos must upload before completion.',details:{fields:['photos']}};await this.persist();continue;}
 if(!item.attempts&&dependency?.result?.revision!=null)item.args.expected_revision=dependency.result.revision;
 item.attempts++;this.inFlight=item.id;await this.persist();
 try{item.result=await this.send(item.fn,item.args);item.status='done';item.error=null;await this.persist();try{await this.completed(item);}catch(e){this.changed(e);}}
 catch(e){item.error={message:e.message,code:e.code,details:e.details};
 if(['401','GRND-401'].includes(e.code)){this.stopped=true;await this.persist();this.changed(e);return;}
 if(e.retryable){item.nextAt=Date.now()+backoff(item.attempts);}else item.status=e.code==='GRND-422'?'validation':'review';
 await this.persist();}finally{this.inFlight=null;}
 }
 }
 async fix(id,args){const item=this.items.find(c=>c.id===id);if(item?.status!=='validation')throw Error('Only a validation error can be corrected with the same key.');item.args={...args,idempotency_key:item.args.idempotency_key};item.status='pending';item.nextAt=0;await this.persist();return this.flush();}
 async cancel(id){const item=this.items.find(c=>c.id===id);if(!item)throw Error('This saved action is no longer available.');if(this.inFlight===id)throw Error('This action is being sent. Wait for the result before canceling.');if(item.status==='done')throw Error('A completed command cannot be canceled.');item.status='canceled';let changed=true;while(changed){changed=false;for(const child of this.items){if(child.status!=='done'&&child.status!=='canceled'&&this.items.find(p=>p.id===child.dependsOn)?.status==='canceled'){child.status='canceled';changed=true;}}}await this.persist();}
 async redo(id){const item=this.items.find(c=>c.id===id);if(!['review','canceled'].includes(item.status))throw Error('Review the action before retrying.');return item;}
 async stop(){this.stopped=true;await this.running;}
}
export class LocationQueue{
 constructor({owner,load,save,send,currentOwner,notify}){Object.assign(this,{owner,load,save,send,currentOwner,notify});this.running=null;}
 async init(){this.items=await this.load(this.owner,'locations',[]);return this;}
 async add(shift_id,samples){for(const sample of samples)this.items.push({shift_id,sample,key:crypto.randomUUID(),attempts:0,nextAt:0});if(this.items.length>2000){this.items=this.items.slice(-2000);this.notify('Older location samples dropped. The newest 2,000 are retained.');await this.save(this.owner,'location-note','Older samples dropped at '+new Date().toISOString());}await this.save(this.owner,'locations',this.items);await this.flush();}
 async flush(){if(this.running)return this.running;this.running=this.drain().finally(()=>this.running=null);return this.running;}
 async drain(){while(this.items.length&&this.currentOwner()===this.owner){const item=this.items[0];if(item.nextAt>Date.now())return;try{const result=await this.send('location_upload',{shift_id:item.shift_id,idempotency_key:item.key,samples:[item.sample]});if(result.data.rejected)this.notify('A location sample was rejected by the server.');this.items=this.items.filter(p=>p.key!==item.key);}catch(e){if(e.retryable){item.attempts++;item.nextAt=Date.now()+backoff(item.attempts);await this.save(this.owner,'locations',this.items);return;}if(['401','GRND-401'].includes(e.code))return;this.notify(e.message);this.items=this.items.filter(p=>p.key!==item.key);}await this.save(this.owner,'locations',this.items);}}
}
