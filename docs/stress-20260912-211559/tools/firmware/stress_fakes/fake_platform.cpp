// Stubs for hardware/network modules not under test, plus lock-order tracking,
// fake LittleFS and fake transport hooks. Test shim only: no product logic.
#include <Arduino.h>
#include <ArduinoJson.h>
#include <LittleFS.h>
#include <esp_heap_caps.h>
#include <filesystem>
#include <fstream>
#include <sstream>
#include "config.h"
#include "sync.h"
#include "serial_log.h"
#include "led_driver.h"
#include "button_animations.h"
#include "buttons.h"
#include "wifi_manager.h"
#include "power_monitor.h"
#include "transport_ble.h"
#include "scroll.h"

uint64_t g_fakeMicros = 1000ULL * 1000ULL; // boot + 1 s: avoids millis()==0 sentinels
size_t g_fakeMallocFailAbove = SIZE_MAX;
void (*g_fakeNotifyTakeHook)(uint32_t) = nullptr;
FakeSerial Serial;
FakeEsp ESP;
void FakeEsp::restart() { std::fprintf(stderr, "ESP.restart() called\n"); }

// ---- lock tracking: FreeRTOS mutexes in sync.cpp are NOT recursive ----------
unsigned g_lockHeld[4] = {0, 0, 0, 0};
unsigned g_lockRecursion = 0, g_lockOrderViolations = 0;
static int rankOf(SyncDomain d) {
    switch (d) { case SyncDomain::Scroll: return 0; case SyncDomain::Frame: return 1;
                 case SyncDomain::Storage: return 2; case SyncDomain::HardwareBus: return 3; }
    return 0;
}
ScopedLock::ScopedLock(SyncDomain domain) : domain_(domain) {
    const int r = rankOf(domain);
    if (g_lockHeld[r]) ++g_lockRecursion;
    for (int i = r + 1; i < 4; ++i) if (g_lockHeld[i]) ++g_lockOrderViolations;
    if (domain == SyncDomain::Storage && g_lockHeld[3]) ++g_lockRecursion; // storage also takes bus
    ++g_lockHeld[r];
    locked_ = true;
}
ScopedLock::~ScopedLock() { if (locked_) --g_lockHeld[rankOf(domain_)]; }
bool initSyncPrimitives() { return true; }

// ---- serial log ------------------------------------------------------------
static RinaLogSink g_sink = nullptr;
void rinaLogInit() {}
void rinaLogSetEnabled(bool) {}
bool rinaLogEnabled() { return false; }
void rinaLogSetLevel(RinaLogLevel) {}
RinaLogLevel rinaLogLevel() { return RINA_LOG_INFO; }
const char* rinaLogLevelName(RinaLogLevel) { return "INFO"; }
bool rinaLogParseLevel(const char*, RinaLogLevel&) { return false; }
bool rinaLogShouldEmit(RinaLogLevel) { return false; }
void rinaLogEmit(RinaLogLevel, const char*, const char*, ...) {}
void rinaLogSetSink(RinaLogSink sink) { g_sink = sink; }
void rinaSerialInit() {}
void rinaSerialWrite(const uint8_t*, size_t) {}
bool rinaLogRateReady(uint32_t&, uint32_t) { return false; }

// ---- LED driver: refresh latency is configurable (default 11 ms, 370*24*30 us)
uint32_t g_fakeRefreshUs = 11100;
unsigned g_fakeRefreshCount = 0;
namespace leddrv {
bool begin() { return true; }
bool ready() { return true; }
void setBrightness(uint8_t) {}
void setPixel(uint16_t, uint8_t, uint8_t, uint8_t) {}
void clear() {}
bool refresh() { g_fakeMicros += g_fakeRefreshUs; ++g_fakeRefreshCount; return true; }
const char* backendName() { return "fake"; }
bool dmaEnabled() { return false; }
uint32_t lastRefreshUs() { return g_fakeRefreshUs; }
uint32_t maxRefreshUs() { return g_fakeRefreshUs; }
uint32_t refreshFailCount() { return 0; }
}
void startButtonAnimationForGpioAction(const String&) {}
void showBatteryOverlay(bool) {}
void showSettingsResetOverlay(bool) {}
void handleButtonAnimationGpioPress(const char*) {}
void handleButtonAnimationGpioRelease(const char*) {}
void serviceButtonAnimationButtonInputs(bool, bool, bool) {}
void serviceButtonAnimations() {}
bool copyButtonAnimationOverlay(uint8_t*, uint16_t) { return false; }
void initHardwareButtons() {}
void serviceHardwareButtons() {}
bool runButtonAction(const String&, const String&) { return true; }
__attribute__((weak)) void notifyScrollRenderTask() {}

// ---- Wi-Fi manager (event fan-out inputs are harness controlled) -----------
bool g_fakeWifiChanged = false, g_fakeWifiScanReady = false;
void wifiManagerBegin() {}
void wifiManagerService() {}
bool wifiManagerStateChanged() { bool v = g_fakeWifiChanged; g_fakeWifiChanged = false; return v; }
bool wifiManagerStateChangedPeek() { return g_fakeWifiChanged; }
void wifiManagerGetStatusJson(JsonObject out) { out["mode"] = "sta"; }
bool wifiManagerStartScan() { return true; }
bool wifiManagerScanInProgress() { return false; }
bool wifiManagerScanResultReady() { bool v = g_fakeWifiScanReady; g_fakeWifiScanReady = false; return v; }
void wifiManagerGetScanJson(JsonArray) {}
bool wifiManagerSetCredentials(const String&, const String&) { return true; }
void wifiManagerClearCredentials() {}
bool wifiManagerSetHotspotCredentials(const String&, const String&) { return true; }
void wifiManagerClearHotspotCredentials() {}
bool wifiManagerSetMode(const String&) { return true; }
void wifiManagerConnect() {}
bool wifiManagerSetAp(const String&, const String&) { return true; }
void wifiManagerFactoryReset() {}

PowerStatus powerStatus;
PowerStatus g_fakePower;
void initPowerMonitor() {}
void servicePowerMonitor(bool) {}
PowerStatus readPowerStatusSnapshot() { return g_fakePower; }
void resetBatteryVoltageMinimum() {}
void resetBatteryVoltageMaximum() {}

void bleTransportBegin() {}
void bleTransportService() {}
void bleTransportDeviceName(char* out, size_t n) { if (n) strlcpy(out, "RinaBoard-TEST", n); }
void bleTransportDefaultDeviceName(char* out, size_t n) { if (n) strlcpy(out, "RinaBoard-TEST", n); }
bool bleTransportSetDeviceName(const char*, String& e) { e = "fake"; return false; }
bool bleTransportFactoryReset() { return true; }

// ---- fake LittleFS -----------------------------------------------------------
FakeFsFaults g_fsFaults;
std::string g_fsRoot = "/tmp/rina-fakefs";
FakeLittleFS LittleFS;
namespace fs = std::filesystem;
static std::string full(const char* p) { return g_fsRoot + (p[0] == '/' ? "" : "/") + p; }

File::File(const std::string& f, const char* mode) : full_(f) {
    if (mode[0] == 'r') {
        std::ifstream in(f, std::ios::binary);
        if (!in) return;
        std::stringstream ss; ss << in.rdbuf(); data_ = ss.str();
        open_ = true;
    } else {
        if (g_fsFaults.failOpenWrite) return;
        writing_ = true; open_ = true; budget_ = g_fsFaults.writeLimitBytes;
        std::ofstream out(f, std::ios::binary | std::ios::trunc);
        if (!out) open_ = false;
    }
}
String File::readString() { String s(data_.substr(pos_)); pos_ = data_.size(); return s; }
size_t File::readBytes(char* out, size_t n) { size_t c = std::min(n, data_.size() - pos_); std::memcpy(out, data_.data() + pos_, c); pos_ += c; return c; }
size_t File::read(uint8_t* out, size_t n) { return readBytes(reinterpret_cast<char*>(out), n); }
size_t File::write(const uint8_t* p, size_t n) {
    if (!open_ || !writing_) return 0;
    size_t c = n;
    if (budget_ >= 0) { c = std::min<size_t>(n, static_cast<size_t>(budget_)); budget_ -= static_cast<long>(c); if (c < n) ++g_fsFaults.partialWrites; }
    data_.append(reinterpret_cast<const char*>(p), c);
    return c;
}
void File::close() {
    if (open_ && writing_) { std::ofstream out(full_, std::ios::binary | std::ios::trunc); out.write(data_.data(), static_cast<std::streamsize>(data_.size())); }
    open_ = false;
}
bool FakeLittleFS::exists(const char* p) { return fs::exists(full(p)); }
bool FakeLittleFS::mkdir(const char* p) { std::error_code ec; return fs::create_directories(full(p), ec) || fs::exists(full(p)); }
bool FakeLittleFS::remove(const char* p) { std::error_code ec; return fs::remove(full(p), ec); }
bool FakeLittleFS::rename(const String& from, const char* to) {
    if (g_fsFaults.failRename) return false;
    std::error_code ec; fs::rename(full(from.c_str()), full(to), ec); if (!ec) ++g_fsFaults.renames; return !ec;
}
File FakeLittleFS::open(const char* p, const char* mode) { return File(full(p), mode); }
