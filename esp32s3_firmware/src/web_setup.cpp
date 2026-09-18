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
// PROGMEM page: single file, inline CSS/JS, four languages (zh-Hans, zh-Hant,
// ja, en) via an inline dictionary and a t(key) lookup — no CDN, no extra
// request. Mobile-first. Polls /api/wifi/status and /api/wifi/scan; posts
// credentials, mode and AP settings. Everything else is controlled from the
// iOS app.
// ---------------------------------------------------------------------------
const char PAGE[] PROGMEM = R"HTML(<!DOCTYPE html>
<html lang="zh-Hans"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title data-i18n="page.title">Rina-chan Board Wi-Fi setup</title>
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
<h1 data-i18n="page.title">Rina-chan Board Wi-Fi setup</h1>

<div class="card">
<div class="row"><span data-i18n="board.name">Board name</span><span id="board">-</span></div>
<div class="row"><span data-i18n="mode.label">Wi-Fi mode</span><span id="mode">-</span></div>
<div class="row"><span data-i18n="network.home">Home Wi-Fi</span><span id="sta">-</span></div>
<div class="row"><span data-i18n="signal.label">Signal strength</span><span id="rssi">-</span></div>
<div class="row"><span data-i18n="hotspot.board">Board hotspot</span><span id="ap">-</span></div>
<div class="row"><span data-i18n="clients.label">Connected devices</span><span id="clients">-</span></div>
<div class="row"><span data-i18n="profile.active">Active network profile</span><span id="prof">-</span></div>
</div>

<div class="card">
<label data-i18n="mode.label">Wi-Fi mode</label>
<select id="modeSel">
<option value="off" data-i18n="mode.off">Wi-Fi off</option>
<option value="ap" data-i18n="mode.ap">Board hotspot only</option>
<option value="sta" data-i18n="mode.sta">Connect to home Wi-Fi</option>
<option value="sta_or_ap" data-i18n="mode.sta_or_ap">Home Wi-Fi (board hotspot fallback)</option>
</select>
<button class="secondary" onclick="setMode()" data-i18n="action.apply">Apply settings</button>
<div class="msg" id="modeMsg"></div>
</div>

<div class="card">
<label>&nbsp;</label>
<button class="secondary" onclick="scan()" data-i18n="action.scan">Scan Wi-Fi networks</button>
<div id="nets"></div>
<label data-i18n="field.ssid">Network name (SSID)</label>
<input id="ssid" data-i18n-placeholder="placeholder.ssid" placeholder="Enter Wi-Fi name">
<label data-i18n="field.password">Password</label>
<input id="pass" type="password" data-i18n-placeholder="placeholder.password" placeholder="Enter password">
<button onclick="connect()" data-i18n="action.connect">Connect to network</button>
<div class="msg" id="staMsg"></div>
</div>

<div class="card">
<label>&nbsp;</label>
<div class="row"><span data-i18n="hotspot.phone">Phone hotspot</span><span id="hs">-</span></div>
<label data-i18n="field.ssid">Network name (SSID)</label>
<input id="hssid" data-i18n-placeholder="placeholder.phoneHotspot" placeholder="Enter phone hotspot name">
<label data-i18n="field.password">Password</label>
<input id="hpass" type="password" data-i18n-placeholder="placeholder.password" placeholder="Enter password">
<button onclick="setHotspot()" data-i18n="action.save">Save settings</button>
<div class="msg" id="hsMsg"></div>
</div>

<div class="card">
<label data-i18n="field.boardHotspotName">Board hotspot name</label>
<input id="apssid" data-i18n-placeholder="placeholder.boardHotspotName" placeholder="Enter board hotspot name">
<label data-i18n="field.boardHotspotPassword">Board hotspot password</label>
<div class="note" data-i18n="help.boardHotspotPassword">Use at least 8 characters, or leave blank for no password.</div>
<input id="appass" type="password" data-i18n-placeholder="placeholder.boardHotspotPassword" placeholder="At least 8 characters, or leave blank">
<button class="secondary" onclick="setAp()" data-i18n="action.save">Save settings</button>
<div class="msg" id="apMsg"></div>
</div>

<div class="card">
<label data-i18n="language.label">Language</label>
<select id="langSel" onchange="setLang(this.value)">
<option value="zh-Hans">简体中文</option>
<option value="zh-Hant">繁體中文</option>
<option value="ja">日本語</option>
<option value="en">English</option>
</select>
</div>

<p class="note" data-i18n="help.app">Use the RinaBoard app over Bluetooth or Wi-Fi to control expressions, colors, animations, and scrolling text.</p>

<script>
var M={"zh-Hans":{"page.title":"璃奈板 Wi-Fi 设置","language.label":"语言","board.name":"璃奈板名称","mode.label":"Wi-Fi 模式","network.home":"家庭 Wi-Fi","signal.label":"信号强度","hotspot.board":"璃奈板热点","clients.label":"已连接设备数","profile.active":"正在使用的网络配置","mode.off":"关闭 Wi-Fi","mode.ap":"仅使用璃奈板热点","mode.sta":"连接家庭 Wi-Fi","mode.sta_or_ap":"家庭 Wi-Fi（热点备用）","action.apply":"应用设置","action.scan":"扫描 Wi-Fi 网络","field.ssid":"网络名称（SSID）","placeholder.ssid":"输入 Wi-Fi 名称","field.password":"密码","placeholder.password":"输入密码","action.connect":"连接网络","hotspot.phone":"手机热点","placeholder.phoneHotspot":"输入手机热点名称","action.save":"保存设置","field.boardHotspotName":"璃奈板热点名称","field.boardHotspotPassword":"璃奈板热点密码","help.boardHotspotPassword":"密码至少 8 个字符；留空则不设置密码。","placeholder.boardHotspotName":"输入璃奈板热点名称","placeholder.boardHotspotPassword":"至少 8 个字符，或留空","help.app":"表情、颜色、动画和滚动文字等功能，请使用 RinaBoard App 通过蓝牙或 Wi-Fi 控制。","status.notConnected":"未连接","status.off":"已关闭","status.notSet":"尚未设置","profile.home":"家庭网络","profile.hotspot":"手机热点","profile.none":"无","status.connected":"璃奈板已连接网络","status.scanning":"正在扫描…","status.noNetworks":"未发现 Wi-Fi 网络","error.ssidRequired":"请输入网络名称（SSID）。","status.connecting":"璃奈板正在连接网络…","status.saved":"设置已保存","error.saveFailed":"无法保存设置。","status.applied":"设置已应用","error.applyFailed":"无法应用设置。","error.nameRequired":"请输入璃奈板热点名称。","error.scanFailed":"Wi-Fi 扫描失败，请重试。","status.unknown":"状态未知","error.passwordTooShort":"密码至少需要 8 个字符。"},"zh-Hant":{"page.title":"璃奈板 Wi-Fi 設定","language.label":"語言","board.name":"璃奈板名稱","mode.label":"Wi-Fi 模式","network.home":"家用 Wi-Fi","signal.label":"訊號強度","hotspot.board":"璃奈板熱點","clients.label":"已連線裝置數","profile.active":"正在使用的網路設定","mode.off":"關閉 Wi-Fi","mode.ap":"僅使用璃奈板熱點","mode.sta":"連線至家用 Wi-Fi","mode.sta_or_ap":"家用 Wi-Fi（熱點備援）","action.apply":"套用設定","action.scan":"掃描 Wi-Fi 網路","field.ssid":"網路名稱（SSID）","placeholder.ssid":"輸入 Wi-Fi 名稱","field.password":"密碼","placeholder.password":"輸入密碼","action.connect":"連線至網路","hotspot.phone":"手機熱點","placeholder.phoneHotspot":"輸入手機熱點名稱","action.save":"儲存設定","field.boardHotspotName":"璃奈板熱點名稱","field.boardHotspotPassword":"璃奈板熱點密碼","help.boardHotspotPassword":"密碼至少 8 個字元；留空則不設定密碼。","placeholder.boardHotspotName":"輸入璃奈板熱點名稱","placeholder.boardHotspotPassword":"至少 8 個字元，或留空","help.app":"表情、顏色、動畫和捲動文字等功能，請使用 RinaBoard App 透過藍牙或 Wi-Fi 控制。","status.notConnected":"未連線","status.off":"已關閉","status.notSet":"尚未設定","profile.home":"家用網路","profile.hotspot":"手機熱點","profile.none":"無","status.connected":"璃奈板已連線至網路","status.scanning":"正在掃描…","status.noNetworks":"未找到 Wi-Fi 網路","error.ssidRequired":"請輸入網路名稱（SSID）。","status.connecting":"璃奈板正在連線至網路…","status.saved":"設定已儲存","error.saveFailed":"無法儲存設定。","status.applied":"設定已套用","error.applyFailed":"無法套用設定。","error.nameRequired":"請輸入璃奈板熱點名稱。","error.scanFailed":"Wi-Fi 掃描失敗，請再試一次。","status.unknown":"狀態不明","error.passwordTooShort":"密碼至少需要 8 個字元。"},"ja":{"page.title":"璃奈ちゃんボードの Wi-Fi 設定","language.label":"言語","board.name":"ボード名","mode.label":"Wi-Fi モード","network.home":"自宅の Wi-Fi","signal.label":"電波強度","hotspot.board":"ボードの Wi-Fi","clients.label":"接続中のデバイス数","profile.active":"使用中の接続設定","mode.off":"Wi-Fi をオフ","mode.ap":"ボードの Wi-Fi のみ","mode.sta":"自宅の Wi-Fi に接続","mode.sta_or_ap":"自宅の Wi-Fi（接続できない場合はボードの Wi-Fi）","action.apply":"設定を適用","action.scan":"Wi-Fi ネットワークを検索","field.ssid":"ネットワーク名（SSID）","placeholder.ssid":"Wi-Fi 名を入力","field.password":"パスワード","placeholder.password":"パスワードを入力","action.connect":"ネットワークに接続","hotspot.phone":"スマートフォンのテザリング","placeholder.phoneHotspot":"スマートフォンのネットワーク名を入力","action.save":"設定を保存","field.boardHotspotName":"ボードの Wi-Fi 名","field.boardHotspotPassword":"ボードの Wi-Fi パスワード","help.boardHotspotPassword":"パスワードは 8 文字以上で入力してください。空欄にするとパスワードなしになります。","placeholder.boardHotspotName":"ボードの Wi-Fi 名を入力","placeholder.boardHotspotPassword":"8 文字以上、または空欄","help.app":"表情、色、アニメーション、スクロール文字などの操作には、Bluetooth または Wi-Fi で接続した RinaBoard アプリを使用してください。","status.notConnected":"未接続","status.off":"オフ","status.notSet":"未設定","profile.home":"自宅のネットワーク","profile.hotspot":"スマートフォンのテザリング","profile.none":"なし","status.connected":"ボードがネットワークに接続しました","status.scanning":"検索中…","status.noNetworks":"Wi-Fi ネットワークが見つかりません","error.ssidRequired":"ネットワーク名（SSID）を入力してください。","status.connecting":"ボードがネットワークに接続中…","status.saved":"設定を保存しました","error.saveFailed":"設定を保存できませんでした。","status.applied":"設定を適用しました","error.applyFailed":"設定を適用できませんでした。","error.nameRequired":"ボードの Wi-Fi 名を入力してください。","error.scanFailed":"Wi-Fi の検索に失敗しました。もう一度お試しください。","status.unknown":"状態不明","error.passwordTooShort":"パスワードは 8 文字以上で入力してください。"},"en":{"page.title":"Rina-chan Board Wi-Fi setup","language.label":"Language","board.name":"Board name","mode.label":"Wi-Fi mode","network.home":"Home Wi-Fi","signal.label":"Signal strength","hotspot.board":"Board hotspot","clients.label":"Connected devices","profile.active":"Active network profile","mode.off":"Wi-Fi off","mode.ap":"Board hotspot only","mode.sta":"Connect to home Wi-Fi","mode.sta_or_ap":"Home Wi-Fi (board hotspot fallback)","action.apply":"Apply settings","action.scan":"Scan Wi-Fi networks","field.ssid":"Network name (SSID)","placeholder.ssid":"Enter Wi-Fi name","field.password":"Password","placeholder.password":"Enter password","action.connect":"Connect to network","hotspot.phone":"Phone hotspot","placeholder.phoneHotspot":"Enter phone hotspot name","action.save":"Save settings","field.boardHotspotName":"Board hotspot name","field.boardHotspotPassword":"Board hotspot password","help.boardHotspotPassword":"Use at least 8 characters, or leave blank for no password.","placeholder.boardHotspotName":"Enter board hotspot name","placeholder.boardHotspotPassword":"At least 8 characters, or leave blank","help.app":"Use the RinaBoard app over Bluetooth or Wi-Fi to control expressions, colors, animations, and scrolling text.","status.notConnected":"Not connected","status.off":"Off","status.notSet":"Not set","profile.home":"Home network","profile.hotspot":"Phone hotspot","profile.none":"None","status.connected":"The board joined the network","status.scanning":"Scanning…","status.noNetworks":"No Wi-Fi networks found","error.ssidRequired":"Enter a network name (SSID).","status.connecting":"The board is connecting to the network…","status.saved":"Settings saved","error.saveFailed":"Could not save settings.","status.applied":"Settings applied","error.applyFailed":"Could not apply settings.","error.nameRequired":"Enter the board hotspot name.","error.scanFailed":"Wi-Fi scan failed. Try again.","status.unknown":"Status unknown","error.passwordTooShort":"Password must be at least 8 characters."}};
function pickLang(){
  try{
    var saved=localStorage.getItem('rinaLang');
    if(saved&&M[saved])return saved;
  }catch(e){}
  var langs=navigator.languages||[navigator.language||'en'];
  for(var i=0;i<langs.length;i++){
    var l=(langs[i]||'').toLowerCase();
    if(l.indexOf('zh')===0){
      if(l.indexOf('tw')>=0||l.indexOf('hk')>=0||l.indexOf('hant')>=0)return'zh-Hant';
      return'zh-Hans';
    }
    if(l.indexOf('ja')===0)return'ja';
  }
  return'en';
}
var LANG=pickLang();
function t(k){return(M[LANG]&&M[LANG][k])||k}
function setLang(l){
  if(!M[l])return;
  LANG=l;
  try{localStorage.setItem('rinaLang',l)}catch(e){}
  render();
}
function render(){
  document.documentElement.lang=LANG;
  document.getElementById('langSel').value=LANG;
  document.querySelectorAll('[data-i18n]').forEach(function(el){el.textContent=t(el.getAttribute('data-i18n'))});
  document.querySelectorAll('[data-i18n-placeholder]').forEach(function(el){el.placeholder=t(el.getAttribute('data-i18n-placeholder'))});
  refresh();
}
function j(u,o){return fetch(u,o).then(r=>r.json())}
function refresh(){
  j('/api/wifi/status').then(s=>{
    document.getElementById('board').textContent=s.hostname||'-';
    var modeNames={off:t('mode.off'),ap:t('mode.ap'),sta:t('mode.sta'),sta_or_ap:t('mode.sta_or_ap')};
    document.getElementById('mode').textContent=modeNames[s.mode]||(s.mode?t('status.unknown'):'-');
    document.getElementById('sta').textContent=s.staConnected?(s.ssid+' '+s.ip):t('status.notConnected');
    document.getElementById('rssi').textContent=s.staConnected?(s.rssi+' dBm'):'-';
    document.getElementById('ap').textContent=s.apActive?(s.apSsid+' '+s.apIp):t('status.off');
    document.getElementById('clients').textContent=s.clients||0;
    document.getElementById('hs').textContent=s.hotspotSsid?s.hotspotSsid:t('status.notSet');
    var pn={home:t('profile.home'),hotspot:t('profile.hotspot'),none:t('profile.none')};
    document.getElementById('prof').textContent=pn[s.activeProfile]||(s.activeProfile?t('status.unknown'):'-');
    document.getElementById('modeSel').value=s.mode||'off';
    if(window._connecting && s.staConnected){
      window._connecting=false;
      document.getElementById('staMsg').textContent=t('status.connected')+': '+s.ip;
    }
  });
}
function scan(){
  document.getElementById('nets').textContent=t('status.scanning');
  j('/api/wifi/scan',{method:'POST'}).then(r=>{
    if(r.ok){pollScan()}else{document.getElementById('nets').textContent=t('error.scanFailed')}
  });
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
    if(!(r.networks||[]).length) el.textContent=t('status.noNetworks');
  });
}
function connect(){
  var ssid=document.getElementById('ssid').value;
  var pass=document.getElementById('pass').value;
  if(!ssid){document.getElementById('staMsg').textContent=t('error.ssidRequired');return}
  document.getElementById('staMsg').textContent=t('status.connecting');
  window._connecting=true;
  j('/api/wifi/credentials',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ssid:ssid,password:pass})});
}
function setHotspot(){
  var s=document.getElementById('hssid').value;
  var p=document.getElementById('hpass').value;
  if(!s){document.getElementById('hsMsg').textContent=t('error.ssidRequired');return}
  j('/api/wifi/hotspot',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ssid:s,password:p})}).then(r=>{
    document.getElementById('hsMsg').textContent=r.ok?t('status.saved'):t('error.saveFailed');
  });
}
function setMode(){
  var m=document.getElementById('modeSel').value;
  j('/api/wifi/mode',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({mode:m})}).then(r=>{
    document.getElementById('modeMsg').textContent=r.ok?t('status.applied'):t('error.applyFailed');
  });
}
function setAp(){
  var s=document.getElementById('apssid').value;
  var p=document.getElementById('appass').value;
  if(!s){document.getElementById('apMsg').textContent=t('error.nameRequired');return}
  j('/api/wifi/ap',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ssid:s,password:p})}).then(r=>{
    document.getElementById('apMsg').textContent=r.ok?t('status.saved'):(r.error==='password_too_short'?t('error.passwordTooShort'):t('error.saveFailed'));
  });
}
render();
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
