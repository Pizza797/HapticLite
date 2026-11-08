<#
HapticLite installer. Run once from a NORMAL (non-admin) PowerShell window:

  powershell -ExecutionPolicy Bypass -File .\install.ps1

To remove the autostart task and desktop files (your HapticLite folder is kept):

  powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
#>
param([switch]$Uninstall)
$ErrorActionPreference = "Stop"

# ---- refuse to run as Administrator (the app must run with normal rights) ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    Write-Host "This window is running as Administrator. Close it, open a normal PowerShell window (Start menu > PowerShell > Enter), and run the script again." -ForegroundColor Red
    exit 1
}

$dir      = "$env:USERPROFILE\HapticLite"
$lnk      = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\HapticLite.lnk"
$desktop  = [Environment]::GetFolderPath("Desktop")
$taskName = "HapticLite"

function Stop-App {
    $ErrorActionPreference = "SilentlyContinue"
    schtasks /End /TN $taskName 2>$null | Out-Null
    Get-Process pythonw -ErrorAction SilentlyContinue | ForEach-Object {
        try { Stop-Process -Id $_.Id -Force -ErrorAction Stop }
        catch { Write-Host "Could not stop pythonw (PID $($_.Id)): $($_.Exception.Message)" -ForegroundColor Yellow }
    }
}

function Find-Python {
    $c = "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe"
    if (Test-Path $c) { return $c }
    try {
        $p = (& py -3.12 -c "import sys; print(sys.executable)" 2>$null)
        if ($p -and (Test-Path $p)) { return $p }
    } catch {}
    return $null
}

# ---- uninstall ----
if ($Uninstall) {
    Stop-App
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $lnk, "$desktop\restart.bat", "$desktop\HapticLite Settings.url" -ErrorAction SilentlyContinue
    Write-Host "Stopped the app and removed the task, startup shortcut and desktop files. Your files are kept in $dir"
    exit 0
}

# ---- 1. Python ----
Write-Host "[1/7] Checking Python 3.12..."
$py = Find-Python
if (-not $py) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget was not found. Install Python 3.12 from python.org (choose 'Install for me only'), then run this script again."
    }
    winget install -e --id Python.Python.3.12 --scope user --accept-package-agreements --accept-source-agreements
    $py = Find-Python
    if (-not $py) { throw "Python 3.12 was not found after the install. Close PowerShell, open a new one and run this script again." }
}
$pyw = Join-Path (Split-Path $py) "pythonw.exe"
Write-Host "      Using $py"

# ---- 2. stop any running copy ----
Write-Host "[2/7] Stopping any running copy..."
Stop-App

# ---- 3. app files ----
Write-Host "[3/7] Writing app files to $dir ..."
New-Item -ItemType Directory -Force $dir | Out-Null
if (Test-Path "$dir\app.py") { Copy-Item "$dir\app.py" "$dir\app.py.bak" -Force }

$app = @'
import json, os, time, ctypes, threading, queue, requests, winreg
from ctypes import wintypes
from pathlib import Path
from flask import Flask, request, jsonify, Response
from pynput import mouse
try:
    import websocket
except Exception:
    websocket = None

BASE = "https://local.jmw.nz:41443"
WS_URL = "wss://local.jmw.nz:41443/ws"
CFG = Path(__file__).with_name("settings.json")
FALLBACK = ["sharp_collision", "sharp_state_change", "knock", "damp_collision"]
DEFAULT_PROFILE = {
    "enabled": True, "delay": 0, "strength": 1,
    "left": "sharp_state_change", "right": "damp_collision", "middle": "sharp_collision",
    "x1": "sharp_collision", "x2": "sharp_collision",
    "hold_on": False, "hold_ms": 0, "hold_wf": "sharp_collision",
    "pulse": False, "pulse_ms": 200, "pulse_wf": "knock",
    "scroll_on": False, "scroll_wf": "damp_collision", "scroll_density": 2,
    "thumb_on": False, "thumb_wf": "damp_collision", "thumb_density": 2,
    "ptr_on": False, "ptr_speed": 10,
}
LIMITS = {"delay": (0, 500), "hold_ms": (0, 2000), "pulse_ms": (30, 1000),
          "strength": (1, 3), "scroll_density": (0, 4), "thumb_density": (0, 4), "ptr_speed": (1, 20)}
BUTTONS = ("left", "right", "middle", "x1", "x2")

def load():
    try:
        data = json.loads(CFG.read_text())
    except Exception:
        data = {}
    if "default" not in data:
        data = {"default": data, "apps": {}}
    def fix(v):
        v = dict(v)
        if "hold_on" not in v:
            v["hold_on"] = v.get("hold_ms", 0) > 0
        return {**DEFAULT_PROFILE, **v}
    out = {"default": fix(data["default"]), "apps": {}}
    for k, v in data.get("apps", {}).items():
        out["apps"][k] = fix(v)
    return out

cfg = load()

def save_cfg():
    CFG.write_text(json.dumps(cfg))

# ---- foreground app detection ----
u32, k32 = ctypes.windll.user32, ctypes.windll.kernel32
u32.GetForegroundWindow.restype = wintypes.HWND
u32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
k32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
k32.OpenProcess.restype = wintypes.HANDLE
k32.CloseHandle.argtypes = [wintypes.HANDLE]
k32.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD,
                                           wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]

def fg_exe():
    try:
        h = u32.GetForegroundWindow()
        pid = wintypes.DWORD()
        u32.GetWindowThreadProcessId(h, ctypes.byref(pid))
        ph = k32.OpenProcess(0x1000, False, pid.value)
        if not ph:
            return ""
        buf = ctypes.create_unicode_buffer(520)
        n = wintypes.DWORD(520)
        ok = k32.QueryFullProcessImageNameW(ph, 0, buf, ctypes.byref(n))
        k32.CloseHandle(ph)
        return os.path.basename(buf.value).lower() if ok else ""
    except Exception:
        return ""

# ---- plugin connection ----
S = requests.Session()
state = {"wf": FALLBACK, "online": False, "active": "", "seen": set(), "idx": {}}

def warm():
    while True:
        try:
            d = S.get(f"{BASE}/waveforms", timeout=3).json()
            d = d.get("waveforms", d) if isinstance(d, dict) else d
            names = [w["name"] if isinstance(w, dict) else w for w in d]
            state["wf"] = names
            if names[:4] == ["sharp_collision", "sharp_state_change", "knock", "damp_collision"]:
                state["idx"] = {n: i for i, n in enumerate(names)}
            else:
                state["idx"] = {}
            state["online"] = True
            time.sleep(15)
        except Exception:
            state["online"] = False
            time.sleep(3)

SPI_GET, SPI_SET = 0x0070, 0x0071
u32.SystemParametersInfoW.argtypes = [wintypes.UINT, wintypes.UINT, ctypes.c_void_p, wintypes.UINT]

def _saved_speed():
    try:
        k = winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Control Panel\Mouse")
        return int(winreg.QueryValueEx(k, "MouseSensitivity")[0])
    except Exception:
        c = ctypes.c_int(10)
        u32.SystemParametersInfoW(SPI_GET, 0, ctypes.byref(c), 0)
        return c.value

orig_speed = _saved_speed()
applied = [None]

def apply_speed(exe):
    try:
        p = cfg["apps"].get(exe, cfg["default"])
        want = p["ptr_speed"] if p["ptr_on"] else orig_speed
        if want != applied[0]:
            u32.SystemParametersInfoW(SPI_SET, 0, want, 0)
            applied[0] = want
    except Exception:
        pass

def watch():
    while True:
        e = fg_exe()
        state["active"] = e
        if e:
            state["seen"].add(e)
        apply_speed(e)
        time.sleep(0.5)

threading.Thread(target=warm, daemon=True).start()
threading.Thread(target=watch, daemon=True).start()

ws_conn = [None]
ws_lock = threading.Lock()
ws_down_until = [0.0]

def send_wf(name):
    # Fast path: persistent WebSocket (one byte = waveform index). Falls back to REST.
    i = state["idx"].get(name)
    if websocket is not None and i is not None and time.monotonic() >= ws_down_until[0]:
        with ws_lock:
            for _ in range(2):
                try:
                    if ws_conn[0] is None:
                        ws_conn[0] = websocket.create_connection(WS_URL, timeout=2)
                    ws_conn[0].send_binary(bytes([i]))
                    return
                except Exception:
                    try:
                        if ws_conn[0] is not None:
                            ws_conn[0].close()
                    except Exception:
                        pass
                    ws_conn[0] = None
            ws_down_until[0] = time.monotonic() + 30
    try:
        S.post(f"{BASE}/haptic/{name}", data="", timeout=2)
    except Exception:
        pass

def buzz(name, delay=0, reps=1):
    try:
        if delay:
            time.sleep(delay / 1000)
        for i in range(max(1, reps)):
            if i:
                time.sleep(0.04)
            send_wf(name)
    except Exception:
        pass

# ---- mouse handling ----
holds = {}

def hold_worker(ev, p):
    gap = max(0.03, p["pulse_ms"] / 1000)
    while not ev.wait(gap):
        buzz(p["hold_wf"])

def on_click(x, y, button, pressed):
    name = button.name
    if name not in BUTTONS:
        return
    if pressed:
        p = cfg["apps"].get(fg_exe(), cfg["default"])
        if not p["enabled"]:
            return
        threading.Thread(target=buzz, args=(p[name], p["delay"], p["strength"]), daemon=True).start()
        if p["hold_on"]:
            old = holds.get(name)
            if old:
                old.set()
            ev = threading.Event()
            holds[name] = ev
            threading.Thread(target=hold_worker, args=(ev, p), daemon=True).start()
    else:
        ev = holds.pop(name, None)
        if ev:
            ev.set()

# ---- scroll wheels: one pulse per notch, with density ----
# Raw wheel units: 120 = one notch. Density picks how many units per pulse.
STEPS = [360, 240, 120, 60, 30]   # Sparse, Light, Standard, Fine, Dense
acc = {"v": 0, "h": 0}
dirs = {"v": 0, "h": 0}
last_ev = {"v": 0.0, "h": 0.0}
last_pulse = {"v": 0.0, "h": 0.0}
pulse_q = queue.Queue()

def pulse_worker():
    while True:
        name = pulse_q.get()
        while pulse_q.qsize() > 2:   # drop stale backlog so feedback never lags the wheel
            try:
                pulse_q.get_nowait()
            except Exception:
                break
        send_wf(name)

threading.Thread(target=pulse_worker, daemon=True).start()

def wheel(kind, delta):
    # kind "v" = main wheel, "h" = side (thumb) wheel. delta is the raw signed wheel value.
    if delta == 0:
        return
    p = cfg["apps"].get(state["active"], cfg["default"])
    if not p["enabled"]:
        return
    if kind == "v":
        on, wf, dens = p["scroll_on"], p["scroll_wf"], p["scroll_density"]
    else:
        on, wf, dens = p["thumb_on"], p["thumb_wf"], p["thumb_density"]
    if not on:
        return
    now = time.monotonic()
    step = STEPS[max(0, min(4, int(dens)))]
    sg = 1 if delta > 0 else -1
    a = acc[kind]
    if now - last_ev[kind] > 0.4 or dirs[kind] != sg:
        a = (step - 120) * sg if step > 120 else 0   # new gesture or reversal: first notch pulses at once
    dirs[kind] = sg
    last_ev[kind] = now
    a += delta
    if abs(a) >= step:
        r = abs(a) % step
        a = r if a > 0 else -r
        if now - last_pulse[kind] >= 0.025:
            last_pulse[kind] = now
            pulse_q.put(wf)
    acc[kind] = a

def win_filter(msg, data):
    # Read the raw wheel value ourselves. pynput's own on_scroll rounds it to whole notches,
    # which breaks smooth wheels (and rounds the two directions differently).
    if msg == 0x020A or msg == 0x020E:
        try:
            wheel("v" if msg == 0x020A else "h", wintypes.SHORT(data.mouseData >> 16).value)
        except Exception:
            pass
        return False
    return True

mouse.Listener(on_click=on_click, win32_event_filter=win_filter).start()

# ---- web UI ----
app = Flask(__name__)

PAGE = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>HapticLite</title>
<style>
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:20px 0;
font-family:Segoe UI,system-ui,sans-serif;color:#e8eaf6;
background:radial-gradient(circle at 20% 10%,#2a2f6b,#0d0f1f 60%)}
.card{width:min(520px,94vw);padding:28px;border-radius:20px;background:rgba(255,255,255,.06);
border:1px solid rgba(255,255,255,.12);backdrop-filter:blur(14px);box-shadow:0 20px 60px rgba(0,0,0,.5)}
h1{margin:0 0 4px;font-size:22px}
h3{margin:0 0 4px;font-size:13px;letter-spacing:.08em;text-transform:uppercase;opacity:.65}
.sub{display:flex;align-items:center;gap:8px;font-size:13px;opacity:.8;margin-bottom:18px}
.dot{width:9px;height:9px;border-radius:50%;background:#ef5350}
.dot.on{background:#66bb6a;box-shadow:0 0 8px #66bb6a}
.row{display:flex;align-items:center;justify-content:space-between;gap:10px;margin:12px 0}
.row>label:first-child{font-size:14px;width:110px;flex-shrink:0}
select,input[type=text]{flex:1;min-width:0;padding:9px 10px;border-radius:10px;border:1px solid rgba(255,255,255,.2);
background:#171a33;color:#e8eaf6;font-size:14px}
button{padding:9px 14px;border:0;border-radius:10px;cursor:pointer;font-weight:600;
background:linear-gradient(135deg,#7c4dff,#448aff);color:#fff}
button.sec{background:#2d3158}
button.danger{background:#7a2b3a}
button:active{transform:scale(.96)}
input[type=range]{flex:1;accent-color:#7c4dff}
.val{width:72px;text-align:right;font-variant-numeric:tabular-nums;font-size:14px}
.sw{position:relative;width:46px;height:26px}
.sw input{display:none}
.sw span{position:absolute;inset:0;background:#444a73;border-radius:26px;cursor:pointer;transition:.2s}
.sw span:before{content:"";position:absolute;width:20px;height:20px;left:3px;top:3px;
background:#fff;border-radius:50%;transition:.2s}
.sw input:checked+span{background:#7c4dff}
.sw input:checked+span:before{transform:translateX(20px)}
hr{border:0;border-top:1px solid rgba(255,255,255,.1);margin:18px 0}
.active{font-size:12px;opacity:.7;margin:-8px 0 12px}
#saved{font-size:12px;opacity:0;transition:.3s;text-align:right;color:#66bb6a}
</style></head><body><div class="card">
<h1>HapticLite</h1>
<div class="sub"><span class="dot" id="dot"></span><span id="st">Connecting...</span></div>

<h3>Profile</h3>
<div class="row"><select id="profile"></select><button class="danger" id="del" onclick="delApp()">Remove</button></div>
<div class="row"><input type="text" id="newapp" list="seen" placeholder="Add app, e.g. chrome.exe"><button class="sec" onclick="addApp()">Add app</button></div>
<datalist id="seen"></datalist>
<div class="active">Active app right now: <b id="active">-</b></div>
<hr>

<div class="row"><label>Enabled</label><label class="sw"><input type="checkbox" id="enabled"><span></span></label></div>
<div class="row"><label>Strength</label><input type="range" id="strength" min="1" max="3" step="1"><span class="val" id="sv"></span></div>
<hr>

<h3>Click feedback</h3>
<div class="row"><label>Left click</label><select id="left"></select><button onclick="t('left')">Test</button></div>
<div class="row"><label>Right click</label><select id="right"></select><button onclick="t('right')">Test</button></div>
<div class="row"><label>Middle click</label><select id="middle"></select><button onclick="t('middle')">Test</button></div>
<div class="row"><label>Delay</label><input type="range" id="delay" min="0" max="500" step="10"><span class="val" id="dv"></span></div>
<hr>

<h3>Side buttons</h3>
<div class="row"><label>Back</label><select id="x1"></select><button onclick="t('x1')">Test</button></div>
<div class="row"><label>Forward</label><select id="x2"></select><button onclick="t('x2')">Test</button></div>
<hr>

<h3>Scroll wheel</h3>
<div class="row"><label>Scroll buzz</label><label class="sw"><input type="checkbox" id="scroll_on"><span></span></label></div>
<div class="row"><label>Scroll waveform</label><select id="scroll_wf"></select><button onclick="t('scroll_wf')">Test</button></div>
<div class="row"><label>Density</label><input type="range" id="scroll_density" min="0" max="4" step="1"><span class="val" id="scv"></span></div>
<hr>

<h3>Side scroll wheel (thumb)</h3>
<div class="row"><label>Thumb buzz</label><label class="sw"><input type="checkbox" id="thumb_on"><span></span></label></div>
<div class="row"><label>Thumb waveform</label><select id="thumb_wf"></select><button onclick="t('thumb_wf')">Test</button></div>
<div class="row"><label>Density</label><input type="range" id="thumb_density" min="0" max="4" step="1"><span class="val" id="thv"></span></div>
<hr>

<h3>Pointer speed</h3>
<div class="row"><label>Control speed</label><label class="sw"><input type="checkbox" id="ptr_on"><span></span></label></div>
<div class="row"><label>Speed</label><input type="range" id="ptr_speed" min="1" max="20" step="1"><span class="val" id="ptv"></span></div>
<hr>

<h3>Hold feedback</h3>
<div class="row"><label>Hold feedback</label><label class="sw"><input type="checkbox" id="hold_on"><span></span></label></div>
<div class="row" style="display:none"><label>Hold time</label><input type="range" id="hold_ms" min="0" max="2000" step="50"><span class="val" id="hv"></span></div>
<div class="row"><label>Hold waveform</label><select id="hold_wf"></select><button onclick="t('hold_wf')">Test</button></div>
<div class="row" style="display:none"><label>Pulses</label><label class="sw"><input type="checkbox" id="pulse"><span></span></label></div>
<div class="row"><label>Repeat every</label><input type="range" id="pulse_ms" min="30" max="1000" step="10"><span class="val" id="pv"></span></div>
<div class="row" style="display:none"><label>Pulse buzz</label><select id="pulse_wf"></select><button onclick="t('pulse_wf')">Test</button></div>
<div id="saved">Saved</div>
</div>
<script>
const $=id=>document.getElementById(id);
const WF=["left","right","middle","x1","x2","scroll_wf","thumb_wf","hold_wf","pulse_wf"];
const SL=["delay","hold_ms","pulse_ms","strength","scroll_density","thumb_density","ptr_speed"];
const CB=["enabled","pulse","scroll_on","thumb_on","hold_on","ptr_on"];
let S=null, cur="default";

function opts(sel,list,val){
  sel.innerHTML=list.map(w=>`<option>${w}</option>`).join("");
  if(!list.includes(val)){sel.insertAdjacentHTML("afterbegin",`<option>${val}</option>`);}
  sel.value=val;
}
function prof(){return cur==="default"?S.cfg.default:S.cfg.apps[cur];}
function labels(){
  $("dv").textContent=$("delay").value+" ms";
  $("hv").textContent=+$("hold_ms").value===0?"Instant":$("hold_ms").value+" ms";
  $("pv").textContent=$("pulse_ms").value+" ms";
  $("sv").textContent=$("strength").value+"x";
  const DN=["Sparse","Light","Standard","Fine","Dense"];
  $("scv").textContent=DN[$("scroll_density").value];
  $("thv").textContent=DN[$("thumb_density").value];
  $("ptv").textContent=$("ptr_speed").value;
}
function fillProfiles(){
  const names=["default",...Object.keys(S.cfg.apps)];
  $("profile").innerHTML=names.map(n=>`<option value="${n}">${n==="default"?"Default (all other apps)":n}</option>`).join("");
  $("profile").value=cur;
  $("del").style.display=cur==="default"?"none":"";
}
function render(){
  const p=prof();
  WF.forEach(i=>opts($(i),S.wf,p[i]));
  CB.forEach(i=>$(i).checked=p[i]);
  SL.forEach(i=>$(i).value=p[i]);
  labels();
  fillProfiles();
}
async function refresh(){S=await (await fetch("/api/state")).json();}
async function poll(){
  const first=!S, old=S?S.wf.length:0;
  await refresh();
  if(!S.cfg.apps[cur]&&cur!=="default")cur="default";
  if(first||S.wf.length!==old)render();
  $("dot").className="dot"+(S.online?" on":"");
  $("st").textContent=S.online?"Plugin connected":"Waiting for plugin...";
  $("active").textContent=S.active||"-";
  $("seen").innerHTML=S.seen.map(n=>`<option value="${n}">`).join("");
}
async function save(){
  const p={};
  CB.forEach(i=>p[i]=$(i).checked);
  SL.forEach(i=>p[i]=+$(i).value);
  WF.forEach(i=>p[i]=$(i).value);
  Object.assign(prof(),p);
  await fetch("/api/save",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({target:cur,profile:p})});
  $("saved").style.opacity=1;setTimeout(()=>$("saved").style.opacity=0,1000);
}
function t(i){fetch("/api/test/"+$(i).value+"?reps="+$("strength").value)}
async function addApp(){
  let n=$("newapp").value.trim().toLowerCase();
  if(!n)return;
  if(!n.endsWith(".exe"))n+=".exe";
  await fetch("/api/addapp",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({exe:n})});
  await refresh();cur=n;$("newapp").value="";render();
}
async function delApp(){
  await fetch("/api/delapp",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({exe:cur})});
  cur="default";await refresh();render();
}
$("profile").addEventListener("change",e=>{cur=e.target.value;render();});
WF.concat(CB).forEach(i=>$(i).addEventListener("change",save));
SL.forEach(i=>{
  $(i).addEventListener("input",labels);
  $(i).addEventListener("change",save);
});
poll();setInterval(poll,3000);
</script></body></html>"""

@app.get("/")
def index():
    return Response(PAGE, mimetype="text/html")

@app.get("/api/state")
def api_state():
    return jsonify(cfg=cfg, wf=state["wf"], online=state["online"],
                   active=state["active"], seen=sorted(state["seen"]))

@app.post("/api/save")
def api_save():
    d = request.get_json()
    t = d.get("target", "default")
    p = cfg["default"] if t == "default" else cfg["apps"].get(t)
    if p is None:
        return jsonify(ok=False), 404
    inc = d.get("profile", {})
    for k in DEFAULT_PROFILE:
        if k in inc:
            p[k] = inc[k]
    for k, (lo, hi) in LIMITS.items():
        p[k] = max(lo, min(hi, int(p[k])))
    for k in ("enabled", "pulse", "scroll_on", "thumb_on", "hold_on", "ptr_on"):
        p[k] = bool(p[k])
    save_cfg()
    return jsonify(ok=True)

@app.post("/api/addapp")
def api_addapp():
    e = request.get_json().get("exe", "").strip().lower()
    if e and e not in cfg["apps"]:
        cfg["apps"][e] = dict(cfg["default"])
        save_cfg()
    return jsonify(ok=True)

@app.post("/api/delapp")
def api_delapp():
    cfg["apps"].pop(request.get_json().get("exe", ""), None)
    save_cfg()
    return jsonify(ok=True)

@app.get("/api/test/<name>")
def api_test(name):
    reps = max(1, min(3, int(request.args.get("reps", 1))))
    threading.Thread(target=buzz, args=(name, 0, reps), daemon=True).start()
    return jsonify(ok=True)

app.run(host="127.0.0.1", port=8767)
'@
Set-Content -Encoding utf8 "$dir\app.py" $app

# ---- 4. libraries ----
Write-Host "[4/7] Installing libraries (flask, requests, pynput, websocket-client)..."
& $py -m pip install --quiet --disable-pip-version-check flask requests pynput websocket-client
if ($LASTEXITCODE -ne 0) { throw "pip install failed. Check your internet connection and run this script again." }

# ---- 5. autostart (Task Scheduler, with Startup-shortcut fallback) ----
Write-Host "[5/7] Setting up autostart..."
$useTask = $false
try {
    $a = New-ScheduledTaskAction -Execute $pyw -Argument "`"$dir\app.py`"" -WorkingDirectory $dir
    $t = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $t.Delay = "PT30S"
    $s = New-ScheduledTaskSettingsSet -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
    $p = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $taskName -Action $a -Trigger $t -Settings $s -Principal $p -Force | Out-Null
    Remove-Item $lnk -ErrorAction SilentlyContinue
    $useTask = $true
    Write-Host "      Task Scheduler task created (starts 30 s after sign-in, retries up to 5 times)."
} catch {
    Write-Host "      Task Scheduler failed: $($_.Exception.Message)" -ForegroundColor Yellow
    $sh = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    $sh.TargetPath = $pyw
    $sh.Arguments = "`"$dir\app.py`""
    $sh.WorkingDirectory = $dir
    $sh.Save()
    Write-Host "      Used a Startup shortcut instead."
}

# ---- 6. desktop helpers ----
Write-Host "[6/7] Creating desktop files..."
if ($useTask) {
    $bat = @'
@echo off
schtasks /End /TN HapticLite >nul 2>&1
taskkill /F /IM pythonw.exe >nul 2>&1
schtasks /Run /TN HapticLite
'@
} else {
    $bat = @'
@echo off
taskkill /F /IM pythonw.exe >nul 2>&1
start "" /D "%USERPROFILE%\HapticLite" "%LOCALAPPDATA%\Programs\Python\Python312\pythonw.exe" "%USERPROFILE%\HapticLite\app.py"
'@
}
Set-Content -Encoding ascii "$desktop\restart.bat" $bat
@("[InternetShortcut]", "URL=http://localhost:8767") | Set-Content -Encoding ascii "$desktop\HapticLite Settings.url"

# ---- 7. start and check ----
Write-Host "[7/7] Starting the app..."
if ($useTask) { Start-ScheduledTask -TaskName $taskName }
else { Start-Process $pyw "`"$dir\app.py`"" -WorkingDirectory $dir }

$up = $false
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Seconds 1
    if (Get-NetTCPConnection -LocalPort 8767 -State Listen -ErrorAction SilentlyContinue) { $up = $true; break }
}
if ($up) { Write-Host "      App is running: http://localhost:8767" -ForegroundColor Green }
else { Write-Host "      The app did not start listening on port 8767. Run this to see the error: & '$py' '$dir\app.py'" -ForegroundColor Yellow }

try {
    $r = Invoke-RestMethod https://local.jmw.nz:41443/waveforms -TimeoutSec 5
    Write-Host "      HapticWeb plugin: responding ($($r.count) waveforms)" -ForegroundColor Green
} catch {
    Write-Host "      HapticWeb plugin: NOT responding yet. Install it in Logi Options+ and restart Options+ (see below)." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Done. Still to do by hand:"
Write-Host "  1. Logi Options+ > Buttons > Show actions ring > Configure action ring > Marketplace icon (top right) > search 'HapticWeb' by Jasper M-W > install, then restart Options+."
Write-Host "  2. Optional: map an Options+ button or Actions Ring item to open http://localhost:8767 (or use the 'HapticLite Settings' file in the app folder)."
Write-Host "Restart the app any time with 'restart.bat' in the application folder."