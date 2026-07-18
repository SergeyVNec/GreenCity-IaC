"""Hermes agent — bridges an open-weights Hermes model (via OpenRouter) to the
greencity-ops MCP server. It turns MCP tools into OpenAI function schemas, runs
the tool-call loop, and serves a small voice-capable web UI.

    Browser (mic/text) -> /chat -> Hermes (OpenRouter) <-> MCP tools -> cluster
"""
import os
import io
import wave
import json
import requests
from fastapi import FastAPI, UploadFile, File
from fastapi.responses import HTMLResponse, Response
from pydantic import BaseModel

# --- Speech-to-text via Groq Whisper (much better than the browser Web Speech API) ---
GROQ_KEY = os.environ.get("GROQ_API_KEY", "")
GROQ_STT = os.environ.get("GROQ_STT_URL", "https://api.groq.com/openai/v1/audio/transcriptions")
STT_MODEL = os.environ.get("STT_MODEL", "whisper-large-v3-turbo")
# Bias Whisper toward our domain vocabulary → far fewer mis-hears of tech terms.
STT_PROMPT = ("GreenCity, backcore, backuser, frontend, rabbitmq, namespace greencity, "
              "Prometheus, Grafana, Splunk, SonarQube, CodeBuild, Falco, Kubernetes, "
              "реплики, поды, деплой, Quality Gate, отмасштабируй, перезапусти")

# --- Text-to-speech via ElevenLabs (natural Russian voice) ---
ELEVEN_KEY = os.environ.get("ELEVENLABS_API_KEY", "")
ELEVEN_VOICE = os.environ.get("ELEVENLABS_VOICE_ID", "EXAVITQu4vr4xnSDxMaL")  # Sarah (free-tier usable)
ELEVEN_MODEL = os.environ.get("ELEVENLABS_MODEL", "eleven_turbo_v2_5")  # low latency, multilingual

_DEC = json.JSONDecoder()


def extract_tool_calls(text: str) -> list:
    """Pull tool calls out of the model reply. Tolerant of a missing </tool_call>,
    trailing braces, or bare JSON — grabs the first valid JSON object after each marker."""
    calls, idx = [], 0
    while True:
        m = text.find("<tool_call>", idx)
        if m == -1:
            break
        rest = text[m + len("<tool_call>"):]
        stripped = rest.lstrip()
        try:
            obj, end = _DEC.raw_decode(stripped)
            if isinstance(obj, dict) and "name" in obj:
                calls.append(obj)
            idx = m + len("<tool_call>") + (len(rest) - len(stripped)) + end
        except Exception:
            idx = m + len("<tool_call>")
    return calls

# LLM endpoint is pluggable: default OpenRouter, but LLM_URL/LLM_API_KEY can point
# it at any OpenAI-compatible API (e.g. Groq for much lower latency). Revert by
# unsetting LLM_URL/LLM_API_KEY and setting HERMES_MODEL back to the OpenRouter id.
OPENROUTER = os.environ.get("OPENROUTER_URL", "https://openrouter.ai/api/v1/chat/completions")
LLM_URL = os.environ.get("LLM_URL", OPENROUTER)
API_KEY = os.environ.get("LLM_API_KEY", "") or os.environ.get("OPENROUTER_API_KEY", "")
MODEL = os.environ.get("HERMES_MODEL", "nousresearch/hermes-3-llama-3.1-70b")
MCP_URL = os.environ.get("MCP_URL", "http://mcp-server.observability.svc.cluster.local:8000/mcp")
MCP_TOKEN = os.environ.get("MCP_BEARER_TOKEN", "")

SYSTEM_TMPL = (
    "You are the GreenCity Ops assistant. You operate a k3s cluster and its CI/CD. "
    "You can call tools. The available tools are given as JSON inside <tools></tools>:\n"
    "<tools>\n{tools}\n</tools>\n"
    "To call a tool, reply with ONLY this and nothing else:\n"
    '<tool_call>{{"name": "<tool_name>", "arguments": <json-args>}}</tool_call>\n'
    "You will then receive the result inside <tool_response></tool_response>. "
    "Use it to answer. Always call a tool to get real data instead of guessing. "
    "NEVER ask the user to clarify — act with sensible defaults: assume namespace "
    "'greencity'; if a project key is needed and none is given, use 'greencity-backcore'. "
    "Reply in plain Russian. {fmt_rule} "
    "For destructive actions (restart_pod, scale_deployment, rollout_restart, trigger_build) "
    "briefly say what you are doing, then issue the tool call."
)

app = FastAPI()
_mcp_headers = {
    "Authorization": f"Bearer {MCP_TOKEN}",
    "Accept": "application/json, text/event-stream",
    "Content-Type": "application/json",
}


def _parse_sse(text: str) -> dict:
    """Pull the JSON out of an SSE `data:` line."""
    for line in text.splitlines():
        if line.startswith("data:"):
            return json.loads(line[5:].strip())
    return json.loads(text)  # fall back to plain JSON


def mcp_rpc(method: str, params: dict | None = None) -> dict:
    body = {"jsonrpc": "2.0", "id": 1, "method": method}
    if params is not None:
        body["params"] = params
    r = requests.post(MCP_URL, headers=_mcp_headers, json=body, timeout=60)
    return _parse_sse(r.text)


_TOOLS_CACHE = None


def load_tools() -> list:
    """MCP tools/list -> compact JSON spec embedded in the system prompt (cached)."""
    global _TOOLS_CACHE
    if _TOOLS_CACHE is not None:
        return _TOOLS_CACHE
    res = mcp_rpc("tools/list").get("result", {})
    tools = []
    for t in res.get("tools", []):
        tools.append({
            "name": t["name"],
            "description": t.get("description", ""),
            "parameters": t.get("inputSchema", {"type": "object", "properties": {}}),
        })
    _TOOLS_CACHE = tools
    return tools


def call_tool(name: str, arguments: dict) -> str:
    res = mcp_rpc("tools/call", {"name": name, "arguments": arguments})
    if "error" in res:
        return f"tool error: {res['error']}"
    content = res.get("result", {}).get("content", [])
    return "\n".join(c.get("text", "") for c in content) or json.dumps(res.get("result", {}))


def hermes(messages: list) -> str:
    """Plain chat completion (no OpenAI tools param — Hermes tool-calling is prompt-based).
    Free models are rate-limited upstream, so retry on 429 honoring Retry-After."""
    import time
    last = ""
    for attempt in range(4):
        r = requests.post(
            LLM_URL,
            headers={"Authorization": f"Bearer {API_KEY}", "Content-Type": "application/json"},
            json={"model": MODEL, "messages": messages, "temperature": 0.2},
            timeout=120,
        )
        if r.status_code == 429:
            wait = 6
            try:
                wait = int(float(r.json()["error"]["metadata"].get("retry_after_seconds", 6))) + 2
            except Exception:
                pass
            last = f"OpenRouter HTTP 429 (rate limited); waited {min(wait, 25)}s"
            time.sleep(min(wait, 25))
            continue
        if r.status_code != 200:
            raise RuntimeError(f"OpenRouter HTTP {r.status_code}: {r.text[:600]}")
        data = r.json()
        if "choices" not in data:
            raise RuntimeError(f"OpenRouter response: {json.dumps(data)[:600]}")
        return data["choices"][0]["message"].get("content", "") or ""
    raise RuntimeError(f"{last} — free model still rate-limited after retries; retry shortly or add OpenRouter credits")


class Chat(BaseModel):
    message: str


@app.post("/chat")
def chat(req: Chat):
    if not API_KEY:
        return {"reply": "OPENROUTER_API_KEY is not set — put it in the openrouter-secret."}
    try:
        tools = load_tools()
        # Deterministically pick answer length from the request wording, so the
        # model gets one unambiguous instruction instead of a conditional it ignores.
        detail_words = ("подробно", "детальн", "полн", "по каждому", "перечисли",
                        "список", "статистик", "все поды", "каждый под")
        if any(w in req.message.lower() for w in detail_words):
            fmt_rule = ("Ответь НУМЕРОВАННЫМ СПИСКОМ: перечисли КАЖДЫЙ элемент из результата "
                        "инструмента со всеми полями (для пода: имя, статус, готовность, "
                        "перезапуски, узел). Не сокращай.")
        else:
            fmt_rule = ("Ответь ОДНИМ коротким предложением-сводкой (число и общее состояние), "
                        "БЕЗ перечисления имён и полей.")
        system = SYSTEM_TMPL.format(tools=json.dumps(tools, ensure_ascii=False), fmt_rule=fmt_rule)
        messages = [{"role": "system", "content": system}, {"role": "user", "content": req.message}]
        trace = []
        for _ in range(6):
            reply = hermes(messages)
            found = extract_tool_calls(reply)
            if not found:
                return {"reply": reply.strip(), "tools_used": trace}
            messages.append({"role": "assistant", "content": reply})
            responses = []
            for call in found:
                fn, args = call["name"], call.get("arguments", {})
                trace.append({"tool": fn, "args": args})
                out = call_tool(fn, args)
                responses.append(f"<tool_response>\n{out[:6000]}\n</tool_response>")
            # Repeat the format directive right next to the data — models follow the
            # most recent instruction far more reliably than one in the system prompt.
            messages.append({"role": "user",
                             "content": "\n".join(responses) + "\n\nФормат ответа: " + fmt_rule})
        return {"reply": "(остановлено после 6 итераций инструментов)", "tools_used": trace}
    except Exception as e:
        return {"reply": f"⚠️ {e}"}


@app.get("/healthz")
def healthz():
    return {"ok": True, "model": MODEL, "llm_key": bool(API_KEY),
            "stt_key": bool(GROQ_KEY), "tts_key": bool(ELEVEN_KEY)}


@app.post("/stt")
async def stt(audio: UploadFile = File(...)):
    """Speech-to-text via Groq Whisper — far more accurate than the browser API."""
    if not GROQ_KEY:
        return {"text": "", "error": "GROQ_API_KEY not set"}
    data = await audio.read()
    # Forward the real filename/type so Groq detects the format (webm from the
    # browser, wav from the native Windows agent).
    fname = audio.filename or "audio.webm"
    ctype = audio.content_type or "audio/webm"
    try:
        # NB: a long English prompt corrupts Russian transcription — keep it minimal.
        r = requests.post(
            GROQ_STT,
            headers={"Authorization": f"Bearer {GROQ_KEY}"},
            files={"file": (fname, data, ctype)},
            data={"model": STT_MODEL, "language": "ru",
                  "response_format": "json", "temperature": "0"},
            timeout=60,
        )
        if r.status_code != 200:
            return {"text": "", "error": f"Groq {r.status_code}: {r.text[:300]}"}
        return {"text": r.json().get("text", "").strip()}
    except Exception as e:
        return {"text": "", "error": str(e)}


class Speak(BaseModel):
    text: str


@app.post("/tts")
def tts(req: Speak, fmt: str = "mp3"):
    """Text-to-speech via ElevenLabs multilingual. fmt=mp3 (browser) or wav
    (native Windows client — plays via stdlib winsound, no extra deps)."""
    if not ELEVEN_KEY:
        return Response(status_code=204)
    url = f"https://api.elevenlabs.io/v1/text-to-speech/{ELEVEN_VOICE}"
    if fmt == "wav":
        url += "?output_format=pcm_16000"
    r = requests.post(
        url,
        headers={"xi-api-key": ELEVEN_KEY, "Content-Type": "application/json"},
        json={"text": req.text[:2000], "model_id": ELEVEN_MODEL,
              "voice_settings": {"stability": 0.5, "similarity_boost": 0.8}},
        timeout=60,
    )
    if r.status_code != 200:
        return Response(content=r.text[:300], status_code=r.status_code)
    if fmt == "wav":
        buf = io.BytesIO()
        w = wave.open(buf, "wb")
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(r.content)  # raw PCM16 mono 16k from ElevenLabs
        w.close()
        return Response(content=buf.getvalue(), media_type="audio/wav")
    return Response(content=r.content, media_type="audio/mpeg")


@app.get("/", response_class=HTMLResponse)
def index():
    return PAGE


PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>GreenCity Ops — Hermes</title>
<style>
 body{font-family:system-ui;max-width:760px;margin:24px auto;padding:0 16px;background:#0f1720;color:#e5e7eb}
 h1{font-size:20px} #log{border:1px solid #334;border-radius:8px;padding:12px;height:52vh;overflow:auto;background:#0b1017}
 .u{color:#7dd3fc}.a{color:#a7f3d0;white-space:pre-wrap}.t{color:#fbbf24;font-size:12px}
 #row{display:flex;gap:8px;margin-top:10px}
 input{flex:1;padding:10px;border-radius:8px;border:1px solid #334;background:#0b1017;color:#e5e7eb}
 button{padding:10px 14px;border:0;border-radius:8px;background:#2563eb;color:#fff;cursor:pointer}
 #mic.rec{background:#dc2626;animation:p 1s infinite}@keyframes p{50%{opacity:.5}}
</style></head><body>
<h1>🌿 GreenCity Ops — ChatOps (Whisper · gpt-4o-mini · ElevenLabs)</h1>
<div id="log"></div>
<div id="row">
 <input id="msg" placeholder="напр.: покажи статус подов greencity" autofocus>
 <button id="mic" title="Записать голос">🎤</button>
 <button id="send">➤</button>
</div>
<script>
const log=document.getElementById('log'),msg=document.getElementById('msg'),mic=document.getElementById('mic');
function add(cls,txt){const d=document.createElement('div');d.className=cls;d.textContent=txt;log.appendChild(d);log.scrollTop=log.scrollHeight;return d;}
async function speak(t){try{const r=await fetch('/tts',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({text:t})});
  if(r.ok&&r.headers.get('content-type','').includes('audio')){const b=await r.blob();new Audio(URL.createObjectURL(b)).play();}}catch(e){}}
async function send(){const q=msg.value.trim();if(!q)return;add('u','🧑 '+q);msg.value='';
 const last=add('a','🤖 ⏳ ...');
 try{const r=await fetch('/chat',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({message:q})});
  const j=await r.json();last.textContent='🤖 '+j.reply;
  if(j.tools_used&&j.tools_used.length){add('t','🔧 '+j.tools_used.map(x=>x.tool).join(', '));}
  speak(j.reply);}catch(e){last.textContent='ошибка: '+e;}}
document.getElementById('send').onclick=send;
msg.addEventListener('keydown',e=>{if(e.key==='Enter')send();});
// voice input: record audio -> /stt (Groq Whisper) -> text -> send
let rec,chunks=[];
mic.onclick=async()=>{
 if(rec&&rec.state==='recording'){rec.stop();return;}
 try{const stream=await navigator.mediaDevices.getUserMedia({audio:true});
  rec=new MediaRecorder(stream);chunks=[];
  rec.ondataavailable=e=>chunks.push(e.data);
  rec.onstop=async()=>{mic.classList.remove('rec');stream.getTracks().forEach(t=>t.stop());
   const blob=new Blob(chunks,{type:'audio/webm'});const fd=new FormData();fd.append('audio',blob,'a.webm');
   const info=add('t','🎙️ распознаю...');
   try{const r=await fetch('/stt',{method:'POST',body:fd});const j=await r.json();info.remove();
    if(j.text){msg.value=j.text;send();}else{add('a','STT: '+(j.error||'пусто'));}}catch(e){info.textContent='STT ошибка: '+e;}};
  rec.start();mic.classList.add('rec');
 }catch(e){add('a','нет доступа к микрофону: '+e+' (нужен secure-context / флаг Chrome)');}
};
</script></body></html>"""
