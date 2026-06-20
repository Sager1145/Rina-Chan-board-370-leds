/* =============================================================================
 * test_harness.js -- WebUI test instrumentation for AI agents (Codex, Chrome MCP)
 *
 * It assigns every interactive control a stable, discoverable handle and exposes
 * a small API. The bottom of this file also installs a narrow runtime safety
 * patch for 6.2/6.3 live LED output because this script is loaded after app.js.
 *
 * Each control gets:
 *   data-testid    a stable semantic string  (e.g. "brightness-plus", "gpio-B1")
 *   data-test-code a stable short number      (e.g. 1042) -- convenience handle
 *
 * Agent API (call from the browser console / devtools evaluate):
 *   __ui.list([opts])        -> catalog [{code, testid, label, tag, type, page,
 *                                          visible, disabled, value, rect}]
 *                               opts: {visibleOnly, page, type}
 *   __ui.click(ref)          -> click a control by code or testid
 *   __ui.setValue(ref, val)  -> set input/select/textarea value (+input/change)
 *   __ui.get(ref)            -> read value/checked/text/aria-pressed
 *   __ui.find(substr)        -> catalog entries whose testid/label match
 *   __ui.gpio(code)          -> click a GPIO simulator button (B1..B6S, B3B1...)
 *   __ui.pages()             -> list page sections [{id, active}]
 *   __ui.nav()               -> list nav menu items (to switch pages)
 *   __ui.badges(on)          -> toggle visible code badges over each control
 *
 * DOM bridge for isolated-world agents:
 *   document.documentElement.setAttribute(
 *     "data-ui-bridge-request",
 *     JSON.stringify({id:"1", method:"list", args:[{visibleOnly:true}]}));
 *   document.dispatchEvent(new Event("__ui:call"));
 *   JSON.parse(document.documentElement.getAttribute("data-ui-bridge-result"))
 *
 * Enable visible badges on load with the URL query ?ui_badges=1
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
    "[onclick]",
  ].join(",");

  var registry = new Map(); // testid -> { code, el }
  var usedCodes = new Set();
  var idSeq = 0;

  function slug(s) {
    return (s || "")
      .toString()
      .trim()
      .toLowerCase()
      .replace(/\s+/g, "-")
      .replace(/[^a-z0-9\-_]/g, "")
      .replace(/-+/g, "-")
      .replace(/^-|-$/g, "")
      .slice(0, 40);
  }

  function pageOf(el) {
    var sec = el.closest && el.closest("section.page, section[id]");
    return sec && sec.id ? sec.id : "";
  }

  function labelOf(el) {
    var t =
      el.getAttribute("aria-label") ||
      (el.tagName === "INPUT" || el.tagName === "TEXTAREA"
        ? el.getAttribute("placeholder") || el.getAttribute("name") || el.getAttribute("title")
        : "") ||
      (el.textContent || "").replace(/\s+/g, " ").trim() ||
      el.getAttribute("title") ||
      el.value ||
      "";
    return String(t).slice(0, 60);
  }

  // Deterministic short numeric code from the testid (stable per control).
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
    if (el.__uiTestid && registry.has(el.__uiTestid) && registry.get(el.__uiTestid).el === el) return;
    var testid = el.getAttribute("data-testid") || deriveTestid(el);
    var code;
    if (registry.has(testid) && registry.get(testid).el === el) {
      code = registry.get(testid).code;
    } else {
      code = el.getAttribute("data-test-code")
        ? parseInt(el.getAttribute("data-test-code"), 10)
        : codeFor(testid);
    }
    el.setAttribute("data-testid", testid);
    el.setAttribute("data-test-code", String(code));
    el.__uiTestid = testid;
    registry.set(testid, { code: code, el: el });
    idSeq++;
  }

  function scan() {
    var nodes = document.querySelectorAll(SELECTOR);
    for (var i = 0; i < nodes.length; i++) {
      try {
        tag(nodes[i]);
      } catch (e) {}
    }
    if (badgesOn) renderBadges();
  }

  function resolve(ref) {
    if (ref == null) return null;
    // by code (number or numeric string)
    var asNum = typeof ref === "number" ? ref : /^\d+$/.test(ref) ? parseInt(ref, 10) : null;
    if (asNum != null) {
      for (var en of registry.values()) if (en.code === asNum) return en.el;
      var byAttr = document.querySelector('[data-test-code="' + asNum + '"]');
      if (byAttr) return byAttr;
    }
    // by testid
    if (registry.has(ref)) return registry.get(ref).el;
    var el = document.querySelector('[data-testid="' + (ref + "").replace(/"/g, "") + '"]');
    return el || null;
  }

  function visible(el) {
    return !!(el.offsetParent || el.getClientRects().length) && !el.hasAttribute("hidden");
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

  var badgesOn = false;
  var badgeLayer = null;
  function ensureBadgeLayer() {
    if (badgeLayer) return badgeLayer;
    var s = document.createElement("style");
    s.textContent =
      ".__ui_badge{position:fixed;z-index:2147483647;background:#ff1f8f;color:#fff;font:700 10px/1.2 monospace;" +
      "padding:1px 3px;border-radius:4px;pointer-events:none;box-shadow:0 0 0 1px #fff}";
    document.head.appendChild(s);
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
      if (r.width === 0 && r.height === 0) continue;
      var b = document.createElement("div");
      b.className = "__ui_badge";
      b.textContent = e.code;
      b.style.left = Math.max(0, r.left) + "px";
      b.style.top = Math.max(0, r.top) + "px";
      layer.appendChild(b);
    }
  }

  var debounceT = null;
  function rescanSoon() {
    clearTimeout(debounceT);
    debounceT = setTimeout(scan, 120);
  }

  window.__ui = {
    version: "1.0",
    list: function (opts) {
      opts = opts || {};
      var out = [];
      for (var e of registry.values()) {
        if (!e.el.isConnected) continue;
        if (opts.visibleOnly && !visible(e.el)) continue;
        if (opts.page && pageOf(e.el) !== opts.page) continue;
        var info = entry(e.el);
        if (opts.type && info.type !== opts.type) continue;
        out.push(info);
      }
      out.sort(function (a, b) {
        return a.rect.y - b.rect.y || a.rect.x - b.rect.x;
      });
      return out;
    },
    find: function (substr) {
      substr = (substr || "").toLowerCase();
      return this.list().filter(function (e) {
        return (e.testid + " " + e.label).toLowerCase().indexOf(substr) >= 0;
      });
    },
    click: function (ref) {
      var el = resolve(ref);
      if (!el) return { ok: false, error: "not found: " + ref };
      if (el.scrollIntoView) el.scrollIntoView({ block: "center", inline: "center" });
      var label = labelOf(el);
      try {
        el.focus && el.focus();
        el.click();
        return { ok: true, testid: el.getAttribute("data-testid"), label: label };
      } catch (e) {
        return { ok: false, error: String(e) };
      }
    },
    setValue: function (ref, val) {
      var el = resolve(ref);
      if (!el) return { ok: false, error: "not found: " + ref };
      try {
        if (el.type === "checkbox") {
          el.checked = !!val;
        } else {
          el.value = val;
        }
        el.dispatchEvent(new Event("input", { bubbles: true }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
        return { ok: true, testid: el.getAttribute("data-testid"), value: el.value };
      } catch (e) {
        return { ok: false, error: String(e) };
      }
    },
    get: function (ref) {
      var el = resolve(ref);
      if (!el) return { ok: false, error: "not found: " + ref };
      return { ok: true, testid: el.getAttribute("data-testid"), value: entry(el).value,
               text: (el.textContent || "").trim(),
               ariaPressed: el.getAttribute("aria-pressed"), disabled: entry(el).disabled };
    },
    gpio: function (code) {
      var el = document.querySelector('[data-gpio="' + code + '"]');
      if (!el) return { ok: false, error: "no gpio button: " + code };
      el.click();
      return { ok: true, gpio: code };
    },
    pages: function () {
      return Array.prototype.map.call(document.querySelectorAll("section.page, section[id]"), function (s) {
        return { id: s.id, active: s.classList.contains("active") };
      });
    },
    nav: function () {
      return this.list().filter(function (e) {
        return e.type === "menuitem" || e.testid.indexOf("nav") >= 0;
      });
    },
    badges: function (on) {
      badgesOn = on !== false;
      if (badgesOn) renderBadges();
      else if (badgeLayer) badgeLayer.innerHTML = "";
      return { badges: badgesOn };
    },
    rescan: function () {
      scan();
      return { count: registry.size };
    },
    count: function () {
      return registry.size;
    },
  };

  function bridgePayloadFromEvent(ev) {
    if (ev && ev.detail) {
      if (typeof ev.detail === "string") {
        try {
          return JSON.parse(ev.detail);
        } catch (e) {
          return { id: "", method: "", args: [], parseError: String(e) };
        }
      }
      return ev.detail;
    }
    var raw = document.documentElement.getAttribute("data-ui-bridge-request") || "";
    if (!raw) return {};
    try {
      return JSON.parse(raw);
    } catch (e) {
      return { id: "", method: "", args: [], parseError: String(e) };
    }
  }

  function installDomBridge() {
    document.addEventListener("__ui:call", function (ev) {
      var req = bridgePayloadFromEvent(ev);
      var id = req && req.id != null ? String(req.id) : "";
      var result;
      try {
        if (req.parseError) throw new Error(req.parseError);
        if (
          !req ||
          !req.method ||
          !Object.prototype.hasOwnProperty.call(window.__ui, req.method) ||
          typeof window.__ui[req.method] !== "function"
        ) {
          throw new Error("unknown method: " + (req && req.method));
        }
        result = { id: id, ok: true, result: window.__ui[req.method].apply(window.__ui, Array.isArray(req.args) ? req.args : []) };
      } catch (e) {
        result = { id: id, ok: false, error: String(e && e.message ? e.message : e) };
      }
      var json = JSON.stringify(result);
      document.documentElement.setAttribute("data-ui-bridge-result", json);
      document.dispatchEvent(new CustomEvent("__ui:response", { detail: json }));
    });
    document.documentElement.setAttribute("data-ui-bridge", "ready");
  }

  installDomBridge();

  function init() {
    scan();
    setTimeout(scan, 400);
    setTimeout(scan, 1500); // catch late dynamic controls (presets, face lists, nav)
    try {
      new MutationObserver(rescanSoon).observe(document.body, { childList: true, subtree: true });
    } catch (e) {}
    window.addEventListener("resize", function () { if (badgesOn) renderBadges(); });
    window.addEventListener("scroll", function () { if (badgesOn) renderBadges(); }, true);
    if (/[?&]ui_badges=1/.test(location.search)) window.__ui.badges(true);
    console.info("[__ui] WebUI test harness ready; controls=" + registry.size + ". Try __ui.list()");
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();

/* =============================================================================
 * Runtime safety patch for 6.2/6.3 live LED output.
 *
 * Fixes the live-output chain without touching the large app.js file:
 * - 6.4 text-scroll preparation temporarily disables live output; restore it when
 *   the preparation phase ends so 6.2/6.3 cannot remain silently disabled.
 * - A custom/parts live edit should locally leave Auto/Scroll state immediately;
 *   the matching /api/frame request still lets firmware set manual mode as source
 *   of truth.
 * - If live is disabled, the no-op is logged so the failure mode is visible.
 * ========================================================================== */
(function () {
  "use strict";
  if (window.__rinaLiveOutputPatchInstalled) return;
  window.__rinaLiveOutputPatchInstalled = true;

  function safeLog(message, level) {
    try {
      if (typeof log === "function") log(message, level || "debug");
    } catch (_) {}
  }

  function currentPlaybackIsScroll() {
    try {
      return typeof isScrollPlaybackValue === "function" && isScrollPlaybackValue(state.playback);
    } catch (_) {
      return false;
    }
  }

  function forceManualUiForLiveOutput(reason) {
    try {
      if (typeof state === "undefined") return;
      const wasAuto = typeof isAutoModeValue === "function" && isAutoModeValue(state.mode);
      const wasScroll = !!state.textScrollActive || currentPlaybackIsScroll();
      if (!wasAuto && !wasScroll && state.mode === "manual") return;

      if (typeof guardBeforeOutput === "function" && (wasAuto || wasScroll)) {
        guardBeforeOutput(reason || "custom_live_send", "idle");
      }
      state.mode = "manual";
      if (wasScroll || currentPlaybackIsScroll()) state.playback = "idle";
      state.textScrollActive = false;
      if (typeof renderState === "function") renderState();
    } catch (err) {
      console.warn("[rina-live-patch] force manual failed", err);
    }
  }

  function liveEnabledNow() {
    try {
      return typeof liveSendEnabled !== "undefined" && !!liveSendEnabled;
    } catch (_) {
      return false;
    }
  }

  if (typeof prepareForTextScrollUpload === "function") {
    const originalPrepareForTextScrollUpload = prepareForTextScrollUpload;
    prepareForTextScrollUpload = async function patchedPrepareForTextScrollUpload() {
      const restoreLiveAfterPrepare = liveEnabledNow();
      try {
        return await originalPrepareForTextScrollUpload.apply(this, arguments);
      } finally {
        try {
          if (restoreLiveAfterPrepare && !liveEnabledNow() && typeof setLiveSendEnabled === "function") {
            setLiveSendEnabled(true, "文字滚动准备结束");
          }
        } catch (err) {
          console.warn("[rina-live-patch] live restore after scroll prepare failed", err);
        }
      }
    };
  }

  if (typeof sendCustomFrameIfLive === "function") {
    const originalSendCustomFrameIfLive = sendCustomFrameIfLive;
    sendCustomFrameIfLive = function patchedSendCustomFrameIfLive(reason) {
      const liveReason = reason || "custom_live_send";
      if (!liveEnabledNow()) {
        safeLog("自定义实时发送已关闭：本次 LED 点击只更新本地画板，未发送到固件", "debug");
        return null;
      }
      forceManualUiForLiveOutput(liveReason);
      return originalSendCustomFrameIfLive.apply(this, arguments.length ? arguments : [liveReason]);
    };
  }

  if (typeof sendPartsFrameIfLive === "function") {
    const originalSendPartsFrameIfLive = sendPartsFrameIfLive;
    sendPartsFrameIfLive = function patchedSendPartsFrameIfLive(reason) {
      const liveReason = reason || "parts_live_send";
      if (!liveEnabledNow()) {
        safeLog("部件实时发送已关闭：本次选择只更新本地预览，未发送到固件", "debug");
        return null;
      }
      forceManualUiForLiveOutput(liveReason);
      return originalSendPartsFrameIfLive.apply(this, arguments.length ? arguments : [liveReason]);
    };
  }
})();
