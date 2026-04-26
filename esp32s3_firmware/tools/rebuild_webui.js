const fs = require('fs');
const zlib = require('zlib');

const htmlPath = 'webui/index.html';
const sourceHtml = fs.readFileSync(htmlPath, 'utf8');
const sourceScript = (sourceHtml.match(/<script>([\s\S]*)<\/script>/i) || ['', ''])[1];

function lineStart(text, index) {
  const start = text.lastIndexOf('\n', index);
  return start < 0 ? 0 : start + 1;
}

function findAny(text, names) {
  for (const name of names) {
    const index = text.indexOf(name);
    if (index >= 0) return index;
  }
  return -1;
}

function extractBlock(beginNames, endNames) {
  const beginHit = findAny(sourceScript, beginNames);
  const endHit = findAny(sourceScript, endNames);
  if (beginHit < 0 || endHit < 0 || endHit <= beginHit) {
    throw new Error('Cannot locate WebUI data block: ' + beginNames.join(' / '));
  }
  return sourceScript.slice(lineStart(sourceScript, beginHit), lineStart(sourceScript, endHit)).trim();
}

const dataBlock = extractBlock(
  ['DATA_BUNDLE_BEGIN', 'face_bitmaps.js'],
  ['DATA_BUNDLE_END', 'app.js', 'APP_RUNTIME_BEGIN']
).replace(/\/\/ DATA_BUNDLE_BEGIN|\/\/ DATA_BUNDLE_END/g, '').trim();

const unityBlock = extractBlock(
  ['UNITY_DB_BEGIN', 'unity_db.js'],
  ['UNITY_DB_END', 'modules.js', 'APP_RUNTIME_BEGIN']
).replace(/\/\/ UNITY_DB_BEGIN|\/\/ UNITY_DB_END/g, '').trim();

function readMaybeGzip(path) {
  if (!path || !fs.existsSync(path)) return '';
  const buf = fs.readFileSync(path);
  return path.toLowerCase().endsWith('.gz') ? zlib.gunzipSync(buf).toString('utf8') : buf.toString('utf8');
}

function extractDefaultFacesFromReference() {
  const candidates = [
    process.env.WEBUI_ASSET_REFERENCE,
    'C:/Users/Sager/OneDrive - McMaster University/3dps/linaborad/RinaChanBoard_ESP32S3_370_NATIVE_1_6_0/esp32s3_firmware/webui_index.html.gz',
  ].filter(Boolean);
  for (const path of candidates) {
    try {
      const html = readMaybeGzip(path);
      const script = (html.match(/<script>([\s\S]*)<\/script>/i) || ['', ''])[1];
      const match = script.match(/const\s+DEFAULT_FACES\s*=\s*(\[[\s\S]*?\]);/);
      if (!match) continue;
      const faces = Function('"use strict"; return (' + match[1] + ');')();
      if (Array.isArray(faces) && faces.length) return faces;
    } catch (error) {
      // Keep the build deterministic even when the external reference is absent.
    }
  }
  return null;
}

let bundledDefaultFaces = extractDefaultFacesFromReference() || [];
try {
  if (!bundledDefaultFaces.length) bundledDefaultFaces = JSON.parse(fs.readFileSync('faces370.json', 'utf8'));
} catch (error) {
  bundledDefaultFaces = [];
}
bundledDefaultFaces = bundledDefaultFaces.map((face, index) => ({
  ...face,
  name: face.name || ('默认 ' + String(index + 1).padStart(2, '0')),
  type: face.type || 'default',
  locked: face.locked == null ? true : !!face.locked,
  builtin: face.builtin == null ? true : !!face.builtin,
  default_id: face.default_id || ('web_default_' + String(index).padStart(2, '0')),
}));

const css = String.raw`
:root{--bg:#0f1218;--panel:#171c25;--panel2:#202838;--line:#30384a;--text:#edf2ff;--muted:#9da9bd;--accent:#f971d4;--ok:#75f0a9;--warn:#ffd166;--bad:#ff6b6b}
*{box-sizing:border-box}
body{margin:0;background:#0f1218;color:var(--text);font-family:system-ui,-apple-system,"Segoe UI",Arial,"Microsoft YaHei",sans-serif}
button{font:inherit}
header{position:sticky;top:0;z-index:4;background:#10141d;border-bottom:1px solid var(--line);padding:10px 14px}
h1{font-size:20px;line-height:1.2;margin:0 0 6px}
h2{font-size:16px;margin:0 0 10px}
.sub{color:var(--muted);font-size:12px}
nav{display:flex;gap:6px;overflow:auto;padding-top:8px}
nav button,.btn{display:inline-flex;align-items:center;justify-content:center;gap:6px;border:1px solid #344055;border-radius:8px;background:var(--panel2);color:var(--text);padding:9px 12px;cursor:pointer;min-height:36px;text-decoration:none;line-height:1.15}
nav button:hover,.btn:hover{border-color:#4b5b78;background:#2a354a}
nav button.active,.btn.primary{background:var(--accent);color:#1d101a;font-weight:700}
.btn.danger{background:#3a1720;color:#ffb8c4}
.btn:disabled,input:disabled,select:disabled{opacity:.55;cursor:not-allowed}
main{padding:14px;max-width:1180px;margin:auto}
.tab{display:none}.tab.show{display:block}
.grid2{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:12px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:14px}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin:8px 0}
label{color:var(--muted);font-size:13px}
input,select,textarea{background:#0d1119;color:var(--text);border:1px solid #344055;border-radius:8px;padding:9px;min-height:38px}
textarea{width:100%;min-height:86px;font-family:ui-monospace,Consolas,monospace}
.wide{min-width:260px;flex:1}.mono{font-family:ui-monospace,Consolas,monospace}.small{font-size:12px;color:var(--muted)}
.pill{border-radius:999px;background:#242c3b;padding:4px 8px;color:var(--muted);font-size:12px}
.pill.ok{color:var(--ok)}.pill.warn{color:var(--warn)}
.out{white-space:pre-wrap;background:#0d1119;border-radius:8px;border:1px solid #344055;padding:9px;min-height:38px}
.log{white-space:pre-wrap;background:#080b10;border:1px solid var(--line);border-radius:8px;padding:10px;height:220px;overflow:auto;font-size:12px}
.debugLog{height:320px}
a{color:#8fd3ff}
.matrix{display:grid;grid-template-columns:repeat(22,18px);gap:4px;justify-content:start;background:#0d1119;border-radius:8px;padding:12px;overflow:auto;max-width:max-content}
.led{width:18px;height:18px;border:1px solid var(--line);border-radius:5px;background:#222836;padding:0;cursor:pointer}
.led.on{background:var(--accent);box-shadow:0 0 8px var(--accent)}
.led.hidden{visibility:hidden;pointer-events:none;border-color:transparent;background:transparent}
.miniGrid370{display:grid;grid-template-columns:repeat(22,10px);gap:2px;background:#0d1119;border:1px solid #344055;border-radius:8px;padding:8px;max-width:max-content}
.miniLed{width:10px;height:10px;border-radius:3px;background:#202838}.miniLed.on{background:var(--accent);box-shadow:0 0 5px var(--accent)}.miniLed.hidden{visibility:hidden}
.partGallery{display:grid;grid-template-columns:repeat(auto-fill,minmax(74px,1fr));gap:8px;margin-top:10px}
.partThumb{border:1px solid var(--line);background:#10151f;border-radius:8px;padding:8px;cursor:pointer;text-align:center;color:var(--muted)}
.partThumb.active{border-color:var(--accent);box-shadow:0 0 0 2px #f971d455;color:var(--text)}
.partPixels{display:grid;gap:2px;justify-content:center;margin:4px auto 6px}.partPix{width:8px;height:7px;border-radius:3px;background:#202838}.partPix.on{background:var(--accent)}
.faceList{display:grid;gap:6px;max-height:300px;overflow:auto}.faceRow{display:grid;grid-template-columns:1fr auto auto auto;gap:6px;align-items:center;border:1px solid var(--line);border-radius:8px;padding:8px;background:#10151f}.faceRow.active{border-color:var(--accent)}
.batteryGrid{display:grid;grid-template-columns:max-content 1fr;gap:8px 12px;align-items:center}.batteryGrid .k{color:var(--muted);font-size:12px}.batteryBar{height:12px;background:#252d3e;border-radius:999px;overflow:hidden}.batteryBar span{display:block;height:100%;width:0;background:var(--ok)}
.mediaPreview{display:none;width:100%;max-height:280px;background:#05070b;border-radius:8px}
`;

const body = String.raw`
<header>
  <h1>RinaChanBoard Web 控制台</h1>
  <div class="sub">当前页面来自 <span id="host" class="mono"></span>。同一个 HTML 可直接在电脑打开，也可上传到 ESP32 固件。</div>
  <nav>
    <button class="btn active" data-tab="tab-home" type="button">状态</button>
    <button class="btn" data-tab="tab-custom" type="button">点阵编辑</button>
    <button class="btn" data-tab="tab-face" type="button">表情部件</button>
    <button class="btn" data-tab="tab-saved" type="button">保存表情</button>
    <button class="btn" data-tab="tab-scroll" type="button">滚动文字</button>
    <button class="btn" data-tab="tab-media" type="button">Unity 媒体</button>
    <button class="btn" data-tab="tab-binary" type="button">协议测试</button>
    <button class="btn" data-tab="tab-wifi" type="button">Wi-Fi</button>
    <button class="btn" data-tab="tab-about" type="button">日志</button>
  </nav>
</header>
<main>
  <section id="tab-home" class="tab show">
    <div class="grid2">
      <div class="card">
        <h2>设备状态</h2>
        <div id="status" class="out mono">loading...</div>
        <div class="row">
          <input id="ipInput" class="wide" placeholder="输入设备 IP，例如 192.168.4.1">
          <button class="btn" id="openIp" type="button">打开 IP</button>
          <button class="btn" id="refreshStatus" type="button">刷新状态</button>
          <button class="btn" id="readVersion" type="button">版本</button>
          <button class="btn" id="readEspStatus" type="button">ESP 状态</button>
        </div>
        <div id="versionOut" class="out mono"></div>
        <div id="espOut" class="out mono"></div>
      </div>
      <div class="card">
        <h2>手动控制模式</h2>
        <div class="row">
          <button class="btn primary" id="manualModeToggle" type="button">启动手动控制模式</button>
          <button class="btn" id="manualModeRefresh" type="button">读取模式</button>
          <span id="manualModeBadge" class="pill">未读取</span>
        </div>
        <p class="small">实体按钮会进入手动控制模式；Web/网络控制会退出手动控制模式。</p>
        <pre id="manualModeOut" class="out mono">-</pre>
      </div>
      <div class="card">
        <h2>颜色</h2>
        <div class="row">
          <input type="color" id="colorPick" value="#f971d4">
          <input id="colorHex" value="f971d4" maxlength="6" class="mono">
          <button class="btn primary" id="uploadColor" type="button">发送颜色</button>
          <button class="btn" id="downloadColor" type="button">读取颜色</button>
        </div>
        <div class="row">
          <select id="presetColor" class="wide"></select>
          <button class="btn" id="usePresetColor" type="button">使用预设并发送</button>
        </div>
      </div>
      <div class="card">
        <h2>亮度</h2>
        <div class="row">
          <input type="number" id="bright" min="0" max="255" value="16">
          <button class="btn" data-bright="16" type="button">16</button>
          <button class="btn" data-bright="32" type="button">32</button>
          <button class="btn" data-bright="64" type="button">64</button>
          <button class="btn" data-bright="128" type="button">128</button>
          <button class="btn primary" id="uploadBright" type="button">发送亮度</button>
          <button class="btn" id="downloadBright" type="button">读取亮度</button>
        </div>
      </div>
      <div class="card">
        <h2>电池 / 充电</h2>
        <div class="row">
          <button class="btn primary" id="readBattery" type="button">读取电池状态</button>
          <button class="btn" id="autoSync" type="button">同步 face/color/bright/version/battery</button>
          <span id="batteryBadge" class="pill">未读取</span>
        </div>
        <div class="batteryGrid">
          <div class="k">电量</div><div><div class="batteryBar"><span id="batteryBarFill"></span></div><span id="batteryPercent" class="mono">-</span></div>
          <div class="k">电池电压</div><div id="batteryVoltage" class="mono">-</div>
          <div class="k">充电检测电压</div><div id="batteryChargeVoltage" class="mono">-</div>
          <div class="k">充电状态</div><div id="batteryCharging" class="mono">-</div>
          <div class="k">剩余时间</div><div id="batteryRemaining" class="mono">-</div>
          <div class="k">充满时间</div><div id="batteryChargeTime" class="mono">-</div>
        </div>
        <pre id="batteryRaw" class="out mono">-</pre>
      </div>
    </div>
  </section>
  <section id="tab-custom" class="tab">
    <div class="grid2">
      <div class="card">
        <h2>370 LED 点阵编辑</h2>
        <div class="row">
          <span class="pill">Matrix: 18 / 20x3 / 22x9 / 20x3 / 18 / 16</span>
          <button class="btn" id="clearFace" type="button">清空</button>
          <button class="btn" id="invertFace" type="button">反相</button>
          <button class="btn primary" id="uploadFace" type="button">发送</button>
          <button class="btn" id="downloadFace" type="button">读取</button>
        </div>
        <div id="grid" class="matrix"></div>
      </div>
      <div class="card">
        <h2>Matrix370 Hex</h2>
        <textarea id="faceHex" class="mono"></textarea>
        <div class="row">
          <button class="btn" id="loadHexToEditor" type="button">从 Hex 载入编辑器</button>
          <button class="btn" id="sendLegacyBinary" type="button">发送 36-byte Legacy</button>
        </div>
      </div>
    </div>
  </section>
  <section id="tab-face" class="tab">
    <div class="grid2">
      <div class="card">
        <h2>表情部件组合</h2>
        <div class="row">
          <label>左眼</label><select id="leye"></select>
          <label>右眼</label><select id="reye"></select>
          <label>嘴</label><select id="mouth"></select>
          <label>脸颊</label><select id="cheek"></select>
        </div>
        <div class="row">
          <label class="pill"><input id="eyeSyncBox" type="checkbox"> 左右眼同步</label>
          <button class="btn" id="buildFace" type="button">预览组合</button>
          <button class="btn" id="randomPartBtn" type="button">随机</button>
          <button class="btn primary" id="randomUploadPartBtn" type="button">随机并发送</button>
          <button class="btn primary" id="uploadPartFace" type="button">发送组合</button>
          <button class="btn" id="sendFaceLiteBinary" type="button">发送 4-byte Face_Lite</button>
        </div>
      </div>
      <div class="card"><h2>左眼</h2><div id="leyeGallery" class="partGallery"></div></div>
      <div class="card"><h2>右眼</h2><div id="reyeGallery" class="partGallery"></div></div>
      <div class="card"><h2>嘴</h2><div id="mouthGallery" class="partGallery"></div></div>
      <div class="card"><h2>脸颊</h2><div id="cheekGallery" class="partGallery"></div></div>
    </div>
  </section>
  <section id="tab-saved" class="tab">
    <div class="grid2">
      <div class="card">
        <h2>保存表情</h2>
        <div class="row">
          <button class="btn" id="reloadFaces" type="button">从固件读取</button>
          <button class="btn primary" id="saveCurrentFace" type="button">保存当前编辑器</button>
          <select id="saveFaceType"><option value="custom">自定义表情</option><option value="part">表情部件</option></select>
          <label class="pill"><input id="saveFaceLocked" type="checkbox"> 锁定</label>
          <span id="savedFacesCount" class="pill">0 个</span>
        </div>
        <select id="savedFaces" class="wide"></select>
        <div class="row">
          <button class="btn" id="loadCustomFace" type="button">载入</button>
          <button class="btn" id="renameCustomFace" type="button">重命名</button>
          <button class="btn" id="toggleLockFace" type="button">锁定/解锁</button>
          <button class="btn danger" id="deleteCustomFace" type="button">删除</button>
        </div>
        <div id="savedFaceList" class="faceList"></div>
      </div>
      <div class="card">
        <h2>预览</h2>
        <div id="savedFacePreview" class="miniGrid370"></div>
        <pre id="savedFaceOut" class="out mono">-</pre>
      </div>
    </div>
  </section>
  <section id="tab-scroll" class="tab">
    <div class="grid2">
      <div class="card">
        <h2>滚动文字</h2>
        <div class="row">
          <input id="scrollText" maxlength="30" value="Rina Chan Board" class="wide">
          <label>ms/帧</label><input id="scrollSpeed" type="number" min="40" max="1000" value="120">
          <button class="btn" id="previewScrollText" type="button">预览首帧</button>
          <button class="btn primary" id="startScrollText" type="button">开始</button>
          <button class="btn" id="stopScrollText" type="button">停止</button>
        </div>
        <div id="scrollPreview" class="miniGrid370"></div>
      </div>
      <div class="card"><h2>字库</h2><div id="dbInfo" class="out mono"></div></div>
    </div>
  </section>
  <section id="tab-media" class="tab">
    <div class="grid2">
      <div class="card">
        <h2>Unity 时间轴</h2>
        <div class="row">
          <label>类型</label><select id="unityMediaKind"><option value="voice">Voice</option><option value="music">Music</option><option value="video">Video</option></select>
          <label>项目</label><select id="unityMediaSelect" class="wide"></select>
        </div>
        <div class="row">
          <label>媒体文件</label><input id="unityMediaFile" type="file">
          <label>URL</label><input id="unityMediaUrl" class="wide" placeholder="可选媒体 URL">
        </div>
        <div class="row">
          <button class="btn" id="chooseUnityMedia" type="button">载入第 0 帧</button>
          <button class="btn primary" id="playUnityMedia" type="button">发送并播放</button>
          <button class="btn" id="stopUnityMedia" type="button">停止</button>
          <label class="pill"><input id="unityMediaLoop" type="checkbox"> Loop</label>
          <span class="pill mono" id="unityMediaTime">00:00</span>
        </div>
        <audio id="unityMediaAudio" controls style="display:none;width:100%"></audio>
        <video id="unityMediaVideo" class="mediaPreview" controls></video>
        <div id="unityMediaInfo" class="out mono"></div>
      </div>
      <div class="card"><h2>370 Matrix 预览</h2><div id="unityMediaPreview" class="miniGrid370"></div></div>
    </div>
  </section>
  <section id="tab-binary" class="tab">
    <div class="grid2">
      <div class="card">
        <h2>二进制请求</h2>
        <div class="row">
          <button class="btn" data-binary-request="1001" type="button">RequestFace</button>
          <button class="btn" data-binary-request="1002" type="button">RequestColor</button>
          <button class="btn" data-binary-request="1003" type="button">RequestBright</button>
          <button class="btn" data-binary-request="1004:text" type="button">RequestVersion</button>
          <button class="btn" data-binary-request="1005" type="button">RequestBattery</button>
        </div>
        <div id="binaryOut" class="out mono"></div>
      </div>
      <div class="card">
        <h2>Face_Text_Lite 16-byte</h2>
        <textarea id="textLiteHex" class="mono">FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF</textarea>
        <button class="btn" id="sendTextLite" type="button">发送 16-byte Text Lite</button>
      </div>
      <div class="card">
        <h2>任意 Hex 包</h2>
        <textarea id="rawHex" class="mono">FF0000</textarea>
        <div class="row">
          <button class="btn" id="sendRawHex" type="button">发送不等待</button>
          <button class="btn" id="sendRawHexWait" type="button">发送并等待</button>
        </div>
      </div>
    </div>
  </section>
  <section id="tab-wifi" class="tab">
    <div class="grid2">
      <div class="card">
        <h2>Wi-Fi 状态</h2>
        <div id="wifiStatusOut" class="out mono">未读取</div>
        <div class="row"><button class="btn primary" id="wifiRefreshStatus" type="button">刷新状态</button></div>
        <div id="wifiModeNote" class="small"></div>
      </div>
      <div class="card">
        <h2>连接路由器 Wi-Fi</h2>
        <div id="wifiReadonlyBanner" class="out" style="display:none;color:var(--bad)">只有连接到设备 AP 热点时才允许修改 Wi-Fi。</div>
        <div class="row"><label style="min-width:60px">SSID</label><input id="wifiSsid" class="wide"><button class="btn" id="wifiScanBtn" type="button">扫描</button></div>
        <div id="wifiScanResults" class="out" style="display:none;max-height:180px;overflow:auto"></div>
        <div class="row"><label style="min-width:60px">密码</label><input id="wifiPassword" type="password" class="wide"><button class="btn" id="wifiPwToggle" type="button">显示</button></div>
        <div class="row"><button class="btn primary" id="wifiSaveBtn" type="button">保存并重启</button></div>
        <div id="wifiSaveOut" class="out mono"></div>
      </div>
      <div class="card">
        <h2>设备热点 AP</h2>
        <div id="wifiApReadonlyBanner" class="out" style="display:none;color:var(--bad)">只有连接到设备 AP 热点时才允许修改。</div>
        <div class="row"><label style="min-width:80px">AP 名称</label><input id="wifiApSsid" class="wide" placeholder="RinaChanBoard-S3"></div>
        <div class="row"><label style="min-width:80px">AP 密码</label><input id="wifiApPassword" type="password" class="wide" placeholder="留空则开放热点"></div>
        <div class="row"><label style="min-width:80px">信道</label><select id="wifiApChannel"></select></div>
        <div class="row"><button class="btn primary" id="wifiApSaveBtn" type="button">保存并重启</button></div>
      </div>
    </div>
  </section>
  <section id="tab-about" class="tab">
    <div class="grid2">
      <div class="card">
        <h2>快捷入口</h2>
        <div class="row"><a class="btn" href="/i">/i 状态</a><a class="btn" href="/r">/r 重启</a><a class="btn" href="/wifi">/wifi</a><a class="btn" href="/0wifi">/0wifi</a></div>
      </div>
      <div class="card"><h2>运行日志</h2><div id="log" class="log mono"></div></div>
      <div class="card">
        <h2>HTML Debug Log</h2>
        <div class="row">
          <button class="btn" id="clearDebugLog" type="button">清空 Debug</button>
          <span class="pill">按钮点击、接口请求、JS 错误都会记录在这里</span>
        </div>
        <div id="debugLog" class="log debugLog mono"></div>
      </div>
    </div>
  </section>
</main>`;

const localHelper = String.raw`
// PC local-file helper. On ESP32 HTTP this does nothing; from file:// it
// redirects /api calls to the board AP. Override with ?api=http://x.x.x.x.
(function(){
  const nativeFetch = window.fetch.bind(window);
  function apiBase(){
    if (location.protocol !== 'file:') return '';
    const q = new URLSearchParams(location.search).get('api');
    if (q) localStorage.setItem('rina_api_base', q);
    return (localStorage.getItem('rina_api_base') || 'http://192.168.4.1').replace(/\/$/, '');
  }
  window.setRinaApiBase = function(url){
    localStorage.setItem('rina_api_base', String(url || '').replace(/\/$/, ''));
    return localStorage.getItem('rina_api_base');
  };
  window.fetch = function(input, opts){
    const base = apiBase();
    if (base && typeof input === 'string' && input.charAt(0) === '/') input = base + input;
    return nativeFetch(input, opts);
  };
})();
`;

const appRuntime = String.raw`
// APP_RUNTIME_BEGIN
(function(){
'use strict';

const DEFAULT_FACES = __DEFAULT_FACES__;
const ROW_LENS = [18,20,20,20,22,22,22,22,22,22,22,22,22,20,20,20,18,16];
const ROWS = 18;
const COLS = 22;
const PHY_BITS = ROW_LENS.reduce((a,b)=>a+b,0);
const PHY_HEX_LEN = Math.ceil(PHY_BITS / 4);
const LEGACY_ROW_OFFSET = 1;
const LEGACY_COL_OFFSET = 2;
const UNITY_FPS = 30;
const SAVE_KEY = 'rina_clean_saved_faces_v1';
const $ = id => document.getElementById(id);
const qa = sel => Array.from(document.querySelectorAll(sel));

let gridBits = Array(ROWS * COLS).fill(0);
let savedFaces = [];
let selectedFaceIndex = 0;
let statusTimer = null;
let mediaTimer = null;
let mediaElement = null;
let mediaBlobUrl = '';
let mediaToken = 0;
let mediaSilentFrame = 0;
let mediaLastFrame = 0;

function log(msg){
  const box = $('log');
  const line = '[' + new Date().toLocaleTimeString() + '] ' + msg;
  if (box) box.textContent = line + '\n' + box.textContent.slice(0, 9000);
  try { console.log(line); } catch (_) {}
}
function debug(msg, data){
  const box = $('debugLog');
  const detail = data == null ? '' : ' ' + (typeof data === 'string' ? data : JSON.stringify(data));
  const line = '[' + new Date().toLocaleTimeString() + '] ' + msg + detail;
  if (box) box.textContent = line + '\n' + box.textContent.slice(0, 16000);
  try { console.debug(line); } catch (_) {}
}
function action(label, fn){
  return function(ev){
    debug('button', label);
    try {
      const result = fn.call(this, ev);
      if (result && typeof result.then === 'function') {
        result.catch(error => {
          debug('action error: ' + label, error && (error.stack || error.message || String(error)));
          log(label + ' failed: ' + (error && error.message ? error.message : error));
        });
      }
      return result;
    } catch (error) {
      debug('action error: ' + label, error && (error.stack || error.message || String(error)));
      log(label + ' failed: ' + (error && error.message ? error.message : error));
      return undefined;
    }
  };
}
function on(id, event, label, fn){
  const el = $(id);
  if (!el) {
    debug('missing element', id);
    return null;
  }
  el.addEventListener(event, action(label || id, fn));
  return el;
}
function onAll(selector, event, label, fn){
  const nodes = qa(selector);
  if (!nodes.length) debug('missing selector', selector);
  nodes.forEach((el, index) => el.addEventListener(event, action((label || selector) + '#' + index, function(ev){ return fn.call(el, ev, el, index); })));
  return nodes;
}
window.addEventListener('error', ev => debug('window error', ev.message || String(ev.error || ev)));
window.addEventListener('unhandledrejection', ev => debug('promise rejection', ev.reason && (ev.reason.stack || ev.reason.message || String(ev.reason))));
function cleanHex(s){ return String(s || '').replace(/[^0-9a-fA-F]/g, '').toUpperCase(); }
function pad2(n){ return String(Math.max(0, Math.floor(n || 0))).padStart(2, '0'); }
function rowPad(row){ return Math.floor((COLS - ROW_LENS[row]) / 2); }
function isRealCell(row, col){ const p = rowPad(row); return row >= 0 && row < ROWS && col >= p && col < p + ROW_LENS[row]; }
function realCells(){ const out=[]; for(let r=0;r<ROWS;r++) for(let c=0;c<COLS;c++) if(isRealCell(r,c)) out.push([r,c]); return out; }
function bitIndex(row, col){ return row * COLS + col; }
function toByte(n){ return Number(n || 0).toString(16).padStart(2, '0').toUpperCase(); }
function safeJson(text, fallback){ try { return JSON.parse(text); } catch (_) { return fallback; } }
function commandContentType(reply){ const s = String(reply || '').trim(); return s.charAt(0) === '{' || s.charAt(0) === '['; }

async function apiText(path, opts){
  const method = (opts && opts.method) || 'GET';
  debug('api request', method + ' ' + path);
  try {
    const r = await fetch(path, opts || {});
    const t = await r.text();
    debug('api response', method + ' ' + path + ' -> ' + r.status + ' ' + t.slice(0, 160));
    if (!r.ok) throw new Error(t || r.statusText);
    return t;
  } catch (error) {
    debug('api error', method + ' ' + path + ' ' + (error && error.message ? error.message : error));
    throw error;
  }
}
async function apiJson(path, opts){ return JSON.parse(await apiText(path, opts)); }
async function postForm(path, params){
  return apiText(path, {method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded'}, body:new URLSearchParams(params)});
}
async function sendText(msg, wait){
  const t = await postForm('/api/send', {msg, wait: wait ? '1' : '0'});
  log((wait ? 'RX ' : 'TX ') + msg + (wait ? ' => ' + t : ''));
  return t;
}
async function sendHex(hex, wait, format){
  const t = await apiText('/api/binary?hex=' + encodeURIComponent(cleanHex(hex)) + '&wait=' + (wait ? '1' : '0') + '&format=' + encodeURIComponent(format || 'hex'));
  log((wait ? 'RX hex ' : 'TX hex ') + cleanHex(hex) + (wait ? ' => ' + t : ''));
  return t;
}
async function req(cmd){
  const t = await apiText('/api/request?cmd=' + encodeURIComponent(cmd));
  log(cmd + ' => ' + t);
  return t;
}

function bitsToM370(bits){
  let binary = '';
  for (const rc of realCells()) binary += bits[bitIndex(rc[0], rc[1])] ? '1' : '0';
  while (binary.length % 4) binary += '0';
  let out = '';
  for (let i=0; i<binary.length; i+=4) out += parseInt(binary.slice(i, i+4), 2).toString(16).toUpperCase();
  return out.slice(0, PHY_HEX_LEN);
}
function m370ToBits(hex){
  let raw = String(hex || '').trim();
  if (raw.toUpperCase().startsWith('M370:')) raw = raw.slice(5);
  let binary = '';
  for (const h of cleanHex(raw).padEnd(PHY_HEX_LEN, '0').slice(0, PHY_HEX_LEN)) binary += parseInt(h, 16).toString(2).padStart(4, '0');
  const bits = Array(ROWS * COLS).fill(0);
  let k = 0;
  for (const rc of realCells()) bits[bitIndex(rc[0], rc[1])] = binary[k++] === '1' ? 1 : 0;
  return bits;
}
function legacyHexToBits(hex){
  let binary = '';
  for (const h of cleanHex(hex).padEnd(72, '0').slice(0, 72)) binary += parseInt(h, 16).toString(2).padStart(4, '0');
  const bits = Array(ROWS * COLS).fill(0);
  for (let i=0; i<16*18; i++) {
    const r = Math.floor(i / 18) + LEGACY_ROW_OFFSET;
    const c = (i % 18) + LEGACY_COL_OFFSET;
    if (isRealCell(r, c)) bits[bitIndex(r, c)] = binary[i] === '1' ? 1 : 0;
  }
  return bits;
}
function bitsToLegacyHex(bits){
  let binary = '';
  for (let r=0; r<16; r++) for (let c=0; c<18; c++) {
    const rr = r + LEGACY_ROW_OFFSET, cc = c + LEGACY_COL_OFFSET;
    binary += isRealCell(rr, cc) && bits[bitIndex(rr, cc)] ? '1' : '0';
  }
  let out = '';
  for (let i=0; i<binary.length; i+=4) out += parseInt(binary.slice(i, i+4), 2).toString(16).toUpperCase();
  return out.padEnd(72, '0').slice(0, 72);
}
function bitmapToBits(bitmap){
  const bits = Array(ROWS * COLS).fill(0);
  (bitmap || []).forEach((row, r) => String(row || '').split('').forEach((ch, c) => {
    if (r < ROWS && c < COLS && isRealCell(r, c)) bits[bitIndex(r, c)] = ch === '#' || ch === '+' ? 1 : 0;
  }));
  return bits;
}
function bitsToBitmap(bits){
  const rows = [];
  for (let r=0; r<ROWS; r++) {
    let row = '';
    for (let c=0; c<COLS; c++) row += isRealCell(r,c) && bits[bitIndex(r,c)] ? '#' : '.';
    rows.push(row);
  }
  return rows;
}
function faceToBits(item){
  if (!item) return Array(ROWS * COLS).fill(0);
  if (item.hex) return m370ToBits(item.hex);
  return bitmapToBits(item.data || []);
}
function updateHexField(){ const el = $('faceHex'); if (el) el.value = 'M370:' + bitsToM370(gridBits); }
function setEditorBits(bits){ gridBits = bits.slice(0, ROWS * COLS); renderEditor(); updateHexField(); }
function setColorsByString(value){ setEditorBits(String(value || '').toUpperCase().startsWith('M370:') || cleanHex(value).length >= PHY_HEX_LEN ? m370ToBits(value) : legacyHexToBits(value)); }

function renderBits(container, bits, editable){
  if (!container) return;
  container.innerHTML = '';
  for (let r=0; r<ROWS; r++) for (let c=0; c<COLS; c++) {
    const real = isRealCell(r, c);
    const node = editable ? document.createElement('button') : document.createElement('span');
    node.className = (editable ? 'led ' : 'miniLed ') + (real ? '' : 'hidden ') + (real && bits[bitIndex(r,c)] ? 'on' : '');
    if (real && editable) {
      node.type = 'button';
      node.title = 'row ' + r + ', col ' + c;
      node.addEventListener('pointerdown', ev => { ev.preventDefault(); gridBits[bitIndex(r,c)] = gridBits[bitIndex(r,c)] ? 0 : 1; renderEditor(); updateHexField(); });
      node.addEventListener('contextmenu', ev => { ev.preventDefault(); gridBits[bitIndex(r,c)] = 0; renderEditor(); updateHexField(); });
    }
    container.appendChild(node);
  }
}
function renderEditor(){ renderBits($('grid'), gridBits, true); }

function partSize(group){ return group === 'cheek' ? [5, 2] : [8, 8]; }
function getPart(group, idx){
  const faces = window.RINA_FACES || {};
  if (!idx) return group === 'cheek' ? faces.cheek00 : faces.none;
  return (faces[group] || [])[idx - 1] || faces.none;
}
function setPart(bits, bitmap, sr, sc, w, h, flip){
  for (let r=0; r<h; r++) for (let c=0; c<w; c++) {
    const srcC = flip ? w - 1 - c : c;
    const val = bitmap && bitmap[r] && bitmap[r][srcC];
    const rr = sr + r + LEGACY_ROW_OFFSET;
    const cc = sc + c + LEGACY_COL_OFFSET;
    if (isRealCell(rr, cc)) bits[bitIndex(rr, cc)] = val ? 1 : 0;
  }
}
function buildFaceBits(le, re, mo, ch){
  const bits = Array(ROWS * COLS).fill(0);
  setPart(bits, getPart('leye', le), 0, 0, 8, 8, false);
  setPart(bits, getPart('reye', re), 0, 10, 8, 8, false);
  setPart(bits, getPart('mouth', mo), 8, 5, 8, 8, false);
  setPart(bits, getPart('cheek', ch), 8, 0, 5, 2, false);
  setPart(bits, getPart('cheek', ch), 8, 13, 5, 2, true);
  return bits;
}
function faceFromSelectors(){
  const le = +$('leye').value || 0;
  const re = +$('reye').value || 0;
  const mo = +$('mouth').value || 0;
  const ch = +$('cheek').value || 0;
  setEditorBits(buildFaceBits(le, re, mo, ch));
  syncPartThumbSelection();
}
function makeOptions(select, count){
  if (!select) return;
  select.innerHTML = '';
  for (let i=0; i<=count; i++) {
    const o = document.createElement('option');
    o.value = String(i);
    o.textContent = i === 0 ? '00' : pad2(i);
    select.appendChild(o);
  }
}
function buildPartThumb(group, idx, selectId){
  const box = document.createElement('button');
  const size = partSize(group);
  const bmp = getPart(group, idx);
  box.type = 'button';
  box.className = 'partThumb';
  box.dataset.group = group;
  box.dataset.index = String(idx);
  const pixels = document.createElement('div');
  pixels.className = 'partPixels';
  pixels.style.gridTemplateColumns = 'repeat(' + size[0] + ',8px)';
  for (let r=0; r<size[1]; r++) for (let c=0; c<size[0]; c++) {
    const px = document.createElement('span');
    px.className = 'partPix ' + (bmp && bmp[r] && bmp[r][c] ? 'on' : '');
    pixels.appendChild(px);
  }
  const label = document.createElement('div');
  label.className = 'mono small';
  label.textContent = idx === 0 ? '00' : pad2(idx);
  box.appendChild(pixels);
  box.appendChild(label);
  box.addEventListener('click', () => {
    $(selectId).value = String(idx);
    if (selectId === 'leye' && $('eyeSyncBox') && $('eyeSyncBox').checked) $('reye').value = String(idx);
    faceFromSelectors();
  });
  return box;
}
function renderPartGalleries(){
  const faces = window.RINA_FACES || {};
  [['leye','leyeGallery'],['reye','reyeGallery'],['mouth','mouthGallery'],['cheek','cheekGallery']].forEach(pair => {
    const group = pair[0], gallery = $(pair[1]);
    if (!gallery) return;
    gallery.innerHTML = '';
    const count = (faces[group] || []).length;
    for (let i=0; i<=count; i++) gallery.appendChild(buildPartThumb(group, i, group));
  });
  syncPartThumbSelection();
}
function syncPartThumbSelection(){
  const vals = {leye:+$('leye').value||0, reye:+$('reye').value||0, mouth:+$('mouth').value||0, cheek:+$('cheek').value||0};
  qa('.partThumb').forEach(el => el.classList.toggle('active', vals[el.dataset.group] === +el.dataset.index));
}
function randomizeParts(upload){
  const faces = window.RINA_FACES || {};
  const pick = group => Math.floor(Math.random() * ((faces[group] || []).length + 1));
  const le = pick('leye');
  $('leye').value = String(le);
  $('reye').value = String(($('eyeSyncBox') && $('eyeSyncBox').checked) ? le : pick('reye'));
  $('mouth').value = String(pick('mouth'));
  $('cheek').value = String(pick('cheek'));
  faceFromSelectors();
  if (upload) uploadFace();
}

function normalizeFaceItem(item, index){
  const isDefault = item && (item.type === 'default' || item.builtin || item.default_id);
  const defaultRef = isDefault ? DEFAULT_FACES[index] : null;
  const bits = faceToBits(item);
  return {
    name: isDefault && defaultRef && defaultRef.name
      ? String(defaultRef.name)
      : (item && item.name ? String(item.name) : (isDefault ? '默认表情 ' + pad2(index + 1) : '自定义表情 ' + pad2(index + 1))),
    type: isDefault ? 'default' : ((item && item.type) || 'custom'),
    locked: !!(isDefault || (item && item.locked)),
    builtin: !!(item && item.builtin),
    default_id: item && item.default_id,
    data: bitsToBitmap(bits),
    hex: bitsToM370(bits)
  };
}
function displayFaceName(face, index){
  if (face && face.name) return face.name;
  if (face.type === 'default' || face.builtin || face.default_id) return '默认表情 ' + pad2(index + 1);
  return '自定义表情 ' + pad2(index + 1);
}
function localFaces(){
  const raw = safeJson(localStorage.getItem(SAVE_KEY) || '[]', []);
  return Array.isArray(raw) && raw.length ? raw.map(normalizeFaceItem) : DEFAULT_FACES.map(normalizeFaceItem);
}
function storeLocalFaces(list){ localStorage.setItem(SAVE_KEY, JSON.stringify(list.map(faceForFirmware))); }
function faceForFirmware(face){
  const out = {name: face.name, type: face.type || 'custom', locked: !!face.locked, data: face.data || bitsToBitmap(m370ToBits(face.hex))};
  if (face.default_id) out.default_id = face.default_id;
  if (face.builtin) out.builtin = true;
  return out;
}
async function loadFaces(){
  try {
    const list = await apiJson('/api/faces');
    savedFaces = (Array.isArray(list) ? list : []).map(normalizeFaceItem);
    storeLocalFaces(savedFaces);
    log('已从固件读取保存表情：' + savedFaces.length);
  } catch (error) {
    savedFaces = localFaces();
    log('使用本地保存表情：' + error.message);
  }
  selectedFaceIndex = Math.min(selectedFaceIndex, Math.max(0, savedFaces.length - 1));
  renderSavedFaces();
}
function renderSavedFaces(){
  const sel = $('savedFaces');
  const count = $('savedFacesCount');
  const list = $('savedFaceList');
  if (count) count.textContent = savedFaces.length + ' 个';
  if (sel) {
    sel.innerHTML = '';
    savedFaces.forEach((face, i) => {
      const o = document.createElement('option');
      o.value = String(i);
      o.textContent = pad2(i + 1) + ' ' + displayFaceName(face, i) + ' [' + (face.type || 'custom') + ']';
      sel.appendChild(o);
    });
    sel.value = String(selectedFaceIndex);
  }
  if (list) {
    list.innerHTML = '';
    savedFaces.forEach((face, i) => {
      const row = document.createElement('div');
      row.className = 'faceRow ' + (i === selectedFaceIndex ? 'active' : '');
      const name = document.createElement('div');
      name.textContent = pad2(i + 1) + ' ' + displayFaceName(face, i);
      const typ = document.createElement('span');
      typ.className = 'pill';
      typ.textContent = face.type || 'custom';
      const lock = document.createElement('span');
      lock.className = 'pill ' + (face.locked ? 'warn' : '');
      lock.textContent = face.locked ? 'locked' : 'open';
      const load = document.createElement('button');
      load.type = 'button'; load.className = 'btn'; load.textContent = '载入';
      load.addEventListener('click', () => { selectedFaceIndex = i; loadSelectedFace(); });
      row.addEventListener('click', () => { selectedFaceIndex = i; renderSavedFaces(); previewSelectedFace(); });
      row.appendChild(name); row.appendChild(typ); row.appendChild(lock); row.appendChild(load);
      list.appendChild(row);
    });
  }
  previewSelectedFace();
}
function previewSelectedFace(){
  const face = savedFaces[selectedFaceIndex];
  renderBits($('savedFacePreview'), faceToBits(face), false);
  const out = $('savedFaceOut');
  if (out && face) out.textContent = JSON.stringify({index:selectedFaceIndex, name:displayFaceName(face, selectedFaceIndex), type:face.type, locked:face.locked, hex:'M370:' + face.hex}, null, 2);
}
function loadSelectedFace(){
  const face = savedFaces[selectedFaceIndex];
  if (!face) return;
  setEditorBits(faceToBits(face));
  renderSavedFaces();
}
async function addCurrentFace(){
  const name = prompt('表情名称', '自定义表情 ' + pad2(savedFaces.length + 1));
  if (name == null) return;
  const item = {name: String(name).trim() || '自定义表情', type: $('saveFaceType').value || 'custom', locked: $('saveFaceLocked').checked, data: bitsToBitmap(gridBits)};
  savedFaces.push(normalizeFaceItem(item, savedFaces.length));
  selectedFaceIndex = savedFaces.length - 1;
  storeLocalFaces(savedFaces);
  renderSavedFaces();
  try {
    await sendText('addFace370Json|' + JSON.stringify(item), true);
    await loadFaces();
  } catch (error) {
    log('保存到固件失败，仅保存到本地：' + error.message);
  }
}
async function renameSelectedFace(){
  const face = savedFaces[selectedFaceIndex];
  if (!face || face.type === 'default' || face.builtin) return;
  const name = prompt('新的表情名称', face.name);
  if (name == null) return;
  face.name = String(name).trim() || face.name;
  storeLocalFaces(savedFaces);
  renderSavedFaces();
  try { await sendText('renameFace370Index|' + selectedFaceIndex + '|' + face.name, true); } catch (e) { log('固件重命名失败：' + e.message); }
}
async function toggleSelectedLock(){
  const face = savedFaces[selectedFaceIndex];
  if (!face || face.type === 'default' || face.builtin) return;
  face.locked = !face.locked;
  storeLocalFaces(savedFaces);
  renderSavedFaces();
  try { await sendText('lockFace370|' + selectedFaceIndex + '|' + (face.locked ? '1' : '0'), true); } catch (e) { log('固件锁定状态更新失败：' + e.message); }
}
async function deleteSelectedFace(){
  const face = savedFaces[selectedFaceIndex];
  if (!face || face.locked || face.type === 'default' || face.builtin) return;
  if (!confirm('删除 ' + displayFaceName(face, selectedFaceIndex) + ' ?')) return;
  const idx = selectedFaceIndex;
  savedFaces.splice(idx, 1);
  selectedFaceIndex = Math.max(0, Math.min(savedFaces.length - 1, idx));
  storeLocalFaces(savedFaces);
  renderSavedFaces();
  try { await sendText('deleteFace370Index|' + idx, true); await loadFaces(); } catch (e) { log('固件删除失败：' + e.message); }
}

function updateManualModeUi(enabled, raw){
  const badge = $('manualModeBadge');
  const btn = $('manualModeToggle');
  const out = $('manualModeOut');
  if (badge) { badge.textContent = enabled ? 'MANUAL / 手动控制中' : 'WEB / 网络控制中'; badge.className = 'pill ' + (enabled ? 'warn' : 'ok'); }
  if (btn) btn.textContent = enabled ? '停止手动控制模式' : '启动手动控制模式';
  if (out) out.textContent = typeof raw === 'string' ? raw : JSON.stringify(raw, null, 2);
}
async function requestManualMode(){
  const text = await req('requestManualMode');
  const obj = safeJson(text, null);
  updateManualModeUi(!!(obj && obj.manual_control_mode), text);
}
async function setManualMode(enabled){
  const text = await sendText('manualMode|' + (enabled ? '1' : '0'), true);
  updateManualModeUi(enabled, text);
}
async function toggleManualMode(){
  const badge = $('manualModeBadge');
  await setManualMode(!(badge && String(badge.textContent).includes('MANUAL')));
}

async function uploadFace(){ await sendText('M370:' + bitsToM370(gridBits), false); }
async function downloadFace(){
  try { setColorsByString(await req('requestFace370')); }
  catch (_) { setColorsByString(await req('requestFace')); }
}
async function uploadColor(){
  const hex = cleanHex($('colorHex').value).slice(0, 6).padEnd(6, '0');
  $('colorHex').value = hex.toLowerCase();
  $('colorPick').value = '#' + hex.toLowerCase();
  await sendText('#' + hex, false);
}
async function downloadColor(){
  const hex = cleanHex(await req('requestColor')).slice(0, 6).padEnd(6, '0');
  $('colorHex').value = hex.toLowerCase();
  $('colorPick').value = '#' + hex.toLowerCase();
}
async function uploadBright(){
  const b = Math.max(0, Math.min(255, parseInt($('bright').value || '0', 10) || 0));
  $('bright').value = String(b);
  await sendText('B' + String(b).padStart(3, '0'), false);
}
async function downloadBright(){ $('bright').value = String(parseInt(await req('requestBright'), 10) || 0); }
async function requestVersion(){ $('versionOut').textContent = await req('requestVersion'); }
async function requestEspStatus(){ $('espOut').textContent = await req('requestEspStatus'); }
async function updateStatus(){
  try {
    const s = await apiJson('/api/status');
    $('status').textContent = 'mode=' + s.mode + ' ip=' + s.ip + ' ap=' + (s.ap_ip || '') + ' udp=' + s.udp_port + ' rssi=' + s.rssi;
    if (s.runtime) updateManualModeUi(!!s.runtime.manual_control_mode, s.runtime);
  } catch (error) {
    $('status').textContent = 'status error: ' + error.message;
  }
}
function updateBatteryUi(obj){
  const pct = obj.percent == null ? null : Math.max(0, Math.min(100, Number(obj.percent)));
  $('batteryBadge').textContent = pct == null ? '未知' : pct.toFixed(0) + '%';
  $('batteryBadge').className = 'pill ' + (obj.charging ? 'ok' : '');
  $('batteryBarFill').style.width = (pct == null ? 0 : pct) + '%';
  $('batteryPercent').textContent = pct == null ? '-' : pct.toFixed(1) + '%';
  $('batteryVoltage').textContent = obj.battery_voltage == null ? '-' : Number(obj.battery_voltage).toFixed(3) + ' V';
  $('batteryChargeVoltage').textContent = obj.charge_voltage == null ? '-' : Number(obj.charge_voltage).toFixed(3) + ' V';
  $('batteryCharging').textContent = obj.charging ? 'charging' : 'not charging';
  $('batteryRemaining').textContent = obj.remaining_minutes == null ? '-' : obj.remaining_minutes + ' min';
  $('batteryChargeTime').textContent = obj.charge_minutes == null ? '-' : obj.charge_minutes + ' min';
  $('batteryRaw').textContent = JSON.stringify(obj, null, 2);
}
async function requestBatteryJson(){
  const text = await req('requestBattery');
  updateBatteryUi(safeJson(text, {}));
}
async function autoSyncAll(){
  const out = $('espOut');
  const result = {};
  try { result.face370 = await req('requestFace370'); setColorsByString(result.face370); } catch(e) { result.face = e.message; }
  try { result.color = await req('requestColor'); } catch(e) { result.color = e.message; }
  try { result.bright = await req('requestBright'); } catch(e) { result.bright = e.message; }
  try { result.version = await req('requestVersion'); } catch(e) { result.version = e.message; }
  try { result.battery = safeJson(await req('requestBattery'), {}); updateBatteryUi(result.battery); } catch(e) { result.battery = e.message; }
  if (out) out.textContent = JSON.stringify(result, null, 2);
}

function glyphFor(ch){
  const db = window.RINA_UNITY_DB || {};
  const code = ch.charCodeAt(0);
  return (db.ascii || []).find(g => g.id === code || g.symbol === ch);
}
function textToBits(text, offset){
  const bits = Array(ROWS * COLS).fill(0);
  let x = COLS - (offset || 0);
  const y0 = 5;
  for (const ch of String(text || '')) {
    const g = glyphFor(ch) || glyphFor('?') || glyphFor(' ');
    const rows = g ? g.content : [];
    for (let r=0; r<7; r++) for (let c=0; c<5; c++) {
      const rr = y0 + r, cc = x + c;
      if (rows[r] && rows[r][c] && isRealCell(rr, cc)) bits[bitIndex(rr, cc)] = 1;
    }
    x += 6;
  }
  return bits;
}
function previewScrollText(){ renderBits($('scrollPreview'), textToBits($('scrollText').value, 0), false); }
async function startScrollText(){
  stopUnityMedia(false);
  const speed = Math.max(40, Math.min(1000, parseInt($('scrollSpeed').value || '120', 10) || 120));
  const text = String($('scrollText').value || '').replace(/[\r\n\t|]/g, ' ').slice(0, 96);
  previewScrollText();
  await sendText('scrollText370|' + speed + '|' + text, true);
}
async function stopScrollText(doFirmwareStop){
  if (doFirmwareStop !== false) await sendText('runtimeStop|scroll', false);
}

function db(){ return window.RINA_UNITY_DB || {}; }
function timelineOf(kind, key){
  const d = db();
  if (kind === 'voice') return (d.voiceTimelines || {})[key] || [];
  if (kind === 'music') return (d.musicTimelines || {})[key] || [];
  return (d.videoTimelines || {})[key] || [];
}
function mediaKeys(kind){
  const d = db();
  const map = kind === 'voice' ? d.voiceTimelines : kind === 'music' ? d.musicTimelines : d.videoTimelines;
  return Object.keys(map || {});
}
function mediaAsset(kind, key, index){
  const d = db();
  if (kind === 'voice') {
    const number = parseInt(String(key).replace(/^\D+/, ''), 10);
    return (d.voiceDb || []).find(item => Number(item.id) === number)
      || (window.RINA_VOICE_DATA || [])[index]
      || null;
  }
  if (kind === 'music') {
    return (d.musicDb || []).find(item => item.cover === key)
      || (window.RINA_MUSIC_DATA || []).find(item => item.cover === key || item.id === key)
      || null;
  }
  return (d.videoDb || []).find(item => item.cover === key || String(item.id) === String(key)) || null;
}
function mediaLabel(kind, key, index){
  const item = mediaAsset(kind, key, index);
  if (!item) return key;
  if (kind === 'voice') return key + ' - ' + (item.content || item.text || item.id || '');
  if (kind === 'music') return key + ' - ' + (item.title || item.name || item.id || '') + (item.artist || item.singer ? ' / ' + (item.artist || item.singer) : '');
  return key + ' - ' + (item.title || item.name || item.id || '');
}
function drawUnityModule(bits, key, sr, sc, h, w, flip){
  const mods = (db().faceModules || {});
  const bmp = mods[String(key)] || mods[key] || mods['0'];
  if (!bmp) return;
  for (let y=0; y<h; y++) for (let x=0; x<w; x++) {
    const sx = flip ? w - 1 - x : x;
    const rr = sr + y + LEGACY_ROW_OFFSET, cc = sc + x + LEGACY_COL_OFFSET;
    if (bmp[y] && bmp[y][sx] && isRealCell(rr, cc)) bits[bitIndex(rr, cc)] = 1;
  }
}
function unityFaceToBits(face){
  const bits = Array(ROWS * COLS).fill(0);
  face = face || {};
  drawUnityModule(bits, face.leye, 0, 0, 8, 8, false);
  drawUnityModule(bits, face.reye, 0, 10, 8, 8, false);
  drawUnityModule(bits, face.mouth, 8, 5, 8, 8, false);
  drawUnityModule(bits, face.cheek, 8, 14, 4, 4, false);
  drawUnityModule(bits, face.cheek, 8, 0, 4, 4, true);
  return bits;
}
function findTimelineIndex(tl, frame){ let best = -1; for (let i=0; i<tl.length; i++) { if ((tl[i].frame || 0) <= frame) best = i; else break; } return best; }
function currentMedia(){
  const kindEl = $('unityMediaKind');
  const selectEl = $('unityMediaSelect');
  const kind = kindEl ? (kindEl.value || 'voice') : 'voice';
  const key = selectEl ? (selectEl.value || '') : '';
  return {kind, key, timeline: timelineOf(kind, key)};
}
function updateMediaSelect(){
  const kindEl = $('unityMediaKind');
  const sel = $('unityMediaSelect');
  if (!kindEl || !sel) {
    debug('media select skipped', 'missing unityMediaKind or unityMediaSelect');
    return;
  }
  const kind = kindEl.value || 'voice';
  sel.innerHTML = '';
  mediaKeys(kind).forEach((key, index) => {
    const o = document.createElement('option');
    o.value = key;
    o.textContent = mediaLabel(kind, key, index);
    sel.appendChild(o);
  });
  chooseUnityMedia(false);
}
function applyUnityFrame(frame, send){
  const cur = currentMedia();
  const idx = findTimelineIndex(cur.timeline, frame || 0);
  if (idx < 0) return null;
  const bits = unityFaceToBits(cur.timeline[idx].face);
  renderBits($('unityMediaPreview'), bits, false);
  const hx = bitsToM370(bits);
  if (send && typeof window.sendText === 'function') sendText('M370:' + hx, false).catch(e => log('preview send failed: ' + e.message));
  const last = cur.timeline.length ? cur.timeline[cur.timeline.length - 1].frame || 0 : 0;
  $('unityMediaTime').textContent = Math.floor((frame || 0) / UNITY_FPS) + 's / ' + Math.floor(last / UNITY_FPS) + 's';
  return hx;
}
function chooseUnityMedia(send){
  stopUnityMedia(false);
  applyUnityFrame(0, send !== false);
  const cur = currentMedia();
  const selected = $('unityMediaSelect') ? $('unityMediaSelect').selectedIndex : 0;
  $('unityMediaInfo').textContent = JSON.stringify({
    kind: cur.kind,
    key: cur.key,
    label: mediaLabel(cur.kind, cur.key, selected),
    asset: mediaAsset(cur.kind, cur.key, selected),
    frames: cur.timeline.length
  }, null, 2);
}
function mediaSource(){
  const file = $('unityMediaFile').files && $('unityMediaFile').files[0];
  if (file) return URL.createObjectURL(file);
  return String($('unityMediaUrl').value || '').trim();
}
function showMediaElement(kind, url){
  const audio = $('unityMediaAudio'), video = $('unityMediaVideo');
  if (audio) { audio.pause(); audio.style.display = 'none'; }
  if (video) { video.pause(); video.style.display = 'none'; }
  if (!url) return null;
  const el = kind === 'video' ? video : audio;
  if (!el) return null;
  el.src = url;
  el.style.display = 'block';
  try { el.currentTime = 0; el.play().catch(()=>{}); } catch (_) {}
  return el;
}
async function sendFirmwareTimeline(cur, loop){
  const entries = [];
  let lastHex = '';
  for (const row of cur.timeline) {
    const hx = bitsToM370(unityFaceToBits(row.face));
    if (hx !== lastHex) { entries.push({frame: row.frame || 0, hex: hx}); lastHex = hx; }
  }
  const last = cur.timeline.length ? cur.timeline[cur.timeline.length - 1].frame || 0 : 0;
  const name = (cur.kind + ':' + cur.key).replace(/[|;,\r\n]/g, ' ').slice(0, 48);
  await sendText('timeline370Begin|' + UNITY_FPS + '|' + last + '|' + (loop ? '1' : '0') + '|' + entries.length + '|' + name, true);
  let chunk = '';
  for (const e of entries) {
    const part = String(e.frame) + ',' + e.hex + ';';
    if ((chunk + part).length > 1180) { await sendText('timeline370Chunk|' + chunk, true); chunk = ''; }
    chunk += part;
  }
  if (chunk) await sendText('timeline370Chunk|' + chunk, true);
  return {entries, last, name};
}
function stopUnityMedia(doFirmwareStop){
  if (mediaTimer) { clearInterval(mediaTimer); mediaTimer = null; }
  if (mediaElement) { try { mediaElement.pause(); } catch (_) {} }
  if (mediaBlobUrl && mediaBlobUrl.startsWith('blob:')) { try { URL.revokeObjectURL(mediaBlobUrl); } catch (_) {} }
  mediaElement = null; mediaBlobUrl = ''; mediaSilentFrame = 0; mediaLastFrame = 0; mediaToken++;
  if (doFirmwareStop !== false) sendText('runtimeStop|media', false).catch(e => log('停止媒体失败：' + e.message));
}
async function playUnityMedia(){
  const cur = currentMedia();
  if (!cur.timeline.length) { alert('没有时间轴数据'); return; }
  stopUnityMedia(false);
  const loop = !!$('unityMediaLoop').checked;
  const sent = await sendFirmwareTimeline(cur, loop);
  mediaBlobUrl = mediaSource();
  mediaElement = showMediaElement(cur.kind, mediaBlobUrl);
  mediaLastFrame = sent.last;
  const token = ++mediaToken;
  await sendText('timeline370Play', true);
  mediaTimer = setInterval(() => {
    if (token !== mediaToken) return;
    let frame = mediaElement && mediaBlobUrl && !mediaElement.paused ? Math.floor((mediaElement.currentTime || 0) * UNITY_FPS) : mediaSilentFrame++;
    if (frame > mediaLastFrame + 20 || (mediaElement && mediaBlobUrl && mediaElement.ended)) {
      if (loop) { mediaSilentFrame = 0; if (mediaElement && mediaBlobUrl) { try { mediaElement.currentTime = 0; mediaElement.play(); } catch (_) {} } frame = 0; }
      else { stopUnityMedia(true); return; }
    }
    applyUnityFrame(frame, false);
  }, Math.max(20, Math.floor(1000 / UNITY_FPS)));
  log('Unity 时间轴已发送：' + sent.entries.length + ' keyframes, ' + sent.name);
}

async function sendFaceLiteBinary(){ await sendHex([+$('leye').value, +$('reye').value, +$('mouth').value, +$('cheek').value].map(toByte).join(''), false); }
async function sendTextLite(){ const h = cleanHex($('textLiteHex').value).padEnd(32, '0').slice(0, 32); $('textLiteHex').value = h; await sendHex(h, false); }
async function sendFaceFullBinary(){ await sendHex(bitsToLegacyHex(gridBits), false); }
async function binaryRequest(value){
  const parts = String(value).split(':');
  $('binaryOut').textContent = await sendHex(parts[0], true, parts[1] || 'hex');
}

let wifiCanConfigure = false;
function applyWifiLock(){
  const readonly = !wifiCanConfigure;
  ['wifiSsid','wifiPassword','wifiApSsid','wifiApPassword','wifiApChannel','wifiSaveBtn','wifiApSaveBtn','wifiScanBtn'].forEach(id => { const el = $(id); if (el) el.disabled = readonly; });
  if ($('wifiReadonlyBanner')) $('wifiReadonlyBanner').style.display = readonly ? '' : 'none';
  if ($('wifiApReadonlyBanner')) $('wifiApReadonlyBanner').style.display = readonly ? '' : 'none';
}
async function wifiRefreshStatus(){
  const out = $('wifiStatusOut');
  out.textContent = '读取中...';
  try {
    const s = await apiJson('/api/wifi/status');
    wifiCanConfigure = !!s.can_configure;
    out.textContent = (s.sta_connected ? 'STA: 已连接 SSID=' + s.sta_ssid + ' IP=' + s.sta_ip : 'STA: 未连接') + '\nAP: ' + (s.ap_ssid_cfg || s.ap_ssid || 'RinaChanBoard-S3') + ' IP=' + (s.ap_ip || '192.168.4.1');
    $('wifiModeNote').textContent = wifiCanConfigure ? '当前通过 AP 热点访问，可修改 Wi-Fi。' : '当前不是 AP 配置模式，Wi-Fi 配置只读。';
    if (s.sta_ssid_cfg && !$('wifiSsid').value) $('wifiSsid').value = s.sta_ssid_cfg;
    if (s.ap_ssid_cfg && !$('wifiApSsid').value) $('wifiApSsid').value = s.ap_ssid_cfg;
    applyWifiLock();
  } catch (error) {
    out.textContent = '读取失败：' + error.message;
  }
}
async function wifiScan(){
  const box = $('wifiScanResults'), btn = $('wifiScanBtn');
  btn.disabled = true; btn.textContent = '扫描中...'; box.style.display = 'block'; box.textContent = '扫描中...';
  try {
    const data = await apiJson('/api/wifi/scan');
    const nets = data.networks || [];
    box.innerHTML = nets.length ? '' : '<span class="small">未发现网络</span>';
    nets.forEach(n => {
      const row = document.createElement('button');
      row.type = 'button'; row.className = 'btn'; row.style.margin = '2px'; row.textContent = n.ssid + '  ' + n.rssi + ' dBm';
      row.addEventListener('click', () => { $('wifiSsid').value = n.ssid; box.style.display = 'none'; $('wifiPassword').focus(); });
      box.appendChild(row);
    });
  } catch (error) { box.textContent = '扫描失败：' + error.message; }
  btn.disabled = false; btn.textContent = '扫描';
}
async function wifiSave(){
  if (!wifiCanConfigure) { alert('只能在连接到设备 AP 热点时修改 Wi-Fi。'); return; }
  const body = {
    ssid: $('wifiSsid').value.trim(),
    password: $('wifiPassword').value || '',
    ap_ssid: $('wifiApSsid').value.trim() || 'RinaChanBoard-S3',
    ap_password: $('wifiApPassword').value || '',
    ap_channel: $('wifiApChannel').value || '6'
  };
  try {
    const data = await apiJson('/api/wifi/save', {method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded'}, body:new URLSearchParams(body)});
    $('wifiSaveOut').textContent = JSON.stringify(data, null, 2);
  } catch (error) { $('wifiSaveOut').textContent = '保存失败：' + error.message; }
}
function wifiTogglePw(){
  const pw = $('wifiPassword'), btn = $('wifiPwToggle');
  pw.type = pw.type === 'password' ? 'text' : 'password';
  btn.textContent = pw.type === 'password' ? '显示' : '隐藏';
}

function fillSelectors(){
  const faces = window.RINA_FACES || {};
  makeOptions($('leye'), (faces.leye || []).length);
  makeOptions($('reye'), (faces.reye || []).length);
  makeOptions($('mouth'), (faces.mouth || []).length);
  makeOptions($('cheek'), (faces.cheek || []).length);
  const colors = $('presetColor');
  if (colors) {
    colors.innerHTML = '';
    (window.RINA_COLOR_INFO || []).forEach((c, i) => {
      const o = document.createElement('option');
      o.value = c.color; o.textContent = pad2(i) + ' ' + c.name + ' #' + c.color;
      colors.appendChild(o);
    });
  }
  const ch = $('wifiApChannel');
  if (ch) for (let i=1; i<=13; i++) { const o = document.createElement('option'); o.value = String(i); o.textContent = String(i); if (i === 6) o.selected = true; ch.appendChild(o); }
  updateMediaSelect();
}
function bind(){
  $('host').textContent = location.host || 'local file';
  $('ipInput').value = location.hostname || '192.168.4.1';
  on('openIp', 'click', 'openIp', () => { const ip = $('ipInput').value.trim(); if (ip) location.href = 'http://' + ip + '/'; });
  on('clearDebugLog', 'click', 'clearDebugLog', () => { const box = $('debugLog'); if (box) box.textContent = ''; });
  onAll('[data-tab]', 'click', 'tab', (ev, btn) => {
    qa('[data-tab]').forEach(b => b.classList.remove('active'));
    qa('.tab').forEach(t => t.classList.remove('show'));
    btn.classList.add('active'); $(btn.dataset.tab).classList.add('show');
    if (btn.dataset.tab === 'tab-wifi') wifiRefreshStatus();
  });
  on('refreshStatus', 'click', 'refreshStatus', updateStatus);
  on('readVersion', 'click', 'readVersion', requestVersion);
  on('readEspStatus', 'click', 'readEspStatus', requestEspStatus);
  on('manualModeToggle', 'click', 'manualModeToggle', toggleManualMode);
  on('manualModeRefresh', 'click', 'manualModeRefresh', requestManualMode);
  on('colorPick', 'input', 'colorPick', () => { $('colorHex').value = $('colorPick').value.slice(1); });
  on('usePresetColor', 'click', 'usePresetColor', () => { $('colorHex').value = $('presetColor').value; $('colorPick').value = '#' + $('presetColor').value; return uploadColor(); });
  on('uploadColor', 'click', 'uploadColor', uploadColor);
  on('downloadColor', 'click', 'downloadColor', downloadColor);
  on('uploadBright', 'click', 'uploadBright', uploadBright);
  on('downloadBright', 'click', 'downloadBright', downloadBright);
  onAll('[data-bright]', 'click', 'brightPreset', (ev, btn) => { $('bright').value = btn.dataset.bright; return uploadBright(); });
  on('readBattery', 'click', 'readBattery', requestBatteryJson);
  on('autoSync', 'click', 'autoSync', autoSyncAll);
  on('clearFace', 'click', 'clearFace', () => setEditorBits(Array(ROWS * COLS).fill(0)));
  on('invertFace', 'click', 'invertFace', () => setEditorBits(gridBits.map((b, i) => isRealCell(Math.floor(i / COLS), i % COLS) ? (b ? 0 : 1) : 0)));
  on('uploadFace', 'click', 'uploadFace', uploadFace);
  on('downloadFace', 'click', 'downloadFace', downloadFace);
  on('loadHexToEditor', 'click', 'loadHexToEditor', () => setColorsByString($('faceHex').value));
  on('sendLegacyBinary', 'click', 'sendLegacyBinary', sendFaceFullBinary);
  ['leye','reye','mouth','cheek'].forEach(id => on(id, 'change', id + 'Change', () => { if (id === 'leye' && $('eyeSyncBox').checked) $('reye').value = $('leye').value; faceFromSelectors(); }));
  on('buildFace', 'click', 'buildFace', faceFromSelectors);
  on('uploadPartFace', 'click', 'uploadPartFace', () => { faceFromSelectors(); return uploadFace(); });
  on('randomPartBtn', 'click', 'randomPart', () => randomizeParts(false));
  on('randomUploadPartBtn', 'click', 'randomUploadPart', () => randomizeParts(true));
  on('sendFaceLiteBinary', 'click', 'sendFaceLiteBinary', sendFaceLiteBinary);
  on('reloadFaces', 'click', 'reloadFaces', loadFaces);
  on('saveCurrentFace', 'click', 'saveCurrentFace', addCurrentFace);
  on('savedFaces', 'change', 'savedFacesChange', () => { selectedFaceIndex = +$('savedFaces').value || 0; renderSavedFaces(); });
  on('loadCustomFace', 'click', 'loadCustomFace', loadSelectedFace);
  on('renameCustomFace', 'click', 'renameCustomFace', renameSelectedFace);
  on('toggleLockFace', 'click', 'toggleLockFace', toggleSelectedLock);
  on('deleteCustomFace', 'click', 'deleteCustomFace', deleteSelectedFace);
  on('previewScrollText', 'click', 'previewScrollText', previewScrollText);
  on('startScrollText', 'click', 'startScrollText', startScrollText);
  on('stopScrollText', 'click', 'stopScrollText', () => stopScrollText(true));
  on('unityMediaKind', 'change', 'unityMediaKind', updateMediaSelect);
  on('chooseUnityMedia', 'click', 'chooseUnityMedia', () => chooseUnityMedia(true));
  on('playUnityMedia', 'click', 'playUnityMedia', playUnityMedia);
  on('stopUnityMedia', 'click', 'stopUnityMedia', () => stopUnityMedia(true));
  onAll('[data-binary-request]', 'click', 'binaryRequest', (ev, btn) => binaryRequest(btn.dataset.binaryRequest));
  on('sendTextLite', 'click', 'sendTextLite', sendTextLite);
  on('sendRawHex', 'click', 'sendRawHex', () => sendHex($('rawHex').value, false));
  on('sendRawHexWait', 'click', 'sendRawHexWait', () => sendHex($('rawHex').value, true));
  on('wifiRefreshStatus', 'click', 'wifiRefreshStatus', wifiRefreshStatus);
  on('wifiScanBtn', 'click', 'wifiScan', wifiScan);
  on('wifiSaveBtn', 'click', 'wifiSave', wifiSave);
  on('wifiApSaveBtn', 'click', 'wifiApSave', wifiSave);
  on('wifiPwToggle', 'click', 'wifiTogglePw', wifiTogglePw);
}
function init(){
  fillSelectors();
  bind();
  renderEditor();
  renderPartGalleries();
  renderBits($('scrollPreview'), Array(ROWS * COLS).fill(0), false);
  $('dbInfo').textContent = JSON.stringify({
    ascii: (db().ascii || []).length,
    faceModules: Object.keys(db().faceModules || {}).length,
    voiceTimelines: Object.keys(db().voiceTimelines || {}).length,
    musicTimelines: Object.keys(db().musicTimelines || {}).length,
    videoTimelines: Object.keys(db().videoTimelines || {}).length
  }, null, 2);
  loadFaces();
  updateStatus();
  statusTimer = setInterval(updateStatus, 5000);
  requestManualMode().catch(()=>{});
  log('Web UI ready');
}

Object.assign(window, {
  sendText, sendHex, req, log, debug, setColorsByString, clearFace: () => setEditorBits(Array(ROWS * COLS).fill(0)),
  invertFace: () => setEditorBits(gridBits.map((b, i) => isRealCell(Math.floor(i / COLS), i % COLS) ? (b ? 0 : 1) : 0)),
  uploadFace, downloadFace, uploadColor, downloadColor, uploadBright, downloadBright, requestVersion,
  requestEspStatus, requestBatteryJson, autoSyncAll, faceFromSelectors, sendFaceLiteBinary,
  sendTextLite, sendFaceFullBinary, startScrollText, stopScrollText, previewScrollText,
  chooseUnityMedia, playUnityMedia, stopUnityMedia, wifiRefreshStatus, wifiScan, wifiSave, wifiTogglePw,
  requestManualMode, setManualMode, toggleManualMode
});

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init, {once:true});
else init();
})();
// APP_RUNTIME_END
`.replace('__DEFAULT_FACES__', JSON.stringify(bundledDefaultFaces));

const output = [
  '<!doctype html>',
  '<html lang="zh-CN">',
  '<head>',
  '  <meta charset="utf-8">',
  '  <meta name="viewport" content="width=device-width,initial-scale=1">',
  '  <title>RinaChanBoard Web UI</title>',
  '  <style>' + css.trim() + '</style>',
  '</head>',
  '<body>',
  body.trim(),
  '<script>',
  localHelper.trim(),
  '// DATA_BUNDLE_BEGIN',
  dataBlock,
  '// DATA_BUNDLE_END',
  '// UNITY_DB_BEGIN',
  unityBlock,
  '// UNITY_DB_END',
  appRuntime.trim(),
  '</script>',
  '</body>',
  '</html>',
  ''
].join('\n');

fs.writeFileSync(htmlPath, output, 'utf8');
console.log('rebuilt ' + htmlPath + ' bytes=' + Buffer.byteLength(output));
