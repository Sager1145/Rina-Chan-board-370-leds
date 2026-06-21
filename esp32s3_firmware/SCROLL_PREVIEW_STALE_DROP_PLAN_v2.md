# 滚动预览 STALE / DROPPED 补丁计划 v2（已对照现有代码修正）

本版相对原计划的核心变化：**不新增与现有函数重复的入口**，改为复用 `app.js` 已有的
`setScrollPreviewFrame()` / `resetScrollControlsAfterButton()` / `clearRecoveredScrollCache()` /
`loadStaticFramePreviewFromFirmware()` / `restoreScrollTextFromFirmware()`，只补真正缺失的语义
（STALE / DROPPED、传输失败计数、断连防假播放）。

所有行号对应当前 `data/app.js`（12,213 行）。

---

## 0. 必须保留的现有强逻辑（不动）

文字滚动同步继续以 `/api/preview_sync` → `recordPresentedSyncSample()`（9479）为准：
presented frame/seq/atUs 回归估算实际 fps，`nextPreviewDelayMs()`（9554）做 slew-limited 调速，
不跳帧、不补帧。`scrollMachine`（3719）的 phase / pauseReasons / epoch / gen / token 全部保留。

---

## 1. 复用映射表（本版最重要的一节）

| 原计划新增函数 | 现有等价物 | 处理方式 |
| --- | --- | --- |
| `applyStaticPreviewFrame(frame, reason)` | `setScrollPreviewFrame(frame, reason, playback)` (5734) | **复用**，给它加 `opts.syncLiveBaseline`，静态预览传 `playback=null` |
| `clearScrollPreviewCache(reason)` | `resetScrollControlsAfterButton(reason)` (9793) + `clearRecoveredScrollCache(reason)` (5053) | **复用**，DROPPED 即“等同 Stop/Clear 的终态清理” |
| 静态 fallback 帧获取主体 | `loadStaticFramePreviewFromFirmware(reason)` (6420) | **复用**，已含 live-scroll 守卫 + render |
| `scheduleStaticFrameReloadFromFirmware()` | `refreshFaceLibraryFromFirmware()` in-flight 模式 (7990) | **保留**（沿用同一 `xxxInFlight=promise.finally(()=>null)` 写法） |
| `scheduleScrollDropRecovery()` | 同上 in-flight 模式 + `restoreScrollTextFromFirmware()` | **保留**，但**不要**用 `kickPostBootScrollMetaRestore()`（见 §6.3） |
| `stopScrollPreviewTimer()` | 无命名 helper，仅 ~10 处内联 `clearInterval(scroll.timer)` | **新增并替换内联点**（顺带修 setTimeout/clearInterval 不一致） |
| `markPreviewSyncOk/Failed()` | 无 | **新增** |
| `enterScrollPreviewStale/Dropped()` | 无 | **新增** |

> 不要新增 `applyStaticPreviewFrame` 和 `clearScrollPreviewCache` 这两个名字；它们会与上表左列重复。

---

## 2. 要修的 4 个缺口（不变）

| # | 缺口 | 当前问题 | 修复 |
| -: | --- | --- | --- |
| 1 | faceIndex fallback | `applyFirmwareRuntimeState()` 5267–5277 只有 `if (face)` 无 `else` | cache miss 时 `scheduleStaticFrameReloadFromFirmware()` |
| 2 | preview sync 传输失败 | `pollPreviewSyncOnce()` 9596 失败只 `return null` | 连续失败计数 → `STALE` |
| 3 | 断连假播放 | `previewTickLoop()` 9568 只看 `active/paused` | stale/dropped 停 timer |
| 4 | identity mismatch | `recordPresentedSyncSample()` 9496/9501 只 `return` | timeline mismatch 立即 `DROPPED`；frameCount mismatch 收敛后才 drop（见 §5.4） |

仅改 `data/app.js`。状态文案复用现有 `scroll-restore-warning` 元素（见 §8），不改 HTML 结构。

---

## 3. 改动一：faceIndex 静态 fallback（复用现有函数）

### 3.1 新增 in-flight 守卫（沿用 7990 的写法）

```js
let staticFrameReloadInFlight = null;
function scheduleStaticFrameReloadFromFirmware(reason = "static_frame_reload") {
  if (staticFrameReloadInFlight) return staticFrameReloadInFlight;
  staticFrameReloadInFlight = loadStaticFramePreviewFromFirmware(reason)
    .catch((err) => {
      logScrollRestoreDebug("static frame reload failed", {
        reason, error: err?.message || String(err),
      });
      return false;
    })
    .finally(() => { staticFrameReloadInFlight = null; });
  return staticFrameReloadInFlight;
}
```
`loadStaticFramePreviewFromFirmware()`（6420）已经写 `currentFrame/scrollFrame`、`syncLiveSendBaseline`、
`renderMatrices()`、`updatePackedFrameViews()`，并在 `state.textScrollActive || scroll.firmwareBacked` 时直接
`return false`——所以**不需要**再写 `applyStaticPreviewFrame`。

### 3.2 给 `setScrollPreviewFrame()` 加一个可选 live-baseline（最小改动）

```js
function setScrollPreviewFrame(frame, reason = "text_scroll_preview", playback = "scroll", opts = {}) {
  scrollFrame = cloneFrame(frame);
  currentFrame = cloneFrame(frame);
  if (opts.syncLiveBaseline && liveSendEnabled) syncLiveSendBaseline(currentFrame);
  state.lastRefreshReason = reason;
  state.refreshCount++;
  if (playback !== null) state.playback = playback;
  updateDps();
  renderMatrices();
  renderState();
  updatePackedFrameViews();
}
```
现有三个调用点（5734 定义、9789 `resetScrollPreviewToFirstFrame`）行为不变（`opts` 默认空）。

### 3.3 改 faceIndex 分支（5267–5277）

```js
if (!skipFrame && !firmwareIsScrolling && faceChanged) {
  const face = getAllFaces()[state.faceIndex];
  if (face && Array.isArray(face.frameBytes)) {
    setScrollPreviewFrame(
      faceFrame(face),
      renderer.lastReason || data.lastReason || source || "face_index_sync",
      null,                         // 表情切换不改 playback
      { syncLiveBaseline: true },
    );
    frameChanged = false;           // setScrollPreviewFrame 已 render
    stateChanged = true;
  } else {
    scheduleStaticFrameReloadFromFirmware("face_index_cache_miss");
  }
}
```
主路径仍优先用本地 saved_faces；只有 cache miss 才读 `/api/frame/current`。

---

## 4. 改动二：在现有 `scrollMachine` 上补 STALE / DROPPED

### 4.1 scroll 字段初始化（3622 字面量里补，避免依赖 undefined）

```js
previewStale: false,
previewDropped: false,
staleReason: "",
dropReason: "",
```

### 4.2 `setPhase()`（3751）

```js
function setPhase(next) {
  machine.state = next;
  scroll.restoring = next === "RESTORING";
  scroll.uploading = next === "UPLOADING" || scroll.uploading;
  scroll.previewStale = next === "STALE";
  scroll.previewDropped = next === "DROPPED";
  scroll.active =
    next === "ACTIVE" && machine.pauseReasons.size === 0 &&
    !scroll.previewStale && !scroll.previewDropped;
  if (next === "IDLE" || next === "STALE" || next === "DROPPED") scroll.active = false;
}
```

> **重要（来自代码核对）：** `scroll.active` 还有两个直接写入点——`applyFirmwareRuntimeState` 5188
> 与 `applyScrollMetaRuntime` 10682——它们不看 `previewStale`，会在下一次轮询把 `scroll.active`
> 重新置回。因此 **`setPhase` 的 `scroll.active` 门控不是真正的防线**，真正生效的是 §7 的 timer 级守卫。
> 实施时须接受“STALE 期间 `scroll.active` 可能被轮询置真”，并把 UI 的 `scrollPlayingNow`
> 也用 `previewStale/previewDropped` 兜底（见 §8）。

### 4.3 `ALLOWED_FROM`（3821）新增

```js
SYNC_STALE: ["ACTIVE", "STEPPING", "RESTORING"],
FW_SYNC_RECOVERED: ["STALE"],
IDENTITY_MISMATCH: null,
DROP_DONE: ["DROPPED"],
```

### 4.4 `dispatch()`（3846 switch）新增 case

```js
case "SYNC_STALE":
  enterScrollPreviewStale(payload.reason || "preview_sync_stale");
  setPhase("STALE");
  break;
case "FW_SYNC_RECOVERED":
  scroll.previewStale = false;
  scroll.syncState = "observe";
  setPhase(machine.device.hasSession ? "ACTIVE" : "IDLE");
  syncPauseBacking();
  break;
case "IDENTITY_MISMATCH":
  enterScrollPreviewDropped(payload.reason || "preview_identity_mismatch");
  setPhase("DROPPED");
  break;
case "DROP_DONE":
  scroll.previewDropped = false;
  setPhase(payload && payload.restore ? "RESTORING" : "IDLE");
  break;
```

---

## 5. 改动三/四：传输失败计数 + identity mismatch

### 5.1 计数字段（poller 附近，9586 一带）

```js
const PREVIEW_SYNC_TRANSPORT_FAIL_LIMIT = 3;
const PREVIEW_SYNC_STALE_MS = 5000;
let previewSyncTransportFailCount = 0;
let previewSyncLastOkMs = 0;
let previewSyncLastFailReason = "";
```

### 5.2 成功 / 失败标记

```js
function markPreviewSyncOk(payload = {}) {
  previewSyncTransportFailCount = 0;
  previewSyncLastOkMs = performance.now();
  previewSyncLastFailReason = "";
  if (scroll.previewStale) {
    snapPreviewToFirmwareFrame(
      Number(payload.presentedFrameIndex ?? payload.frameIndex),
      "preview_sync_recovered",
    );
    scroll.previewTargetSpeedMultiplier = 1;
    scroll.previewSpeedMultiplier = 1;
    scroll.syncState = "observe";
    scrollMachine.dispatch("FW_SYNC_RECOVERED", payload);
    restartScrollPreviewTimer();
  }
}

function markPreviewSyncTransportFailed(reason = "preview_sync_failed") {
  previewSyncTransportFailCount++;
  previewSyncLastFailReason = reason;
  const now = performance.now();
  const staleByCount = previewSyncTransportFailCount >= PREVIEW_SYNC_TRANSPORT_FAIL_LIMIT;
  const staleByAge = previewSyncLastOkMs > 0 && now - previewSyncLastOkMs >= PREVIEW_SYNC_STALE_MS;
  if (staleByCount || staleByAge) scrollMachine.dispatch("SYNC_STALE", { reason });
}
```

### 5.3 `pollPreviewSyncOnce()`（9596）接计数

被 busy（`firmwareFullStatusInFlight || scrollMetaFetchInFlight || scroll.uploading || scroll.startBusy`）
跳过的 poll **不计失败**（保持现有 9599–9604 提前 return）。只有 HTTP/timeout/`invalid` 计失败：

```js
try {
  const payload = await apiGet(API_ENDPOINTS.previewSync, { timeoutMs: API_GET_TIMEOUT_MS });
  if (!payload || payload.ok === false || !payload.valid) {
    markPreviewSyncTransportFailed("invalid_preview_sync_payload");
    return null;
  }
  const accepted = recordPresentedSyncSample(payload, {
    excludeFromRate: !!options.excludeFromRate,
    forceSnap: !!options.forceSnap,
  });
  if (accepted !== false) markPreviewSyncOk(payload);
  return payload;
} catch (err) {
  if (shouldLogApiError()) {
    logScrollRestoreDebug("preview sync failed", { error: err?.message || String(err) });
  }
  markPreviewSyncTransportFailed("preview_sync_transport_error");
  return null;
}
```

### 5.4 `recordPresentedSyncSample()`（9479）返回值语义 + 收敛防抖

返回 `true`=有效 / `undefined`=普通不可用 / `false`=必须 drop。

**timeline mismatch（9496）= 立即 drop**（身份不同，无歧义）：
```js
if (scroll.framesTimelineId && timelineId && scroll.framesTimelineId !== timelineId) {
  resetFirmwareScrollRate();
  scrollMachine.dispatch("IDENTITY_MISMATCH", {
    reason: "preview_sync_timeline_mismatch",
    localTimelineId: scroll.framesTimelineId, firmwareTimelineId: timelineId,
  });
  return false;
}
```

**frameCount mismatch（9501）—— 不要无条件立即 drop。** 代码核对发现：RESTORING 期间本地
`scroll.frames` 正在重建，`applyFirmwareCursor` 的 busy 守卫（3771）只挡 GENERATING/UPLOADING/STARTING，
**不挡 RESTORING**，此时 count 短暂不等会触发 drop→recovery→drop 抖动。改为只在“身份本应已绑定”时才 drop：
```js
const sameTimeline = !timelineId || scroll.framesTimelineId === timelineId;
const identityBound = scrollMachine.snapshot().cache.identityBound;
if (!scroll.frames.length || frameCount !== scroll.frames.length) {
  if (sameTimeline && identityBound && machine_is_active_or_stepping()) {
    resetFirmwareScrollRate();
    scrollMachine.dispatch("IDENTITY_MISMATCH", {
      reason: "preview_sync_frame_count_mismatch",
      localFrameCount: scroll.frames.length, firmwareFrameCount: frameCount,
    });
    return false;
  }
  return; // 重建/过渡窗口：保持原有的良性 return，不升级为 drop
}
```
（`machine_is_active_or_stepping()` 用 `scrollMachine.snapshot().state` 判断 `ACTIVE`/`STEPPING`；
`identityBound` 已由 `RESTORE_DONE` 的 `deriveIdentityBound` 维护，见 3909。）

---

## 6. STALE / DROPPED 入口与恢复（复用现有清理函数）

### 6.1 `stopScrollPreviewTimer()`（新增，并替换内联点）

```js
function stopScrollPreviewTimer() {
  if (scroll.timer) { clearTimeout(scroll.timer); clearInterval(scroll.timer); }
  scroll.timer = null;
}
```
替换以下内联 `clearInterval(scroll.timer); scroll.timer=null`：5828、6583、9795、10077、10157、
10202、10223、10330、10689（消除 setTimeout/clearInterval 不一致）。

### 6.2 `enterScrollPreviewStale()`

```js
function enterScrollPreviewStale(reason = "preview_sync_stale") {
  scroll.previewStale = true;
  scroll.syncState = "stale";
  scroll.staleReason = reason;
  stopScrollPreviewTimer();
  logScrollRestoreDebug("scroll preview stale", {
    reason, failCount: previewSyncTransportFailCount, lastOkMs: previewSyncLastOkMs,
  });
  updateScrollUi();
  renderState();
}
```

### 6.3 `enterScrollPreviewDropped()`（复用 `resetScrollControlsAfterButton`）

DROPPED 的“清掉不可信本地缓存”与现有“GPIO/按钮停止 = 等同 Stop/Clear”是同一语义。
直接复用 `resetScrollControlsAfterButton()`（9793，已清 frames/signature/timeline/framesTimelineId、
`clearRecoveredScrollCache`、`resetScrollUploadProgress`、停 timer、render），**不要**新写
`clearScrollPreviewCache`：

```js
function enterScrollPreviewDropped(reason = "preview_identity_mismatch") {
  resetFirmwareScrollRate();
  scroll.dropReason = reason;
  resetScrollControlsAfterButton(reason, { preserveCurrentFrame: false }); // 清缓存+停timer+render
  scroll.previewDropped = true;   // 在 reset 之后置位（reset 不动这个新字段）
  scroll.previewStale = false;
  scroll.syncState = "dropped";
  updateScrollUi();
  scheduleScrollDropRecovery(reason);
}
```

### 6.4 `scheduleScrollDropRecovery()`（沿用 in-flight 模式，但用 `restoreScrollTextFromFirmware`）

```js
let scrollDropRecoverInFlight = null;
function scheduleScrollDropRecovery(reason = "scroll_preview_dropped") {
  if (scrollDropRecoverInFlight) return scrollDropRecoverInFlight;
  scrollDropRecoverInFlight = (async () => {
    const ok = await syncRuntimeSummaryFromFirmware(`${reason}_status`);
    if (ok && state.textScrollActive) {
      scrollMachine.dispatch("DROP_DONE", { restore: true });
      // 不用 kickPostBootScrollMetaRestore()：它有 postBootScrollMetaRestoreStarted 一次性闩锁
      // (10941)，boot 后第二次 drop 不会再恢复。直接调底层恢复：
      await restoreScrollTextFromFirmware(`${reason}_restore`, { autoPreview: true });
      return true;
    }
    scrollMachine.dispatch("DROP_DONE", { restore: false });
    await loadStaticFramePreviewFromFirmware(`${reason}_reload_current_frame`);
    return true;
  })()
    .catch((err) => {
      logScrollRestoreDebug("scroll drop recovery failed", {
        reason, error: err?.message || String(err),
      });
      return false;
    })
    .finally(() => { scrollDropRecoverInFlight = null; });
  return scrollDropRecoverInFlight;
}
```

---

## 7. 断连防假播放（timer 级守卫——真正的防线）

### 7.1 `previewTickLoop()`（9568）：顶部早退 + 回调守卫

```js
function previewTickLoop() {
  if (scroll.previewStale || scroll.previewDropped) return; // 顶部早退，避免空挂 timer
  scroll.timer = setTimeout(() => {
    scroll.timer = null;
    if (!scroll.active || scroll.paused || scroll.previewStale || scroll.previewDropped) return;
    advanceScroll(false);
    if (!scroll.active || scroll.paused || scroll.previewStale || scroll.previewDropped) return;
    previewTickLoop();
  }, nextPreviewDelayMs());
}
```
覆盖直接调用点 6592（visibilitychange resume）。

### 7.2 `restartScrollPreviewTimer()`（9577）

```js
function restartScrollPreviewTimer() {
  stopScrollPreviewTimer();
  if (scroll.active && !scroll.paused && !scroll.previewStale && !scroll.previewDropped) {
    previewTickLoop();
  }
}
```
覆盖 9664/10117/10205/10240/10286/10629 全部 restart 调用点。

---

## 8. UI 状态提示（复用现有元素，不调用不存在的 setScrollStatus）

> 代码核对：**不存在 `setScrollStatus()`**。状态文字是 `updateScrollUi()`（11337）里算出的 `label`
> 经 `setDomTextIfChanged(stateEl, label)`（11389）写入；另有 `scroll-restore-warning` 元素
> 由 `scroll.restoreWarning` 驱动（11448–11452）。

在 `updateScrollUi()` 中：

1. `scrollPlayingNow`（11365）兜底加 `&& !scroll.previewStale && !scroll.previewDropped`
   （否则 §4.2 提到的 `scroll.active` 被轮询置真会误显示 playing）。
2. 文案复用 `scroll-restore-warning`：
```js
const previewNotice = scroll.previewDropped
  ? "文字滚动预览缓存已失效：正在重新同步硬件状态"
  : scroll.previewStale
    ? "预览可能不同步：正在等待硬件重新同步"
    : "";
if (restoreWarnEl) {
  const msg = previewNotice || scroll.restoreWarning || "";
  setDomTextIfChanged(restoreWarnEl, msg);
  restoreWarnEl.hidden = !msg;
}
```
3. 按钮（沿用现有 `applyScrollButtonUiState` 计算式，叠加门控）：

| 状态 | 发送 | 暂停/继续 | 停止/清屏 | 左右逐格 |
| --- | ---: | ---: | ---: | ---: |
| STALE | 可用 | 禁用 | 可用 | 禁用 |
| DROPPED | 禁用 | 禁用 | 可用 | 禁用 |

实现：`pause`/`step` 的 `disabled` 追加 `|| scroll.previewStale || scroll.previewDropped`；
`send` 追加 `|| scroll.previewDropped`；`stop` 保持 `!hasFrameCache` 原逻辑（STALE 时仍有 cache → 可用）。

---

## 9. 发送前清预览（整合进现有 send 流程，不新增重复函数）

现有发送路径 10077 已 `clearInterval(scroll.timer); scroll.timer=null`，10092 调
`resetScrollPreviewToFirstFrame()`。只需在 send 入口把 stale/dropped 复位并改用统一停 timer：

```js
// 发送入口（GENERATE 之后、上传之前）：
stopScrollPreviewTimer();
scroll.previewStale = false;
scroll.previewDropped = false;
scroll.syncState = "uploading";
scrollFrame = blankFrame();
renderMatrices();
```
不再单列 `clearScrollPreviewBeforeUpload()`（与既有 send 初始化重叠）。
固件 `START_CONFIRMED` 后再 `pollPreviewSyncOnce({ force:true, forceSnap:true })`，然后
`restartScrollPreviewTimer()`。

---

## 10. 不要做（含本次核对新增项）

- 不要新增 `applyStaticPreviewFrame` / `clearScrollPreviewCache`——与 `setScrollPreviewFrame` /
  `resetScrollControlsAfterButton` 重复。
- 不要用 `kickPostBootScrollMetaRestore()` 做 drop 恢复——一次性闩锁，boot 后失效。
- 不要 `setScrollStatus(...)`——不存在；用 `scroll-restore-warning`。
- 不要靠 `setPhase` 的 `scroll.active` 门控当防线——有 5188/10682 直写覆盖；timer 守卫才是防线。
- 不要 preview_sync 失败一次就 drop（先 STALE 冻结）。
- 不要 frameCount mismatch 无条件立即 drop（先确认 timeline 相同且 identityBound，否则良性 return）。
- 不要新建第二套状态机（沿用 `scrollMachine`）。

---

## 11. 提交拆分（修正依赖顺序）

1. `webui: reuse setScrollPreviewFrame for face-index cache-miss fallback`
   —— §3：`setScrollPreviewFrame` 加 `opts.syncLiveBaseline`、`scheduleStaticFrameReloadFromFirmware`、faceIndex 分支 else。
2. `webui: add stopScrollPreviewTimer and unify scroll.timer teardown`
   —— §6.1 + 替换内联 clearInterval 点（独立、低风险、先落）。
3. `webui: add STALE/DROPPED phases to scrollMachine`
   —— §4 + §6.2 `enterScrollPreviewStale` + §6.3 `enterScrollPreviewDropped`（依赖 commit 2）。
4. `webui: stop preview on preview_sync transport failure`
   —— §5.1–5.3 计数 + `markPreviewSyncOk/Failed` + `pollPreviewSyncOnce` 接线（依赖 commit 3）。
5. `webui: drop stale scroll cache on identity mismatch + recovery`
   —— §5.4 返回值语义 + §6.4 `scheduleScrollDropRecovery`（依赖 commit 3）。
6. `webui: guard preview timer + UI notice against fake-play offline`
   —— §7 timer 守卫 + §8 UI + §9 send 复位（依赖 commit 2/3）。

---

## 12. 验收（与原计划一致，新增防抖项）

- faceIndex cache miss → fallback `/api/frame/current`；命中 → 本地 saved_faces 解码。
- 发送：先清预览不抢播，`START_CONFIRMED` 后 forceSnap 再起 timer；只调速不跳帧。
- preview_sync 连续失败/超时 → STALE，停 timer，保留 `scroll.frames`；重连同 timeline → 自动恢复。
- timeline mismatch → 立即 DROPPED 清缓存；frameCount mismatch 仅在 identityBound+同 timeline 才 drop，
  RESTORING 过渡窗口不抖动。
- 断连后本地预览不再无限假播放；固件转静态 → 清滚动缓存读 `/api/frame/current`。
