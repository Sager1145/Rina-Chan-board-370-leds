#include "web_setup.h"

#include <Arduino.h>
#include <ArduinoJson.h>
#include <WebServer.h>
#include <DNSServer.h>

#include "config.h"
#include "wifi_manager.h"

namespace {

WebServer g_server(WEB_SETUP_PORT);
DNSServer g_dns;
bool g_httpUp = false;   // WebServer running (STA connected or AP active)
bool g_dnsUp = false;    // captive DNS running (AP active only)

// ---------------------------------------------------------------------------
// PROGMEM page: single file, inline CSS/JS, bilingual zh-Hans / English,
// mobile-first. Polls /api/wifi/status and /api/wifi/scan; posts credentials,
// mode and AP settings. Everything else is controlled from the iOS app.
// ---------------------------------------------------------------------------
const char PAGE[] PROGMEM = R"HTML(<!DOCTYPE html>
<html lang="zh-Hans"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>RinaChanBoard Wi-Fi 设置 / Setup</title>
<style>
:root{color-scheme:light dark}
*{box-sizing:border-box}
body{font-family:-apple-system,system-ui,sans-serif;margin:0;padding:16px;max-width:480px;margin:0 auto;background:#111;color:#eee}
h1{font-size:1.1rem;margin:8px 0}
.card{background:#1c1c1e;border-radius:12px;padding:14px;margin-bottom:14px}
.row{display:flex;justify-content:space-between;padding:3px 0;font-size:.9rem}
.row span:first-child{opacity:.7}
label{display:block;font-size:.85rem;margin:8px 0 4px;opacity:.85}
input,select{width:100%;padding:10px;border-radius:8px;border:1px solid #444;background:#000;color:#eee;font-size:1rem}
button{width:100%;padding:12px;border-radius:8px;border:none;background:#f971d4;color:#000;font-weight:600;font-size:1rem;margin-top:10px}
button.secondary{background:#333;color:#eee}
#nets div{padding:8px 4px;border-bottom:1px solid #333;font-size:.9rem;cursor:pointer}
#nets div:active{background:#333}
.msg{font-size:.85rem;margin-top:8px;min-height:1.2em}
.note{font-size:.8rem;opacity:.6;line-height:1.4}
</style></head><body>
<h1>RinaChanBoard 网络设置 / Wi-Fi Setup</h1>

<div class="card">
<div class="row"><span>板名 / Board</span><span id="board">-</span></div>
<div class="row"><span>模式 / Mode</span><span id="mode">-</span></div>
<div class="row"><span>家庭Wi-Fi / STA</span><span id="sta">-</span></div>
<div class="row"><span>信号 / RSSI</span><span id="rssi">-</span></div>
<div class="row"><span>热点 / Hotspot</span><span id="ap">-</span></div>
<div class="row"><span>客户端 / Clients</span><span id="clients">-</span></div>
<div class="row"><span>已选网络 / Active profile</span><span id="prof">-</span></div>
</div>

<div class="card">
<label>工作模式 / Mode</label>
<select id="modeSel">
<option value="off">关闭 / Off</option>
<option value="ap">仅热点 / Hotspot only</option>
<option value="sta">家庭Wi-Fi / Home Wi-Fi</option>
<option value="sta_or_ap">家庭Wi-Fi+热点备用 / Home + Hotspot fallback</option>
</select>
<button class="secondary" onclick="setMode()">应用 / Apply</button>
<div class="msg" id="modeMsg"></div>
</div>

<div class="card">
<label>&nbsp;</label>
<button class="secondary" onclick="scan()">扫描 / Scan Wi-Fi</button>
<div id="nets"></div>
<label>SSID</label>
<input id="ssid" placeholder="Wi-Fi name">
<label>密码 / Password</label>
<input id="pass" type="password" placeholder="Password">
<button onclick="connect()">连接 / Connect</button>
<div class="msg" id="staMsg"></div>
</div>

<div class="card">
<label>&nbsp;</label>
<div class="row"><span>手机热点 / Phone hotspot</span><span id="hs">-</span></div>
<label>SSID</label>
<input id="hssid" placeholder="Hotspot name (phone)">
<label>密码 / Password</label>
<input id="hpass" type="password" placeholder="Password">
<button onclick="setHotspot()">保存 / Save</button>
<div class="msg" id="hsMsg"></div>
</div>

<div class="card">
<label>热点名称 / Hotspot name</label>
<input id="apssid" placeholder="Hotspot SSID">
<label>热点密码 / Hotspot password (留空=开放 / empty=open, &ge;8 chars)</label>
<input id="appass" type="password" placeholder="min 8 chars or empty">
<button class="secondary" onclick="setAp()">保存 / Save</button>
<div class="msg" id="apMsg"></div>
</div>

<p class="note">其它所有功能（表情、颜色、动画、滚动文字等）请使用 RinaBoard iOS App
通过蓝牙或 Wi-Fi 连接本板控制。/ All other features (expressions, colors,
animations, scrolling text, etc.) are controlled from the RinaBoard iOS app
over Bluetooth or Wi-Fi.</p>

<script>
function j(u,o){return fetch(u,o).then(r=>r.json())}
function refresh(){
  j('/api/wifi/status').then(s=>{
    document.getElementById('board').textContent=s.hostname||'-';
    document.getElementById('mode').textContent=s.mode||'-';
    document.getElementById('sta').textContent=s.staConnected?(s.ssid+' '+s.ip):'未连接 / not connected';
    document.getElementById('rssi').textContent=s.staConnected?(s.rssi+' dBm'):'-';
    document.getElementById('ap').textContent=s.apActive?(s.apSsid+' '+s.apIp):'关闭 / off';
    document.getElementById('clients').textContent=s.clients||0;
    document.getElementById('hs').textContent=s.hotspotSsid?s.hotspotSsid:'未设置 / not set';
    var pn={home:'家庭 / home',hotspot:'手机热点 / hotspot',none:'无 / none'};
    document.getElementById('prof').textContent=pn[s.activeProfile]||'-';
    document.getElementById('modeSel').value=s.mode||'off';
    if(window._connecting && s.staConnected){
      window._connecting=false;
      document.getElementById('staMsg').textContent='已连接 / connected: '+s.ip;
    }
  });
}
function scan(){
  document.getElementById('nets').innerHTML='扫描中... / scanning...';
  j('/api/wifi/scan',{method:'POST'}).then(()=>pollScan());
}
function pollScan(){
  j('/api/wifi/scan').then(r=>{
    if(r.scanning){setTimeout(pollScan,1000);return}
    var el=document.getElementById('nets');
    el.innerHTML='';
    (r.networks||[]).forEach(function(n){
      var bars=n.rssi>-60?'▉▉▉':(n.rssi>-75?'▉▉':'▉');
      var d=document.createElement('div');
      d.textContent=n.ssid+'  '+bars+(n.secure?' 🔒':'');
      d.onclick=function(){document.getElementById('ssid').value=n.ssid};
      el.appendChild(d);
    });
    if(!(r.networks||[]).length) el.textContent='未发现网络 / no networks';
  });
}
function connect(){
  var ssid=document.getElementById('ssid').value;
  var pass=document.getElementById('pass').value;
  if(!ssid){document.getElementById('staMsg').textContent='请输入SSID / enter SSID';return}
  document.getElementById('staMsg').textContent='连接中... / connecting...';
  window._connecting=true;
  j('/api/wifi/credentials',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ssid:ssid,password:pass})});
}
function setHotspot(){
  var s=document.getElementById('hssid').value;
  var p=document.getElementById('hpass').value;
  if(!s){document.getElementById('hsMsg').textContent='请输入SSID / enter SSID';return}
  j('/api/wifi/hotspot',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ssid:s,password:p})}).then(r=>{
    document.getElementById('hsMsg').textContent=r.ok?'已保存 / saved':'失败 / failed';
  });
}
function setMode(){
  var m=document.getElementById('modeSel').value;
  j('/api/wifi/mode',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({mode:m})}).then(r=>{
    document.getElementById('modeMsg').textContent=r.ok?'已应用 / applied':'失败 / failed';
  });
}
function setAp(){
  var s=document.getElementById('apssid').value;
  var p=document.getElementById('appass').value;
  if(!s){document.getElementById('apMsg').textContent='请输入名称 / enter name';return}
  j('/api/wifi/ap',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ssid:s,password:p})}).then(r=>{
    document.getElementById('apMsg').textContent=r.ok?'已保存 / saved':'失败(密码需&ge;8位) / failed (password needs 8+ chars)';
  });
}
refresh();
setInterval(refresh,3000);
</script>
</body></html>
)HTML";

void sendJsonError(int code, const char* msg) {
    StaticJsonDocument<128> d;
    d["ok"] = false;
    d["error"] = msg;
    String body;
    serializeJson(d, body);
    g_server.send(code, "application/json", body);
}

void handleRoot() {
    g_server.send_P(200, "text/html", PAGE);
}

void handleStatus() {
    StaticJsonDocument<768> d;
    JsonObject o = d.to<JsonObject>();
    wifiManagerGetStatusJson(o);
    String body;
    serializeJson(d, body);
    g_server.send(200, "application/json", body);
}

void handleScanPost() {
    bool started = wifiManagerScanInProgress() || wifiManagerStartScan();
    if (!started) {
        sendJsonError(500, "scan_failed");
        return;
    }
    StaticJsonDocument<64> d;
    d["ok"] = true;
    d["scanning"] = true;
    String body;
    serializeJson(d, body);
    g_server.send(200, "application/json", body);
}

void handleScanGet() {
    // 20 networks × {ssid,rssi,secure} + copied SSID strings ≈ 1.7 KB; 1024 truncated silently.
    DynamicJsonDocument d(2560);
    d["ok"] = true;
    d["scanning"] = wifiManagerScanInProgress();
    JsonArray nets = d.createNestedArray("networks");
    wifiManagerGetScanJson(nets);
    String body;
    serializeJson(d, body);
    g_server.send(200, "application/json", body);
}

bool parseBody(StaticJsonDocument<512>& d) {
    if (!g_server.hasArg("plain"))
        return false;
    DeserializationError e = deserializeJson(d, g_server.arg("plain"));
    return !e;
}

void handleCredentials() {
    StaticJsonDocument<512> d;
    if (!parseBody(d)) {
        sendJsonError(400, "invalid_json");
        return;
    }
    String ssid = d["ssid"] | "";
    String pass = d["password"] | "";
    if (!wifiManagerSetCredentials(ssid, pass)) {
        sendJsonError(400, "ssid_required");
        return;
    }
    // Answer first: switching mode may restart the SoftAP and drop this very
    // connection, so the 200 must be on the wire before the radio changes.
    StaticJsonDocument<32> out;
    out["ok"] = true;
    String body;
    serializeJson(out, body);
    g_server.send(200, "application/json", body);
    g_server.client().flush();
    wifiManagerSetMode("sta_or_ap");
    wifiManagerConnect();
}

void handleHotspot() {
    StaticJsonDocument<512> d;
    if (!parseBody(d)) {
        sendJsonError(400, "invalid_json");
        return;
    }
    String ssid = d["ssid"] | "";
    String pass = d["password"] | "";
    if (!wifiManagerSetHotspotCredentials(ssid, pass)) {
        sendJsonError(400, "ssid_required");
        return;
    }
    StaticJsonDocument<32> out;
    out["ok"] = true;
    String body;
    serializeJson(out, body);
    g_server.send(200, "application/json", body);
}

void handleMode() {
    StaticJsonDocument<512> d;
    if (!parseBody(d)) {
        sendJsonError(400, "invalid_json");
        return;
    }
    String mode = d["mode"] | "";
    if (!wifiManagerSetMode(mode)) {
        sendJsonError(400, "bad_mode");
        return;
    }
    StaticJsonDocument<32> out;
    out["ok"] = true;
    String body;
    serializeJson(out, body);
    g_server.send(200, "application/json", body);
}

void handleAp() {
    StaticJsonDocument<512> d;
    if (!parseBody(d)) {
        sendJsonError(400, "invalid_json");
        return;
    }
    String ssid = d["ssid"] | "";
    String pass = d["password"] | "";
    if (pass.length() > 0 && pass.length() < 8) {
        sendJsonError(400, "password_too_short");
        return;
    }
    if (!wifiManagerSetAp(ssid, pass)) {
        sendJsonError(400, "ssid_required");
        return;
    }
    StaticJsonDocument<32> out;
    out["ok"] = true;
    String body;
    serializeJson(out, body);
    g_server.send(200, "application/json", body);
}

void handleNotFound() {
    sendJsonError(404, "not_found");
}

void registerRoutes() {
    g_server.on("/", HTTP_GET, handleRoot);
    g_server.on("/api/wifi/status", HTTP_GET, handleStatus);
    g_server.on("/api/wifi/scan", HTTP_POST, handleScanPost);
    g_server.on("/api/wifi/scan", HTTP_GET, handleScanGet);
    g_server.on("/api/wifi/credentials", HTTP_POST, handleCredentials);
    g_server.on("/api/wifi/hotspot", HTTP_POST, handleHotspot);
    g_server.on("/api/wifi/mode", HTTP_POST, handleMode);
    g_server.on("/api/wifi/ap", HTTP_POST, handleAp);
    g_server.onNotFound(handleNotFound);
}

void startServer() {
    g_server.begin();
}

bool g_routesRegistered = false;
uint32_t g_lastUpCheckMs = 0;
bool g_wantHttp = false;
bool g_wantDns = false;

} // namespace

void webSetupBegin() {
    // Routes are registered exactly once (WebServer::stop() does not free the
    // handler chain); the server/DNS are started lazily by webSetupService().
    if (!g_routesRegistered) {
        registerRoutes();
        g_routesRegistered = true;
    }
}

void webSetupService() {
    // Re-evaluate the up/down decision only when the Wi-Fi manager reports a
    // change or every 500 ms, not on every loop() iteration.
    uint32_t now = millis();
    if (wifiManagerStateChangedPeek() || (uint32_t)(now - g_lastUpCheckMs) >= 500) {
        g_lastUpCheckMs = now;
        StaticJsonDocument<512> statusDoc;
        JsonObject status = statusDoc.to<JsonObject>();
        wifiManagerGetStatusJson(status);
        bool staConnected = status["staConnected"] | false;
        bool apActive = status["apActive"] | false;
        g_wantHttp = staConnected || apActive;
        g_wantDns = apActive;
    }
    bool wantHttp = g_wantHttp;
    bool apActive = g_wantDns;

    if (wantHttp && !g_httpUp) {
        startServer();
        g_httpUp = true;
    } else if (!wantHttp && g_httpUp) {
        g_server.stop();
        g_httpUp = false;
    }
    if (g_httpUp)
        g_server.handleClient();

    if (apActive && !g_dnsUp) {
        g_dns.setTTL(60);
        g_dnsUp = g_dns.start(WEB_SETUP_DNS_PORT, AP_DOMAIN, apIP());
    } else if (!apActive && g_dnsUp) {
        g_dns.stop();
        g_dnsUp = false;
    }
    if (g_dnsUp)
        g_dns.processNextRequest();
}
