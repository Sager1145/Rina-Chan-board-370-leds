# Independent firmware repair review

Compared the working-tree changes in `esp32s3_firmware/src` against HEAD and the FW-A1..A12 audit requirements. Read all 11 changed production files, the actual surrounding playback/render/registry/Wi-Fi call paths, `audit_repairs_test.py`, `audit_repairs_cases.cpp`, and their configurable adapter fakes. Read pinned Arduino WiFiAP/AP implementations where their failure semantics determine correctness. Read-only; no production/test/user changes, no hardware access, no duplicate full host run.

## One actionable finding

### [P2] Failed AP reconfiguration marks a still-running previous AP inactive and removes its HTTP recovery surface

**Changed lines:** `esp32s3_firmware/src/wifi_manager.cpp:99` (`startSoftAp`, especially100–104), called by the rollback branch at521–525.

**Trigger:** An AP is already running with valid credentials. A valid `wifi_set_ap`/HTTP AP settings update encounters a driver config/get-config error. The attempted change returnsfalse while the old AP remains started with its prior configuration.

**Evidence:**

- New `startSoftAp()` assigns `g_apActive` directly from the attempted `softAPConfig && softAP` result. A failed attempt therefore unconditionally writesfalse.
- `wifiManagerSetAp()` restores the previous SSID/password and avoids NVS writes on failure, but it does not restore/query the prior radio activity. It calls `markChanged()` with `g_apActive` stillfalse.
- Pinned `/Users/sager/.platformio/packages/framework-arduinoespressif32/libraries/WiFi/src/AP.cpp:250–260` returnsfalse for `esp_wifi_get_config`/`esp_wifi_set_config` failure, without disabling the already-running AP. AP.begin() at195–205 enablesAP/checks its started bit; it does not imply a subsequent config failure stoppedAP. WiFiAP.cpp:50–55 passes that create result back.
- `esp32s3_firmware/src/web_setup.cpp:419–431` trusts `apActive` to derive `g_wantHttp` and stops `g_server` when noSTA is connected. Lines436–441 also stop captive DNS. Thus a rejected settings update can leave clients connected to the old AP while the setup HTTP/DNS recovery path disappears until another mode/application operation or reboot.
- The new `apFailure` case at `audit_repairs_cases.cpp:103–111` starts a validAP, injects `apResult=false`, then asserts `apActive=false`. Its fake `softAP` at `audit_fakes/WiFi.h:22` leaves `appliedApSsid` unchanged on failure and never models running-state loss, so the test currently locks in the wrong inference that operationfailure impliesAPinactive.

**Needed correction:** Keep configuration-operation success separate from actual interface activity. On rejected updates preserve/query the still-active previousAP and its serving state while returningfalse and retaining its credentials/NVS. Add a failure case representing rejection on an already-runningAP, alongside a genuinely failed initialAP start. This follows FW-A4's requested actual-state reporting and preservation of usable configuration; it is not new hardening.

**Confidence:** Static production path plus pinned driver failure semantics; no physical fault injection performed. Existing host green results do not refute this case because the fake/test conflate configfailure with radioactivity.

## Other reviewed repairs

No additional concrete findings in battery snapshot transfer, already-ended group state, effective loop updates/resume, all-result profile scan visibility/top20 insertion, temporary scan-mode restoration/superseding mode, unique/nonempty import identities, shared render-task/main-loop fallback, registry-before-carrier teardown ordering, presentation-context retry ownership, or hint precedence.

The new fault harness links the production translation units and meaningfully covers the repaired interfaces. Its carrier scheduler is a bounded registry interleaving model, not proof of real NimBLE timing; its RMT/NVS/radio/FreeRTOS adapters remain injected fault models. No architectural rewrite or unrelated defensive validation is requested.

## Evidence reused

Parent/repair worker reports full ASan/UBSan12case green and aggregate host green in `/tmp/rina-repair-firmware.md` and `/tmp/rina-firmware-selftest.log`; reviewed those records, did not rerun them. Parent owns current build/flashing validation.

## Concrete minimal patch proposal for firmware owner

The pinned WiFiAP.h exposes `WiFi.AP` publicly and NetworkInterface.h exposes `started() const`. Keep the operation's return distinct from the configuredAP serving state:

```cpp
bool startSoftAp() {
    const bool wasActive = g_apActive;
    const bool applied = WiFi.softAPConfig(apIP(), apGateway(), apSubnet()) &&
        (g_apPass.length() > 0
             ? WiFi.softAP(g_apSsid.c_str(), g_apPass.c_str())
             : WiFi.softAP(g_apSsid.c_str()));
    g_apActive = applied || (wasActive && WiFi.AP.started());
    return applied;
}
```

The existing wifiManagerSetAp rollback then restores old credentials while a still-running previouslyconfiguredAP retains its HTTP/DNS serving state; genuinely stopped/initiallyfailedAP remainsinactive. Give the radio fake an explicit startedstate/query, leave itstarted on rejected reconfiguration, and split assertions for previouslyactive rejection versus genuinelyfailed initialstart. Root/firmware owner owns integration and fresh harness/build verification. No remaining findings beyond this item.
