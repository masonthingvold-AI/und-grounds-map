import {supabaseConfig} from './public-config.mjs';
export function apiError(error,status){
 let details={};try{details=JSON.parse(error?.details||'{}');}catch{}
 const code=error?.message?.match(/^GRND-\d{3}/)?.[0]||String(status||error?.status||error?.code||'NETWORK');
 return Object.assign(new Error((error?.message||'Connection unavailable').replace(/^GRND-\d{3}:\s*/,'')),{code,details,retryable:code==='GRND-500'||code==='NETWORK'||Number(code)>=500});
}
export const client=globalThis.supabase.createClient(supabaseConfig.url,supabaseConfig.anonKey,{auth:{persistSession:typeof window!=='undefined',autoRefreshToken:typeof window!=='undefined',detectSessionInUrl:false}});
export async function readView(name,filters={},order){
 let q=client.from(name).select('*');for(const [key,value]of Object.entries(filters))q=q.eq(key,value);if(order)q=q.order(order,{ascending:true});
 const {data,error,status}=await q;if(error)throw apiError(error,status);return data;
}
export async function rpc(fn,args){const {data,error,status}=await client.rpc(fn,args);if(error)throw apiError(error,status);return data;}
export async function login(email,password){const {error}=await client.auth.signInWithPassword({email,password});if(error)throw apiError(error);const [me]=await readView('v_me');if(!me?.active){await client.auth.signOut({scope:'local'});throw Error('Your profile is not active.');}return me;}
export const signOut=()=>client.auth.signOut({scope:'local'});
