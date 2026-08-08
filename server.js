/* Воркер: статика + облачный кэш (KV) + прокси озвучки (TTS) + ИИ-гид (ask).
   Эндпоинты:
     /api/kv?code=X&list=1     → список ключей группы
     /api/kv?code=X&key=K GET  → значение
     /api/kv?code=X&key=K PUT  → сохранить (тело = JSON)
     /api/tts  POST {text,model,voice} → audio/mpeg  (ключ живёт в секрете OPENAI_API_KEY)
     /api/ask  POST {prompt,history?,model?,code?} → {text}  (Anthropic → OpenAI-фолбэк)
               кэш ответов в KV 7 дней (X-Cache: HIT|MISS), лимит/сутки на код группы,
               SSE если Accept: text/event-stream
   Секреты в дашборде: Settings → Variables and Secrets:
     ANTHROPIC_API_KEY (для гида), OPENAI_API_KEY (для озвучки и фолбэка гида)
   Переменные (необязательные): PROVIDER=anthropic|openai, ASK_DAILY_LIMIT (дефолт 200) */
const CORS={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Methods':'GET,PUT,POST,OPTIONS','Access-Control-Allow-Headers':'content-type,accept'};
const J=(o,s=200)=>new Response(JSON.stringify(o),{status:s,headers:{'content-type':'application/json',...CORS}});

/* ---------- ИИ-гид: провайдеры ---------- */
const ASK_SYS='Ты — дружелюбный гид по Стамбулу для небольшой группы туристов (приложение-путеводитель, поездка 1–9 августа 2026). Отвечай кратко и по делу, по-русски.';
// один повтор при 5xx, таймаут 30 с — по ТЗ приложения
async function fetchRetry(url,opts){
  for(let i=0;i<2;i++){
    const r=await fetch(url,{...opts,signal:AbortSignal.timeout(30000)});
    if(r.status<500||i===1)return r;
  }
}
async function askAnthropic(env,body,stream){
  const r=await fetchRetry('https://api.anthropic.com/v1/messages',{
    method:'POST',
    headers:{'content-type':'application/json','x-api-key':env.ANTHROPIC_API_KEY,'anthropic-version':'2023-06-01'},
    body:JSON.stringify({model:body.model||'claude-opus-5',max_tokens:4096,stream,
      system:ASK_SYS,
      messages:[...(body.history||[]).filter(m=>m&&m.role&&m.content),{role:'user',content:body.prompt}]})
  });
  if(!r.ok)throw new Error('Anthropic '+r.status+': '+(await r.text()).slice(0,200));
  if(stream)return{stream:r.body,parse:parseAnthropicSSE};
  const d=await r.json();
  if(d.stop_reason==='refusal')throw new Error('Anthropic refusal'); // проверяем ДО чтения content
  return{text:(d.content||[]).filter(b=>b.type==='text').map(b=>b.text).join('')};
}
async function askOpenRouter(env,body,stream){
  const r=await fetchRetry('https://openrouter.ai/api/v1/chat/completions',{
    method:'POST',
    headers:{'content-type':'application/json','authorization':'Bearer '+env.OPENROUTER_API_KEY,
      'HTTP-Referer':'https://stambul-26.pkvxmch86y.workers.dev','X-Title':'stambul-26'},
    body:JSON.stringify({model:b0(body.model)||env.OPENROUTER_MODEL||'openai/gpt-4o-mini',stream,
      messages:[{role:'system',content:ASK_SYS},...(body.history||[]).filter(m=>m&&m.role&&m.content),{role:'user',content:body.prompt}]})
  });
  if(!r.ok)throw new Error('OpenRouter '+r.status+': '+(await r.text()).slice(0,200));
  if(stream)return{stream:r.body,parse:parseOpenAISSE};
  const d=await r.json();
  return{text:d.choices?.[0]?.message?.content||''};
}
const b0=x=>x&&String(x).includes('/')?String(x):null; // модель для OpenRouter — только в формате vendor/model
async function askOpenAI(env,body,stream){
  const r=await fetchRetry('https://api.openai.com/v1/chat/completions',{
    method:'POST',
    headers:{'content-type':'application/json','authorization':'Bearer '+env.OPENAI_API_KEY},
    body:JSON.stringify({model:'gpt-4o-mini',stream,
      messages:[{role:'system',content:ASK_SYS},...(body.history||[]).filter(m=>m&&m.role&&m.content),{role:'user',content:body.prompt}]})
  });
  if(!r.ok)throw new Error('OpenAI '+r.status+': '+(await r.text()).slice(0,200));
  if(stream)return{stream:r.body,parse:parseOpenAISSE};
  const d=await r.json();
  return{text:d.choices?.[0]?.message?.content||''};
}
// извлечение текстовых дельт из провайдерских SSE
function parseAnthropicSSE(data){try{const e=JSON.parse(data);
  return e.type==='content_block_delta'&&e.delta?.type==='text_delta'?e.delta.text:'';}catch(_){return'';}}
function parseOpenAISSE(data){if(data==='[DONE]')return'';
  try{return JSON.parse(data).choices?.[0]?.delta?.content||'';}catch(_){return'';}}

async function handleAsk(req,env){
  if(req.method!=='POST')return J({error:'нужен POST {prompt}'},405);
  let b={};try{b=await req.json();}catch(e){}
  b.prompt=String(b.prompt||'').slice(0,8000);
  if(!b.prompt)return J({error:'пустой prompt'},400);
  const t0=Date.now(),wantSSE=(req.headers.get('accept')||'').includes('text/event-stream');

  // суточный лимит на код группы (счётчик в KV)
  const code=String(b.code||'anon').slice(0,32),limit=+(env.ASK_DAILY_LIMIT||200);
  let lim=null;
  if(env.SYNC){
    const day=new Date().toISOString().slice(0,10),lk='ask-limit|'+code+'|'+day;
    const n=+(await env.SYNC.get(lk))||0;
    if(n>=limit)return J({error:'дневной лимит вопросов гиду ('+limit+') исчерпан для группы — попробуйте завтра'},429);
    lim={lk,n};
  }

  // кэш ответа: sha256(prompt+model), 7 дней
  const model=b.model||'',hist=(b.history||[]).length;
  let ck=null;
  if(env.SYNC&&!hist){ // кэшируем только вопросы без истории — иначе ключ не однозначен
    const h=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(b.prompt+'|'+model));
    ck='ask-cache|'+[...new Uint8Array(h)].map(x=>x.toString(16).padStart(2,'0')).join('');
    const hit=await env.SYNC.get(ck);
    if(hit!==null){
      console.log(JSON.stringify({ep:'ask',cache:'HIT',code,ms:Date.now()-t0}));
      if(wantSSE)return new Response('data: '+JSON.stringify({text:hit})+'\n\ndata: [DONE]\n\n',
        {headers:{'content-type':'text/event-stream','x-cache':'HIT','x-secrets-source':'cloudflare-worker-secrets',...CORS}});
      return new Response(JSON.stringify({text:hit}),
        {headers:{'content-type':'application/json','x-cache':'HIT','x-secrets-source':'cloudflare-worker-secrets',...CORS}});
    }
  }

  // выбор провайдера: PROVIDER, иначе — у кого есть ключ; фолбэк на второго при ошибке
  const all=['anthropic','openai','openrouter'];
  const order=all.includes(env.PROVIDER)?[env.PROVIDER,...all.filter(p=>p!==env.PROVIDER)]:all;
  const call={anthropic:askAnthropic,openai:askOpenAI,openrouter:askOpenRouter};
  const keys={anthropic:env.ANTHROPIC_API_KEY,openai:env.OPENAI_API_KEY,openrouter:env.OPENROUTER_API_KEY};
  const avail=order.filter(p=>keys[p]);
  if(!avail.length)return J({error:'нет ни одного ключа: ANTHROPIC_API_KEY / OPENAI_API_KEY / OPENROUTER_API_KEY'},500);

  let res=null,used=null,errs=[];
  for(const p of avail){
    try{res=await call[p](env,b,wantSSE);used=p;break;}
    catch(e){errs.push(p+': '+String(e.message).slice(0,120));}
  }
  if(!res)return J({error:'провайдеры недоступны',details:errs},502);

  const done=async(text)=>{ // пост-обработка: лимит + кэш (без содержимого в логах)
    if(lim)await env.SYNC.put(lim.lk,String(lim.n+1),{expirationTtl:172800});
    if(ck&&text)await env.SYNC.put(ck,text,{expirationTtl:604800});
    console.log(JSON.stringify({ep:'ask',provider:used,cache:'MISS',sse:wantSSE,code,len:(text||'').length,ms:Date.now()-t0}));
  };

  if(!wantSSE){await done(res.text);
    return new Response(JSON.stringify({text:res.text}),
      {headers:{'content-type':'application/json','x-cache':'MISS','x-provider':used,'x-secrets-source':'cloudflare-worker-secrets',...CORS}});}

  // SSE: транслируем дельты провайдера как data:{text}, копим полный текст для кэша
  let acc='',buf='';
  const ts=new TransformStream({
    transform(chunk,ctrl){
      buf+=new TextDecoder().decode(chunk);
      const lines=buf.split('\n');buf=lines.pop();
      for(const l of lines){
        if(!l.startsWith('data:'))continue;
        const d=res.parse(l.slice(5).trim());
        if(d){acc+=d;ctrl.enqueue(new TextEncoder().encode('data: '+JSON.stringify({text:d})+'\n\n'));}
      }
    },
    async flush(ctrl){await done(acc);ctrl.enqueue(new TextEncoder().encode('data: [DONE]\n\n'));}
  });
  res.stream.pipeTo(ts.writable).catch(()=>{});
  return new Response(ts.readable,{headers:{'content-type':'text/event-stream','x-cache':'MISS','x-provider':used,'x-secrets-source':'cloudflare-worker-secrets',...CORS}});
}

export default{
  async fetch(req,env){
    const url=new URL(req.url);
    if(req.method==='OPTIONS')return new Response(null,{headers:CORS});

    /* ---------- статус секретов/фич (для людей и фронта) ---------- */
    if(url.pathname==='/api/status'){
      const y=x=>x?'✅ секрет Cloudflare':'—';
      const rows=[
        ['ИИ-гид · Anthropic (claude-opus-5)',y(env.ANTHROPIC_API_KEY)],
        ['ИИ-гид · OpenAI (gpt-4o-mini)',y(env.OPENAI_API_KEY)],
        ['ИИ-гид · OpenRouter',y(env.OPENROUTER_API_KEY)],
        ['Озвучка · OpenAI TTS',y(env.OPENAI_API_KEY)],
        ['Озвучка · ElevenLabs',y(env.ELEVENLABS_API_KEY)],
        ['Уведомления · Telegram',y(env.TG_BOT_TOKEN)],
        ['Облачный кэш · KV SYNC',env.SYNC?'✅ binding':'—'],
      ].map(([f,s])=>'<tr><td>'+f+'</td><td>'+s+'</td></tr>').join('');
      return new Response('<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>stambul-26 · статус</title><style>body{font:16px/1.5 -apple-system,sans-serif;max-width:560px;margin:24px auto;padding:0 12px}td{padding:6px 10px;border-bottom:1px solid #ddd}h1{font-size:20px}</style><h1>🔐 Секреты и фичи</h1><p>Все ключи хранятся как <b>секреты Cloudflare-воркера</b> (в код и репозиторий не попадают).</p><table>'+rows+'</table>',
        {headers:{'content-type':'text/html; charset=utf-8',...CORS}});
    }

    /* ---------- ИИ-гид ---------- */
    if(url.pathname==='/api/ask')return handleAsk(req,env);

    /* ---------- озвучка (AI-voice, опционально и конфигурируемо) ----------
       Переменные (Settings → Variables, все необязательные):
         TTS_ENABLED   on|off (дефолт on) — off → 501, фронт покажет «озвучка выключена»
         TTS_PROVIDER  openai|elevenlabs (дефолт: auto — у кого есть ключ)
         TTS_MODEL     дефолт-модель (openai: gpt-4o-mini-tts; elevenlabs: eleven_multilingual_v2)
         TTS_VOICE     дефолт-голос (openai: alloy; elevenlabs: voice-id)
       Ключи: OPENAI_API_KEY и/или ELEVENLABS_API_KEY.
       Запрос: POST {text, provider?, model?, voice?} → audio/mpeg
       GET /api/tts/config → {enabled, providers, default} — для настроек в приложении */
    if(url.pathname==='/api/tts/config'){
      const provs=[];
      if(env.OPENAI_API_KEY)provs.push('openai');
      if(env.ELEVENLABS_API_KEY)provs.push('elevenlabs');
      const on=!/^(0|off|false)$/i.test(env.TTS_ENABLED||'')&&provs.length>0;
      const askProvs=['anthropic','openai','openrouter'].filter(p=>({anthropic:env.ANTHROPIC_API_KEY,openai:env.OPENAI_API_KEY,openrouter:env.OPENROUTER_API_KEY})[p]);
      return J({enabled:on,providers:provs,ask_providers:askProvs,secrets_source:'cloudflare-worker-secrets', // openrouter: текстовые фичи, TTS не поддерживает
        default:{provider:env.TTS_PROVIDER||provs[0]||null,model:env.TTS_MODEL||null,voice:env.TTS_VOICE||null}});
    }
    if(url.pathname==='/api/tts'){
      if(req.method!=='POST')return J({error:'нужен POST {text}'},405);
      if(/^(0|off|false)$/i.test(env.TTS_ENABLED||''))return J({error:'озвучка выключена на сервере (TTS_ENABLED=off)'},501);
      let b={};try{b=await req.json();}catch(e){}
      const text=String(b.text||'').slice(0,4000);
      if(!text)return J({error:'пустой текст'},400);
      // выбор провайдера: тело → TTS_PROVIDER → у кого есть ключ
      let prov=b.provider||env.TTS_PROVIDER||(env.OPENAI_API_KEY?'openai':env.ELEVENLABS_API_KEY?'elevenlabs':'');
      if(prov==='openai'&&!env.OPENAI_API_KEY)prov=env.ELEVENLABS_API_KEY?'elevenlabs':'';
      if(prov==='elevenlabs'&&!env.ELEVENLABS_API_KEY)prov=env.OPENAI_API_KEY?'openai':'';
      if(!prov)return J({error:'озвучка не настроена: задайте OPENAI_API_KEY или ELEVENLABS_API_KEY'},501);
      let r;
      if(prov==='elevenlabs'){
        const voice=b.voice||env.TTS_VOICE||'21m00Tcm4TlvDq8ikWAM';
        r=await fetch('https://api.elevenlabs.io/v1/text-to-speech/'+encodeURIComponent(voice),{
          method:'POST',
          headers:{'content-type':'application/json','xi-api-key':env.ELEVENLABS_API_KEY},
          body:JSON.stringify({text,model_id:b.model||env.TTS_MODEL||'eleven_multilingual_v2'})
        });
      }else{
        r=await fetch('https://api.openai.com/v1/audio/speech',{
          method:'POST',
          headers:{'content-type':'application/json','authorization':'Bearer '+env.OPENAI_API_KEY},
          body:JSON.stringify({model:b.model||env.TTS_MODEL||'gpt-4o-mini-tts',voice:b.voice||env.TTS_VOICE||'alloy',
            input:text,response_format:'mp3'})
        });
      }
      if(!r.ok)return J({error:prov+' '+r.status+': '+(await r.text()).slice(0,200)},502);
      console.log(JSON.stringify({ep:'tts',provider:prov,len:text.length}));
      return new Response(r.body,{headers:{'content-type':'audio/mpeg',
        'cache-control':'public, max-age=86400','x-tts-provider':prov,'x-secrets-source':'cloudflare-worker-secrets',...CORS}});
    }

    /* ---------- облачный кэш ---------- */
    if(url.pathname==='/api/kv'){
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
