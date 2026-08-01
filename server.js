/* Воркер: статика + облачный кэш в KV.
   /api/kv?code=X&list=1        → список ключей группы
   /api/kv?code=X&key=K  GET    → значение
   /api/kv?code=X&key=K  PUT    → сохранить (тело = JSON) */
const CORS={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Methods':'GET,PUT,OPTIONS','Access-Control-Allow-Headers':'content-type'};
const J=(o,s=200)=>new Response(JSON.stringify(o),{status:s,headers:{'content-type':'application/json',...CORS}});
export default{
  async fetch(req,env){
    const url=new URL(req.url);
    if(url.pathname==='/api/kv'){
      if(req.method==='OPTIONS')return new Response(null,{headers:CORS});
      if(!env.SYNC)return J({error:'KV не подключён: создайте namespace и раскомментируйте kv_namespaces в wrangler.jsonc'},501);
      const code=(url.searchParams.get('code')||'').trim();
      if(code.length<4)return J({error:'код минимум 4 символа'},400);
      if(url.searchParams.get('list')){
        const keys=[];let cursor;
        do{const l=await env.SYNC.list({prefix:code+'|',cursor});
           keys.push(...l.keys.map(k=>k.name.slice(code.length+1)));
           cursor=l.list_complete?null:l.cursor;}while(cursor);
        return J({keys});
      }
      const key=url.searchParams.get('key');
      if(!key)return J({error:'нет key'},400);
      if(req.method==='PUT'){
        const v=await req.text();
        if(v.length>23e6)return J({error:'объект больше 23 МБ — не влезает в KV'},413);
        await env.SYNC.put(code+'|'+key,v);
        return J({ok:1});
      }
      const v=await env.SYNC.get(code+'|'+key);
      return v===null?J({error:'нет такого ключа'},404)
        :new Response(v,{headers:{'content-type':'application/json',...CORS}});
    }
    return env.ASSETS.fetch(req);
  }
};
