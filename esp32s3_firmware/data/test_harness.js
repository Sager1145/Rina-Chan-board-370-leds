/* =============================================================================
 * test_harness.js -- WebUI test instrumentation + live-output safety shim.
 *
 * This file is loaded by index.html after app.js. It keeps a small __ui helper for
 * browser-driven tests and installs a production safety shim for 6.2/6.3 live LED
 * output.
 *
 * Live-output rule:
 * - A 6.2 LED click in realtime mode must behave like pressing Send once.
 * - If the board is still in the same custom/parts manual output context, publish
 *   the changed frame without clearing first (diff/re-sync path).
 * - If another playback context is active, first publish a blank live frame, then
 *   publish the complete edited frame so scroll/auto/previous output cannot leak
 *   into the new custom frame.
 * ========================================================================== */
(function () {
  "use strict";
  if (window.__ui) return;

  var SELECTOR = [
    "button",
    "a[href]",
    "input:not([type=hidden])",
    "select",
    "textarea",
    "summary",
    '[role="button"]',
    '[role="menuitem"]',
    "[data-gpio]",
  ].join(",");
  var registry = new Map();
  var usedCodes = new Set();
  var badgesOn = false;
  var badgeLayer = null;
  var debounceTimer = 0;

  function slug(s) {
    return String(s || "")
      .trim()
      .toLowerCase()
      .replace(/\s+/g, "-")
      .replace(/[^a-z0-9\-_]/g, "")
      .replace(/-+/g, "-")
      .replace(/^-|-$/g, "")
      .slice(0, 40);
  }

  function pageOf(el) {
    var sec = el && el.closest && el.closest("section.page, section[id]");
    return sec && sec.id ? sec.id : "";
  }

  function labelOf(el) {
    if (!el) return "";
    var text =
      el.getAttribute("aria-label") ||
      el.getAttribute("title") ||
      (el.tagName === "INPUT" || el.tagName === "TEXTAREA"
        ? el.getAttribute("placeholder") || el.getAttribute("name") || ""
        : "") ||
      (el.textContent || "").replace(/\s+/g, " ").trim() ||
      el.value ||
      "";
    return String(text).slice(0, 80);
  }

  function codeFor(testid) {
    var h = 5381;
    for (var i = 0; i < testid.length; i++) h = ((h << 5) + h + testid.charCodeAt(i)) >>> 0;
    var code = 1000 + (h % 9000);
    while (usedCodes.has(code)) code = 1000 + ((code + 1 - 1000) % 9000);
    usedCodes.add(code);
    return code;
  }

  function deriveTestid(el) {
    if (el.id) return el.id;
    if (el.getAttribute("data-gpio")) return "gpio-" + el.getAttribute("data-gpio");
    var parts = [el.tagName.toLowerCase()];
    var page = pageOf(el);
    if (page) parts.push(page.replace(/^page-/, ""));
    var s = slug(labelOf(el));
    if (s) parts.push(s);
    var base = parts.join("-") || "ctl";
    var testid = base;
    var n = 2;
    while (registry.has(testid) && registry.get(testid).el !== el) testid = base + "-" + n++;
    return testid;
  }

  function tag(el) {
    if (!el || !el.setAttribute) return;
    if (el.__uiTestid && registry.has(el.__uiTestid) && registry.get(el.__uiTestid).el === el) return;
    var testid = el.getAttribute("data-testid") || deriveTestid(el);
    var code = el.getAttribute("data-test-code")
      ? parseInt(el.getAttribute("data-test-code"), 10)
      : codeFor(testid);
    el.setAttribute("data-testid", testid);
    el.setAttribute("data-test-code", String(code));
    el.__uiTestid = testid;
    registry.set(testid, { code: code, el: el });
  }

  function scan() {
    var nodes = document.querySelectorAll(SELECTOR);
    for (var i = 0; i < nodes.length; i++) {
      try { tag(nodes[i]); } catch (_) {}
    }
    if (badgesOn) renderBadges();
  }

  function visible(el) {
    return !!(el && (el.offsetParent || el.getClientRects().length) && !el.hasAttribute("hidden"));
  }

  function entry(el) {
    var r = el.getBoundingClientRect();
    return {
      code: parseInt(el.getAttribute("data-test-code"), 10),
      testid: el.getAttribute("data-testid"),
      label: labelOf(el),
      tag: el.tagName.toLowerCase(),
      type: el.getAttribute("type") || el.getAttribute("role") || el.getAttribute("data-gpio") || "",
      page: pageOf(el),
      visible: visible(el),
      disabled: !!el.disabled || el.getAttribute("aria-disabled") === "true",
      value:
        el.tagName === "INPUT" && el.type === "checkbox"
          ? !!el.checked
          : "value" in el
            ? el.value
            : undefined,
      rect: { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) },
    };
  }

  function resolve(ref) {
    if (ref == null) return null;
    var asString = String(ref);
    if (/^\d+$/.test(asString)) {
      var code = parseInt(asString, 10);
      for (var en of registry.values()) if (en.code === code) return en.el;
      var byCode = document.querySelector('[data-test-code="' + code + '"]');
      if (byCode) return byCode;
    }
    if (registry.has(asString)) return registry.get(asString).el;
    return document.querySelector('[data-testid="' + asString.replace(/"/g, "") + '"]');
  }

  function ensureBadgeLayer() {
    if (badgeLayer) return badgeLayer;
    var style = document.createElement("style");
    style.textContent =
      ".__ui_badge{position:fixed;z-index:2147483647;background:#ff1f8f;color:#fff;font:700 10px/1.2 monospace;" +
      "padding:1px 3px;border-radius:4px;pointer-events:none;box-shadow:0 0 0 1px #fff}";
    document.head.appendChild(style);
    badgeLayer = document.createElement("div");
    badgeLayer.id = "__ui_badge_layer";
    document.body.appendChild(badgeLayer);
    return badgeLayer;
  }

  function renderBadges() {
    var layer = ensureBadgeLayer();
    layer.innerHTML = "";
    for (var e of registry.values()) {
      if (!visible(e.el)) continue;
      var r = e.el.getBoundingClientRect();
      var badge = document.createElement("div");
      badge.className = "__ui_badge";
      badge.textContent = e.code;
      badge.style.left = Math.max(0, r.left) + "px";
      badge.style.top = Math.max(0, r.top) + "px";
      layer.appendChild(badge);
    }
  }

  function rescanSoon() {
    clearTimeout(debounceTimer);
    debounceTimer = setTimeout(scan, 120);
  }

  window.__ui = {
    version: "1.2-live-click-refresh",
    list: function (opts) {
      opts = opts || {};
      var out = [];
      for (var e of registry.values()) {
        if (!e.el.isConnected) continue;
        if (opts.visibleOnly && !visible(e.el)) continue;
        if (opts.page && pageOf(e.el) !== opts.page) continue;
        var info = entry(e.el);
        if (opts.type && info.type !== "" && info.type !== opts.type) continue;
        out.push(info);
      }
      out.sort(function (a, b) { return a.rect.y - b.rect.y || a.rect.x - b.rect.x; });
      return out;
    },
    find: function (substr) {
      substr = String(substr || "").toLowerCase();
      return this.list().filter(function (e) {
        return (e.testid + " " + e.label).toLowerCase().indexOf(substr) >= 0;
      });
    },
    click: function (ref) {
      var el = resolve(ref);
      if (!el) return { ok: false, error: "not found: " + ref };
      if (el.scrollIntoView) el.scrollIntoView({ block: "center", inline: "center" });
      try {
        if (el.focus) el.focus();
        el.click();
        return { ok: true, testid: el.getAttribute("data-testid"), label: labelOf(el) };
      } catch (err) {
        return { ok: false, error: String(err && err.message ? err.message : err) };
      }
    },
    setValue: function (ref, value) {
      var el = resolve(ref);
      if (!el) return { ok: false, error: "not found: " + ref };
      try {
        if (el.type === "checkbox") el.checked = !!value;
        else el.value = value;
        el.dispatchEvent(new Event("input", { bubbles: true }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
        return { ok: true, testid: el.getAttribute("data-testid"), value: el.value };
      } catch (err) {
        return { ok: false, error: String(err && err.message ? err.message : err) };
      }
    },
    get: function (ref) {
      var el = resolve(ref);
      if (!el) return { ok: false, error: "not found: " + ref };
      var info = entry(el);
      return { ok: true, testid: info.testid, value: info.value, text: labelOf(el), ariaPressed: el.getAttribute("aria-pressed"), disabled: info.disabled };
    },
    gpio: function (code) {
      var el = document.querySelector('[data-gpio="' + code + '"]');
      if (!el) return { ok: false, error: "no gpio button: " + code };
      el.click();
      return { ok: true, gpio: code };
    },
    badges: function (on) {
      badgesOn = on !== false;
      if (badgesOn) renderBadges();
      else if (badgeLayer) badgeLayer.innerHTML = "";
      return { badges: badgesOn };
    },
    rescan: function () { scan(); return { count: registry.size }; },
  };

  function initHarness() {
    scan();
    setTimeout(scan, 400);
    setTimeout(scan, 1500);
    try { new MutationObserver(rescanSoon).observe(document.body, { childList: true, subtree: true }); } catch (_) {}
    window.addEventListener("resize", function () { if (badgesOn) renderBadges(); });
    window.addEventListener("scroll", function () { if (badgesOn) renderBadges(); }, true);
    if (/[?&]ui_badges=1/.test(location.search)) window.__ui.badges(true);
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", initHarness);
  else initHarness();
})();

(function () {
  "use strict";
  if (window.__rinaLiveClickRefreshV3Installed) return;
  window.__rinaLiveClickRefreshV3Installed = true;
  window.__rinaLiveOutputPatchInstalled = true;

  var API_FRAME_ENDPOINT = "/api/frame";
  var installAttempts = 0;
  var liveFallbackBound = false;
  var lastCustomLiveSendAt = 0;
  var lastPartsLiveSendAt = 0;
  var customSendSeq = 0;
  var partsSendSeq = 0;

  function safeLog(message, level) {
    try {
      if (typeof log === "function") log(message, level || "debug");
      else console.debug("[rina-live-click-refresh]", message);
    } catch (_) {}
  }

  function cloneFrameSafe(frame) {
    try {
      if (typeof cloneFrame === "function") return cloneFrame(frame);
    } catch (_) {}
    return Array.prototype.slice.call(frame || []).slice(0, 370).map(Boolean);
  }

  function blankFrameSafe() {
    try {
      if (typeof blankFrame === "function") return blankFrame();
    } catch (_) {}
    return new Array(370).fill(false);
  }

  function normalizeFrame(frame) {
    var out = blankFrameSafe();
    var src = Array.prototype.slice.call(frame || []);
    var n = Math.min(out.length, src.length);
    for (var i = 0; i < n; i++) out[i] = !!src[i];
    return out;
  }

  function liveToggleLooksEnabled(id) {
    var btn = document.getElementById(id);
    return !!btn && (btn.classList.contains("active") || btn.getAttribute("aria-pressed") === "true");
  }

  function liveEnabled(toggleId) {
    try {
      if (typeof liveSendEnabled !== "undefined" && liveSendEnabled) return true;
    } catch (_) {}
    return liveToggleLooksEnabled(toggleId);
  }

  function restoreLiveFlagFromToggle(toggleId, label) {
    try {
      if (liveToggleLooksEnabled(toggleId) && typeof liveSendEnabled !== "undefined" && !liveSendEnabled && typeof setLiveSendEnabled === "function") {
        setLiveSendEnabled(true, label || "实时输出恢复");
      }
    } catch (err) {
      console.warn("[rina-live-click-refresh] failed to restore live flag", err);
    }
  }

  function activePageId() {
    var page = document.querySelector("section.page.active");
    return page && page.id ? page.id : "";
  }

  function isAutoModeActive() {
    try {
      return typeof isAutoModeValue === "function" && isAutoModeValue(state.mode);
    } catch (_) {
      return false;
    }
  }

  function isScrollActive() {
    try {
      return !!state.textScrollActive || (typeof isScrollPlaybackValue === "function" && isScrollPlaybackValue(state.playback));
    } catch (_) {
      return false;
    }
  }

  function playbackIsManualIdle() {
    try {
      if (isAutoModeActive()) return false;
      if (isScrollActive()) return false;
      var playback = String(state.playback || "idle");
      return playback === "idle" || playback === "static" || playback === "manual";
    } catch (_) {
      return true;
    }
  }

  function isSameOutputContext(kind) {
    var page = activePageId();
    if (kind === "custom" && page !== "page-custom") return false;
    if (kind === "parts" && page !== "page-parts") return false;
    return playbackIsManualIdle();
  }

  function forceManualUi(reason) {
    try {
      if (typeof state === "undefined") return;
      if (typeof guardBeforeOutput === "function") guardBeforeOutput(reason || "custom_live_rebase", "idle");
      state.mode = "manual";
      state.playback = "idle";
      state.textScrollActive = false;
      if (typeof updateModeToggleUi === "function") updateModeToggleUi();
      if (typeof updateScrollUi === "function") updateScrollUi();
      if (typeof renderState === "function") renderState();
    } catch (err) {
      console.warn("[rina-live-click-refresh] force manual UI failed", err);
    }
  }

  function frameToNormalizedM370(frame) {
    try {
      if (typeof frameToM370 !== "function") return "";
      var text = String(frameToM370(frame) || "").trim();
      if (text.toUpperCase().startsWith("M370:")) text = text.slice(5);
      text = text.replace(/\s+/g, "");
      return /^[0-9a-fA-F]{93}$/.test(text) ? "M370:" + text.toUpperCase() : "";
    } catch (_) {
      return "";
    }
  }

  async function postFrameNow(frame, reason, label, meta) {
    var snapshot = normalizeFrame(frame);
    var m370 = frameToNormalizedM370(snapshot);
    if (!m370) throw new Error("invalid M370 from " + label);
    var payload = Object.assign({
      type: "m370_frame",
      m370: m370,
      reason: reason,
      mode: "idle",
      playback: "idle",
      at: Date.now(),
    }, meta || {});

    if (typeof apiPost === "function") {
      return apiPost(API_FRAME_ENDPOINT, payload, { silent: false, expectJson: true, timeoutMs: 2500 });
    }

    var url = typeof apiUrl === "function" ? apiUrl(API_FRAME_ENDPOINT) : API_FRAME_ENDPOINT;
    if (!url) throw new Error("offline html mode: " + API_FRAME_ENDPOINT);
    var res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify(payload),
    });
    if (!res.ok) throw new Error(String(res.status) + " " + (res.statusText || ""));
    var body = await res.text();
    try { return body ? JSON.parse(body) : { ok: true }; } catch (_) { return { ok: true }; }
  }

  function localFrameDelta(fromFrame, toFrame) {
    if (typeof frameDeltaChanges === "function") {
      try { return frameDeltaChanges(fromFrame, toFrame) || []; } catch (_) {}
    }
    var from = normalizeFrame(fromFrame);
    var to = normalizeFrame(toFrame);
    var changes = [];
    for (var i = 0; i < to.length; i++) if (!!from[i] !== !!to[i]) changes.push([i, to[i] ? 1 : 0]);
    return changes;
  }

  function applyChanges(frame, changes) {
    var out = normalizeFrame(frame);
    for (var i = 0; i < changes.length; i++) {
      var idx = Number(changes[i] && changes[i][0]);
      if (Number.isInteger(idx) && idx >= 0 && idx < out.length) out[idx] = !!changes[i][1];
    }
    return out;
  }

  function currentBaselineFrame() {
    try {
      if (typeof liveSyncedFrame !== "undefined" && liveSyncedFrame) return cloneFrameSafe(liveSyncedFrame);
    } catch (_) {}
    try {
      if (typeof currentFrame !== "undefined" && currentFrame) return cloneFrameSafe(currentFrame);
    } catch (_) {}
    return blankFrameSafe();
  }

  function syncBaseline(frame) {
    try {
      if (typeof syncLiveSendBaseline === "function") syncLiveSendBaseline(frame);
      else if (typeof liveSyncedFrame !== "undefined") liveSyncedFrame = cloneFrameSafe(frame);
    } catch (_) {}
  }

  function applyRuntimeState(data, reason) {
    try {
      if (data && typeof applyFirmwareRuntimeState === "function") applyFirmwareRuntimeState(data, reason);
    } catch (_) {}
  }

  async function publishDiffOrResync(frame, reason, label) {
    var target = normalizeFrame(frame);
    var baseline = currentBaselineFrame();
    var changes = localFrameDelta(baseline, target);
    var frameToPublish = changes.length ? applyChanges(baseline, changes) : target;
    var postReason = changes.length ? reason : reason + "_resync";
    var data = await postFrameNow(frameToPublish, postReason, label, {
      livePath: "diff_or_resync",
      deltaCount: changes.length,
      deltaOnly: changes.length > 0,
    });
    syncBaseline(frameToPublish);
    applyRuntimeState(data, postReason);
    safeLog(label + "实时" + (changes.length ? "diff" : "重发") + "已发布: " + postReason + " changes=" + changes.length, "debug");
    return data || { ok: true };
  }

  async function publishClearThenFull(frame, reason, label) {
    var target = normalizeFrame(frame);
    var clearReason = reason + "_clear_before_full";
    forceManualUi(clearReason);
    var clearData = await postFrameNow(blankFrameSafe(), clearReason, label + "清屏", {
      livePath: "clear_before_full",
      clearBeforeFull: true,
    });
    applyRuntimeState(clearData, clearReason);
    var data = await postFrameNow(target, reason, label, {
      livePath: "full_after_clear",
      fullAfterClear: true,
    });
    syncBaseline(target);
    applyRuntimeState(data, reason);
    forceManualUi(reason);
    safeLog(label + "实时已清屏并发布完整帧: " + reason, "debug");
    return data || { ok: true };
  }

  function sendLiveFrameByContext(frame, reason, toggleId, label, kind) {
    if (!liveEnabled(toggleId)) {
      safeLog(label + "实时发送关闭：只更新本地预览，未发固件帧", "debug");
      return null;
    }
    restoreLiveFlagFromToggle(toggleId, label + "实时输出恢复");
    var snapshot = normalizeFrame(frame);
    var sameContext = isSameOutputContext(kind);
    var promise = sameContext
      ? publishDiffOrResync(snapshot, reason, label)
      : publishClearThenFull(snapshot, reason, label);
    promise.catch(function (err) {
      safeLog(label + "实时帧发送失败: " + (err && err.message ? err.message : err), "error");
      return null;
    });
    return { ok: true, queued: true, path: sameContext ? "diff_or_resync" : "clear_then_full", reason: reason };
  }

  function customFrameSnapshot() {
    try { if (typeof editFrame !== "undefined") return cloneFrameSafe(editFrame); } catch (_) {}
    return null;
  }

  function partsFrameSnapshot() {
    try { if (typeof partsFrame !== "undefined") return cloneFrameSafe(partsFrame); } catch (_) {}
    return null;
  }

  function patchLiveSendFunctions() {
    var installed = true;
    try {
      if (typeof sendCustomFrameIfLive === "function" && !sendCustomFrameIfLive.__rinaClickRefreshV3) {
        var patchedCustom = function patchedSendCustomFrameIfLive(reason) {
          var frame = customFrameSnapshot();
          if (!frame) return null;
          lastCustomLiveSendAt = Date.now();
          return sendLiveFrameByContext(frame, reason || "custom_live_send", "custom-live-toggle", "自定义画板", "custom");
        };
        patchedCustom.__rinaClickRefreshV3 = true;
        sendCustomFrameIfLive = patchedCustom;
      }
      installed = installed && typeof sendCustomFrameIfLive === "function" && !!sendCustomFrameIfLive.__rinaClickRefreshV3;
    } catch (err) {
      installed = false;
      console.warn("[rina-live-click-refresh] custom patch failed", err);
    }

    try {
      if (typeof sendPartsFrameIfLive === "function" && !sendPartsFrameIfLive.__rinaClickRefreshV3) {
        var patchedParts = function patchedSendPartsFrameIfLive(reason) {
          var frame = partsFrameSnapshot();
          if (!frame) return null;
          lastPartsLiveSendAt = Date.now();
          return sendLiveFrameByContext(frame, reason || "parts_live_send", "parts-live-toggle", "部件组合", "parts");
        };
        patchedParts.__rinaClickRefreshV3 = true;
        sendPartsFrameIfLive = patchedParts;
      }
      installed = installed && typeof sendPartsFrameIfLive === "function" && !!sendPartsFrameIfLive.__rinaClickRefreshV3;
    } catch (err) {
      installed = false;
      console.warn("[rina-live-click-refresh] parts patch failed", err);
    }
    return installed;
  }

  function scheduleCustomFallback(reason) {
    var seq = ++customSendSeq;
    requestAnimationFrame(function () {
      requestAnimationFrame(function () {
        if (seq !== customSendSeq) return;
        if (Date.now() - lastCustomLiveSendAt < 80) return;
        if (typeof sendCustomFrameIfLive === "function") sendCustomFrameIfLive(reason || "custom_live_click_fallback");
      });
    });
  }

  function schedulePartsFallback(reason) {
    var seq = ++partsSendSeq;
    requestAnimationFrame(function () {
      requestAnimationFrame(function () {
        if (seq !== partsSendSeq) return;
        if (Date.now() - lastPartsLiveSendAt < 80) return;
        if (typeof sendPartsFrameIfLive === "function") sendPartsFrameIfLive(reason || "parts_live_change_fallback");
      });
    });
  }

  function bindLiveFallbackEvents() {
    if (liveFallbackBound) return;
    liveFallbackBound = true;

    var customMatrix = document.getElementById("matrix-custom-edit");
    if (customMatrix) {
      customMatrix.addEventListener("click", function (ev) {
        if (!ev.target || !ev.target.closest || !ev.target.closest(".led")) return;
        scheduleCustomFallback("custom_live_click");
      });
    }

    ["custom-clear", "custom-fill", "custom-invert"].forEach(function (id) {
      var btn = document.getElementById(id);
      if (!btn) return;
      btn.addEventListener("click", function () { scheduleCustomFallback("custom_live_" + id.replace("custom-", "")); });
    });

    var customImport = document.getElementById("custom-import");
    if (customImport) {
      customImport.addEventListener("click", function () { scheduleCustomFallback("custom_live_import"); });
    }

    var partsRoot = document.getElementById("part-groups");
    if (partsRoot) {
      partsRoot.addEventListener("click", function () { schedulePartsFallback("parts_live_select"); });
      partsRoot.addEventListener("change", function () { schedulePartsFallback("parts_live_select"); });
    }

    ["parts-random", "parts-reset", "parts-import-m370"].forEach(function (id) {
      var btn = document.getElementById(id);
      if (!btn) return;
      btn.addEventListener("click", function () { schedulePartsFallback("parts_live_" + id.replace("parts-", "")); });
    });
  }

  function patchScrollPrepareLiveRestore() {
    try {
      if (typeof prepareForTextScrollUpload === "function" && !prepareForTextScrollUpload.__rinaLiveRestoreV3) {
        var originalPrepare = prepareForTextScrollUpload;
        var patchedPrepare = async function patchedPrepareForTextScrollUpload() {
          var restoreLiveAfterPrepare = liveEnabled("custom-live-toggle") || liveEnabled("parts-live-toggle");
          try {
            return await originalPrepare.apply(this, arguments);
          } finally {
            if (restoreLiveAfterPrepare && typeof setLiveSendEnabled === "function") setLiveSendEnabled(true, "文字滚动准备结束恢复实时");
          }
        };
        patchedPrepare.__rinaLiveRestoreV3 = true;
        prepareForTextScrollUpload = patchedPrepare;
      }
    } catch (err) {
      console.warn("[rina-live-click-refresh] scroll prepare patch failed", err);
    }
  }

  function install() {
    var ok = patchLiveSendFunctions();
    patchScrollPrepareLiveRestore();
    bindLiveFallbackEvents();
    if (!ok && installAttempts < 30) {
      installAttempts += 1;
      setTimeout(install, 150);
    }
  }

  install();
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", install);
  else setTimeout(install, 0);
  setTimeout(install, 600);
  setTimeout(install, 1800);
})();
