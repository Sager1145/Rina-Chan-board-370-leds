#include "transport_ble.h"

#ifndef RINALINK_NO_BLE

#include <Arduino.h>
#include <ArduinoJson.h>
#include <NimBLEDevice.h>
#include <esp_mac.h>
#include <stdio.h>
#include <string.h>
#include <string>

#include "config.h"
#include "ble_frame_sender.h"
#include "serial_log.h"
#include "state.h"
#include "transport.h"

// =============================================================================
// BLE transport (NimBLE-Arduino 2.x). GATT layout and framing are defined in
// docs/RINALINK_PROTOCOL_V1.md §1.1 / §2. This file only moves raw bytes:
//   * RX writes are appended to the inbound stream via transportPushInbound();
//     protocol.cpp does all framing/dispatch from the Core-0 loop().
//   * send() slices a fully-framed message into (MTU-3)-byte notify chunks.
// Threading: the NimBLE host callbacks (onConnect/onDisconnect/onWrite/
// onMTUChange) run on the NimBLE host task, not the Arduino loop() task.
// Shared state touched from both sides is protected by a small spinlock.
// =============================================================================

namespace {

constexpr char SERVICE_UUID[] = "52494E41-0001-4C49-4E4B-000000000001";
constexpr char RX_UUID[]      = "52494E41-0002-4C49-4E4B-000000000001";
constexpr char TX_UUID[]      = "52494E41-0003-4C49-4E4B-000000000001";
constexpr char INFO_UUID[]    = "52494E41-0004-4C49-4E4B-000000000001";

constexpr uint16_t DEFAULT_ATT_MTU = 23; // Pre-negotiation NimBLE default.
constexpr uint16_t REQUESTED_MTU   = 255;
constexpr uint32_t BLE_INITIALIZATION_TIMEOUT_MS = 15000;
constexpr uint32_t ADVERTISE_RETRY_MS = 250;

class BleTransport : public rinalink::ITransport {
public:
    rinalink::Carrier carrier() const override { return rinalink::Carrier::Ble; }

    bool send(rinalink::ClientId id, const uint8_t* data, size_t len, bool isEvent = false) override {
        uint16_t connHandle;
        uint16_t mtu;
        rinalink::ClientId activeId;
        bool connected;
        {
            portENTER_CRITICAL(&mMux);
            connHandle = mConnHandle;
            mtu = mMtu;
            activeId = mClientId;
            connected = mConnected;
            portEXIT_CRITICAL(&mMux);
        }
        if (!connected || activeId.slot != id.slot || mTx == nullptr)
            return false;

        const size_t chunk = (mtu > 3) ? static_cast<size_t>(mtu - 3) : 20;
        const size_t sliceCount = (len + chunk - 1) / chunk;
        const auto result = rinalink::sendBleFrame(
            data, len, chunk, isEvent,
            [&](const uint8_t* bytes, size_t count) {
                return mTx->notify(bytes, count, connHandle);
            },
            [&]() {
                portENTER_CRITICAL(&mMux);
                const bool active = mConnected && mClientId.slot == id.slot &&
                                    mConnHandle == connHandle;
                portEXIT_CRITICAL(&mMux);
                return active;
            },
            [](uint32_t ms) { delay(ms); },
            []() { return millis(); });
        if (!result.complete) {
            // A reply cannot be silently dropped, even when its first notify
            // never queued: the requester would wait on a dead logical stream.
            // Events may drop before their first byte, but a partial event would
            // make the next frame part of its payload and must close the stream.
            if (rinalink::bleSendFailureRequiresDisconnect(result, isEvent))
                rinalink::transportUnregisterClient(id);
            if (!isEvent)
                RLOG_DEBUG("BLE", "event=notify_failed offset=%u len=%u",
                       static_cast<unsigned>(result.bytesSent), static_cast<unsigned>(len));
            return false;
        }
        // Event delivery must not itself generate another EV_LOG indefinitely.
        if (!isEvent)
            RLOG_DEBUG("BLE", "event=tx_frame handle=%u slot=%u bytes=%u slices=%u mtu=%u kind=%s",
                   static_cast<unsigned>(connHandle), static_cast<unsigned>(id.slot),
                   static_cast<unsigned>(len), static_cast<unsigned>(sliceCount),
                   static_cast<unsigned>(mtu), isEvent ? "event" : "reply");
        return true;
    }

    uint16_t preferredChunkBytes(rinalink::ClientId id) const override {
        (void)id;
        uint16_t mtu;
        portENTER_CRITICAL(&mMux);
        mtu = mMtu;
        portEXIT_CRITICAL(&mMux);
        const uint32_t bytesPerSlice = (mtu > 3) ? static_cast<uint32_t>(mtu - 3) : 20;
        uint32_t v = 8UL * bytesPerSlice;
        if (v > 2048UL)
            v = 2048UL;
        return static_cast<uint16_t>(v);
    }


    void disconnect(rinalink::ClientId id) override {
        uint16_t connHandle = 0;
        bool shouldDisconnect = false;
        portENTER_CRITICAL(&mMux);
        if (mConnected && mClientId.slot == id.slot) {
            connHandle = mConnHandle;
            shouldDisconnect = true;
            // Item A3: clear our own mapping now so the async NimBLE onDisconnect
            // callback (which may arrive after this call returns) sees
            // wasConnected==false in onPeerDisconnected() and does NOT call
            // transportUnregisterClient() again for a slot the registry has
            // already reclaimed.
            mConnected = false;
            mMtu = DEFAULT_ATT_MTU;
            mInitializationTimer.start(0);
        }
        portEXIT_CRITICAL(&mMux);
        if (shouldDisconnect && mServer != nullptr)
            mServer->disconnect(connHandle);
    }

    // --- Setup helpers (called only from bleTransportBegin(), before any BLE
    // activity, so no locking needed here). --------------------------------
    void setCharacteristics(NimBLEServer* server, NimBLECharacteristic* tx, NimBLECharacteristic* info) {
        mServer = server;
        mTx = tx;
        mInfo = info;
    }

    // --- Callback-side hooks (run on the NimBLE host task) ------------------
    void onPeerConnected(NimBLEConnInfo& connInfo) {
        const uint16_t connHandle = connInfo.getConnHandle();
        const std::string peerAddress = connInfo.getAddress().toString();
        bool alreadyConnected;
        portENTER_CRITICAL(&mMux);
        alreadyConnected = mConnected;
        portEXIT_CRITICAL(&mMux);
        if (alreadyConnected) {
            RLOG_WARN("BLE", "event=connect_rejected reason=already_connected handle=%u peer=%s",
                      static_cast<unsigned>(connHandle), peerAddress.c_str());
            if (mServer != nullptr)
                mServer->disconnect(connHandle);
            return;
        }

        rinalink::ClientId newId;
        if (!rinalink::transportRegisterClient(this, rinalink::Carrier::Ble, &newId)) {
            RLOG_WARN("BLE", "event=connect_rejected reason=no_slot handle=%u peer=%s",
                      static_cast<unsigned>(connHandle), peerAddress.c_str());
            if (mServer != nullptr)
                mServer->disconnect(connHandle);
            return;
        }
        portENTER_CRITICAL(&mMux);
        mConnHandle = connHandle;
        mClientId = newId;
        mMtu = DEFAULT_ATT_MTU;
        mConnected = true;
        mInitialFrameTracker.reset();
        mInitializationTimer.start(millis());
        mAdvertisingRetry.cancel();
        mInfoDirty = true;
        portEXIT_CRITICAL(&mMux);
        RLOG_INFO("BLE",
                  "event=connect handle=%u slot=%u peer=%s interval_units=%u timeout_ms=%u mtu=%u",
                  static_cast<unsigned>(connHandle), static_cast<unsigned>(newId.slot),
                  peerAddress.c_str(), static_cast<unsigned>(connInfo.getConnInterval()),
                  static_cast<unsigned>(connInfo.getConnTimeout()) * 10U,
                  static_cast<unsigned>(connInfo.getMTU()));
        // Single central: stop advertising while a peer is connected.
        if (NimBLEDevice::getAdvertising() != nullptr)
            NimBLEDevice::getAdvertising()->stop();
    }

    void onPeerDisconnected(NimBLEConnInfo& connInfo, int reason) {
        const uint16_t connHandle = connInfo.getConnHandle();
        const std::string peerAddress = connInfo.getAddress().toString();
        rinalink::ClientId idToDrop;
        bool wasConnected;
        bool shouldRestartAdvertising;
        portENTER_CRITICAL(&mMux);
        wasConnected = mConnected && mConnHandle == connHandle;
        idToDrop = mClientId;
        if (wasConnected) {
            mConnected = false;
            mMtu = DEFAULT_ATT_MTU;
            mInitializationTimer.start(0);
        }
        // A rejected second central also produces a disconnect callback. Keep
        // advertising stopped while the original central is still connected.
        shouldRestartAdvertising = !mConnected;
        portEXIT_CRITICAL(&mMux);
        if (wasConnected) {
            rinalink::transportUnregisterClient(idToDrop);
        }
        RLOG_INFO("BLE", "event=disconnect handle=%u slot=%d peer=%s reason=%d registered=%d",
                  static_cast<unsigned>(connHandle), wasConnected ? static_cast<int>(idToDrop.slot) : -1,
                  peerAddress.c_str(), reason, wasConnected ? 1 : 0);
        if (shouldRestartAdvertising) {
            portENTER_CRITICAL(&mMux);
            mAdvertisingRetry.request(millis());
            portEXIT_CRITICAL(&mMux);
        }
    }

    void onMtuNegotiated(uint16_t connHandle, uint16_t mtu) {
        portENTER_CRITICAL(&mMux);
        const bool active = mConnected && mConnHandle == connHandle;
        if (active) {
            mMtu = mtu;
            mInfoDirty = true;
        }
        portEXIT_CRITICAL(&mMux);
        if (active) {
            RLOG_INFO("BLE", "event=mtu handle=%u value=%u",
                      static_cast<unsigned>(connHandle), static_cast<unsigned>(mtu));
        } else {
            RLOG_WARN("BLE", "event=mtu_ignored handle=%u value=%u reason=inactive_connection",
                      static_cast<unsigned>(connHandle), static_cast<unsigned>(mtu));
        }
    }

    void onRxWritten(uint16_t connHandle, const uint8_t* data, size_t len) {
        rinalink::ClientId activeId;
        bool connected;
        portENTER_CRITICAL(&mMux);
        activeId = mClientId;
        connected = mConnected && mConnHandle == connHandle &&
                    mInitializationTimer.acceptsInitialization();
        portEXIT_CRITICAL(&mMux);
        if (!connected) {
            RLOG_WARN("BLE", "event=rx_ignored handle=%u bytes=%u reason=inactive_connection",
                      static_cast<unsigned>(connHandle), static_cast<unsigned>(len));
            return;
        }
        // BLE cannot back-pressure a single write like TCP can: if it would not
        // fit, drop it and force a resync (protocol.cpp sends the ERR(413)).
        size_t free = rinalink::transportInboundFree(activeId);
        if (len > free) {
            rinalink::transportMarkResyncNeeded(activeId);
            RLOG_WARN("BLE", "event=inbound_overflow len=%u free=%u", static_cast<unsigned>(len), static_cast<unsigned>(free));
            return;
        }
        const size_t accepted = rinalink::transportPushInbound(activeId, data, len);
        if (accepted > 0 && mInitialFrameTracker.observe(data, accepted)) {
            portENTER_CRITICAL(&mMux);
            if (mConnected && mConnHandle == connHandle)
                mInitializationTimer.confirm();
            portEXIT_CRITICAL(&mMux);
        }
        RLOG_DEBUG("BLE", "event=rx_write handle=%u slot=%u bytes=%u accepted=%u free_before=%u",
                   static_cast<unsigned>(connHandle), static_cast<unsigned>(activeId.slot),
                   static_cast<unsigned>(len), static_cast<unsigned>(accepted),
                   static_cast<unsigned>(free));
    }

    void onTxSubscribed(uint16_t connHandle, uint16_t subValue) {
        if (subValue == 0)
            return;
        portENTER_CRITICAL(&mMux);
        const bool active = mConnected && mConnHandle == connHandle &&
                            mInitializationTimer.acceptsInitialization();
        if (active)
            mInitializationTimer.confirm();
        portEXIT_CRITICAL(&mMux);
        if (active)
            RLOG_DEBUG("BLE", "event=tx_subscribed handle=%u value=%u",
                       static_cast<unsigned>(connHandle), static_cast<unsigned>(subValue));
    }

    void requestAdvertisingRestart(uint32_t delayMs = 0) {
        portENTER_CRITICAL(&mMux);
        if (!mConnected)
            mAdvertisingRetry.request(millis(), delayMs);
        portEXIT_CRITICAL(&mMux);
    }

    // --- Deferred work, called from bleTransportService() on Core-0 loop() --
    void service() {
        bool restartAdvertising = false;
        bool refreshInfo = false;
        bool initializationTimedOut = false;
        rinalink::ClientId timedOutId{0};
        uint16_t timedOutHandle = 0;
        const uint32_t now = millis();
        portENTER_CRITICAL(&mMux);
        if (!mConnected) {
            restartAdvertising = mAdvertisingRetry.takeIfDue(now);
        } else if (mInitializationTimer.expireIfDue(now, BLE_INITIALIZATION_TIMEOUT_MS)) {
            initializationTimedOut = true;
            timedOutId = mClientId;
            timedOutHandle = mConnHandle;
        }
        if (mInfoDirty) {
            mInfoDirty = false;
            refreshInfo = true;
        }
        portEXIT_CRITICAL(&mMux);

        if (initializationTimedOut) {
            RLOG_WARN("BLE", "event=initialization_timeout handle=%u slot=%u timeout_ms=%u",
                      static_cast<unsigned>(timedOutHandle),
                      static_cast<unsigned>(timedOutId.slot),
                      static_cast<unsigned>(BLE_INITIALIZATION_TIMEOUT_MS));
            rinalink::transportUnregisterClient(timedOutId);
        }

        if (refreshInfo)
            updateInfoCharacteristic();

        if (restartAdvertising) {
            NimBLEAdvertising* advertising = NimBLEDevice::getAdvertising();
            const bool started = advertising != nullptr && advertising->start();
            if (started)
                RLOG_INFO("BLE", "event=advertise_restart advertising=1");
            else {
                RLOG_WARN("BLE", "event=advertise_restart_failed");
                requestAdvertisingRestart(ADVERTISE_RETRY_MS);
            }
        }
    }

    void markInfoDirty() {
        portENTER_CRITICAL(&mMux);
        mInfoDirty = true;
        portEXIT_CRITICAL(&mMux);
    }

private:
    void updateInfoCharacteristic() {
        if (mInfo == nullptr)
            return;
        uint16_t mtu;
        portENTER_CRITICAL(&mMux);
        mtu = mMtu;
        portEXIT_CRITICAL(&mMux);
        char name[MAX_DEVICE_NAME_BYTES + 1];
        bleTransportDeviceName(name, sizeof(name));
        char json[256];
        StaticJsonDocument<256> doc;
        doc["proto"] = 1;
        doc["device"] = FIRMWARE_NAME;
        doc["name"] = name;
        doc["fw"] = FIRMWARE_VERSION;
        doc["mtu"] = mtu;
        doc["tcpPort"] = RINALINK_TCP_PORT;
        const size_t n = serializeJson(doc, json, sizeof(json));
        if (n > 0)
            mInfo->setValue(reinterpret_cast<const uint8_t*>(json), n);
    }

    mutable portMUX_TYPE mMux = portMUX_INITIALIZER_UNLOCKED;
    NimBLEServer* mServer = nullptr;
    NimBLECharacteristic* mTx = nullptr;
    NimBLECharacteristic* mInfo = nullptr;

    bool mConnected = false;
    uint16_t mConnHandle = 0;
    uint16_t mMtu = DEFAULT_ATT_MTU;
    rinalink::ClientId mClientId{0};
    rinalink::BleInitialFrameTracker mInitialFrameTracker;
    rinalink::BleInitializationTimer mInitializationTimer;
    rinalink::BleRetryTimer mAdvertisingRetry;
    bool mInfoDirty = false;
};

BleTransport sTransport;

class ServerCallbacks : public NimBLEServerCallbacks {
public:
    void onConnect(NimBLEServer* server, NimBLEConnInfo& connInfo) override {
        (void)server;
        sTransport.onPeerConnected(connInfo);
    }

    void onDisconnect(NimBLEServer* server, NimBLEConnInfo& connInfo, int reason) override {
        (void)server;
        sTransport.onPeerDisconnected(connInfo, reason);
    }

    void onMTUChange(uint16_t mtu, NimBLEConnInfo& connInfo) override {
        sTransport.onMtuNegotiated(connInfo.getConnHandle(), mtu);
    }
};

class RxCallbacks : public NimBLECharacteristicCallbacks {
public:
    void onWrite(NimBLECharacteristic* characteristic, NimBLEConnInfo& connInfo) override {
        // NimBLECharacteristic::getValue() returns NimBLEAttValue in 2.x (was
        // std::string in 1.x); `auto` keeps this compatible with either.
        const auto value = characteristic->getValue();
        if (value.size() > 0)
            sTransport.onRxWritten(connInfo.getConnHandle(),
                                   reinterpret_cast<const uint8_t*>(value.data()), value.size());
    }
};

class TxCallbacks : public NimBLECharacteristicCallbacks {
public:
    void onSubscribe(NimBLECharacteristic* characteristic, NimBLEConnInfo& connInfo,
                     uint16_t subValue) override {
        (void)characteristic;
        sTransport.onTxSubscribed(connInfo.getConnHandle(), subValue);
    }
};

ServerCallbacks sServerCallbacks;
RxCallbacks sRxCallbacks;
TxCallbacks sTxCallbacks;

// Build the factory-default advertised local name: "RinaBoard-AABBCCDDEEFF"
// from all six bytes of the public Bluetooth MAC address (uppercase hex).
// The result is 22 bytes, so it fits as a complete local name in the 31-byte
// scan response and retains the board's full stable hardware identity.
void buildDefaultDeviceName(char* out, size_t outLen) {
    uint8_t mac[6] = {0};
    const esp_err_t result = esp_read_mac(mac, ESP_MAC_BT);
    if (result != ESP_OK)
        RLOG_ERROR("BLE", "event=mac_read_failed code=%d", static_cast<int>(result));
    snprintf(out, outLen, "RinaBoard-%02X%02X%02X%02X%02X%02X",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
}

// Longest prefix of `s` that is <= maxBytes and does not split a UTF-8
// sequence. Returns the byte length to keep. Names are user-supplied and may be
// CJK, so a blind memcpy of maxBytes could emit an invalid trailing fragment.
size_t utf8SafePrefixLen(const char* s, size_t maxBytes) {
    const size_t len = strlen(s);
    if (len <= maxBytes)
        return len;
    size_t cut = maxBytes;
    // Walk back off any continuation byte (0b10xxxxxx) to the lead byte.
    while (cut > 0 && (static_cast<unsigned char>(s[cut]) & 0xC0) == 0x80)
        --cut;
    return cut;
}

// Strict UTF-8 validation. Rejects overlong forms, surrogates and >U+10FFFF so
// a bad name can never be written into the advertisement or persisted.
bool isValidUtf8(const char* s) {
    const unsigned char* p = reinterpret_cast<const unsigned char*>(s);
    while (*p) {
        unsigned char c = *p;
        uint32_t cp;
        int extra;
        if (c < 0x80) { cp = c; extra = 0; }
        else if ((c & 0xE0) == 0xC0) { cp = c & 0x1F; extra = 1; }
        else if ((c & 0xF0) == 0xE0) { cp = c & 0x0F; extra = 2; }
        else if ((c & 0xF8) == 0xF0) { cp = c & 0x07; extra = 3; }
        else return false;
        ++p;
        for (int i = 0; i < extra; i++) {
            if ((*p & 0xC0) != 0x80)
                return false;
            cp = (cp << 6) | (*p & 0x3F);
            ++p;
        }
        if (extra == 1 && cp < 0x80) return false;
        if (extra == 2 && cp < 0x800) return false;
        if (extra == 3 && cp < 0x10000) return false;
        if (cp > 0x10FFFF) return false;
        if (cp >= 0xD800 && cp <= 0xDFFF) return false;
        // Control characters would render as garbage in the app's device list.
        if (cp < 0x20 || cp == 0x7F) return false;
    }
    return true;
}

// Apply the current name to advertising. The 31-byte legacy advertising
// payload cannot hold BOTH a 128-bit service UUID (2 + 16 = 18 bytes) and a
// 14-byte name (2 + 14 = 16) alongside the 3-byte flags field: 37 > 31, so
// NimBLEAdvertisementData::addData() silently rejects the name and the board
// advertises anonymously. Keep the UUID (the app scans by it) in the primary
// payload and put the name in the 31-byte scan response, which iOS merges into
// CBAdvertisementDataLocalNameKey.
bool applyAdvertisingName(const char* deviceName) {
    NimBLEAdvertising* advertising = NimBLEDevice::getAdvertising();
    if (advertising == nullptr)
        return false;

    NimBLEAdvertisementData advData;
    advData.setFlags(BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP);
    const bool uuidOk = advData.setCompleteServices(NimBLEUUID(SERVICE_UUID));

    NimBLEAdvertisementData scanData;
    const bool nameOk = scanData.setName(deviceName);

    const bool advOk = advertising->setAdvertisementData(advData);
    advertising->enableScanResponse(true);
    const bool scanOk = advertising->setScanResponseData(scanData);

    RLOG_INFO("BLE",
              "event=advertise_data name=%s nameBytes=%u uuidSet=%d nameSet=%d advSet=%d scanRspSet=%d",
              deviceName, static_cast<unsigned>(strlen(deviceName)),
              uuidOk ? 1 : 0, nameOk ? 1 : 0, advOk ? 1 : 0, scanOk ? 1 : 0);

    if (!nameOk || !scanOk) {
        // Loud on purpose: this is the failure mode that makes every board show
        // up unnamed in the app, and it is otherwise completely silent.
        RLOG_WARN("BLE", "event=advertise_name_rejected name=%s bytes=%u",
                  deviceName, static_cast<unsigned>(strlen(deviceName)));
    }
    return uuidOk && nameOk && advOk && scanOk;
}

} // namespace

void bleTransportDefaultDeviceName(char* out, size_t outLen) {
    if (out == nullptr || outLen == 0)
        return;
    buildDefaultDeviceName(out, outLen);
}

void bleTransportDeviceName(char* out, size_t outLen) {
    if (out == nullptr || outLen == 0)
        return;
    const String& custom = runtimeState().deviceName;
    if (custom.length() > 0) {
        const size_t keep = utf8SafePrefixLen(custom.c_str(), outLen - 1);
        memcpy(out, custom.c_str(), keep);
        out[keep] = '\0';
        return;
    }
    buildDefaultDeviceName(out, outLen);
}

bool bleTransportSetDeviceName(const char* name, String& error) {
    String next = (name == nullptr) ? String() : String(name);
    next.trim();
    if (next.length() > MAX_DEVICE_NAME_BYTES) {
        error = String("name too long (max ") + MAX_DEVICE_NAME_BYTES + " bytes)";
        return false;
    }
    if (next.length() > 0 && !isValidUtf8(next.c_str())) {
        error = "name is not valid UTF-8";
        return false;
    }

    runtimeState().deviceName = next;
    sTransport.markInfoDirty();

    char effective[MAX_DEVICE_NAME_BYTES + 1];
    bleTransportDeviceName(effective, sizeof(effective));

    NimBLEDevice::setDeviceName(effective);

    NimBLEAdvertising* advertising = NimBLEDevice::getAdvertising();
    const bool wasAdvertising = advertising != nullptr && advertising->isAdvertising();
    if (wasAdvertising)
        advertising->stop();
    applyAdvertisingName(effective);
    // Only resume advertising if we interrupted it. While a central is
    // connected advertising is deliberately stopped (single-central design);
    // restarting here would let a second central connect.
    if (wasAdvertising && !advertising->start()) {
        RLOG_WARN("BLE", "event=advertise_restart_failed name=%s", effective);
        sTransport.requestAdvertisingRestart(ADVERTISE_RETRY_MS);
    }

    RLOG_INFO("BLE", "event=device_name_set name=%s custom=%d readvertised=%d",
              effective, next.length() ? 1 : 0, wasAdvertising ? 1 : 0);
    return true;
}

void bleTransportBegin() {
    char deviceName[MAX_DEVICE_NAME_BYTES + 1];
    bleTransportDeviceName(deviceName, sizeof(deviceName));

    char defaultName[MAX_DEVICE_NAME_BYTES + 1];
    bleTransportDefaultDeviceName(defaultName, sizeof(defaultName));
    RLOG_INFO("BLE", "event=name_resolved effective=%s default=%s custom=%d",
              deviceName, defaultName, runtimeState().deviceName.length() ? 1 : 0);

    NimBLEDevice::init(deviceName);
    NimBLEDevice::setMTU(REQUESTED_MTU);
    // No bonding/pairing required for this device.
    NimBLEDevice::setSecurityAuth(false, false, false);

    NimBLEServer* server = NimBLEDevice::createServer();
    server->setCallbacks(&sServerCallbacks);

    NimBLEService* service = server->createService(SERVICE_UUID);
    NimBLECharacteristic* rx = service->createCharacteristic(
        RX_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
    rx->setCallbacks(&sRxCallbacks);

    NimBLECharacteristic* tx = service->createCharacteristic(TX_UUID, NIMBLE_PROPERTY::NOTIFY);
    tx->setCallbacks(&sTxCallbacks);
    NimBLECharacteristic* info = service->createCharacteristic(INFO_UUID, NIMBLE_PROPERTY::READ);

    sTransport.setCharacteristics(server, tx, info);

    // Seed the INFO value before the first connection (mtu unnegotiated yet).
    char json[256];
    StaticJsonDocument<256> doc;
    doc["proto"] = 1;
    doc["device"] = FIRMWARE_NAME;
    doc["name"] = deviceName;
    doc["fw"] = FIRMWARE_VERSION;
    doc["mtu"] = DEFAULT_ATT_MTU;
    doc["tcpPort"] = RINALINK_TCP_PORT;
    const size_t n = serializeJson(doc, json, sizeof(json));
    if (n > 0)
        info->setValue(reinterpret_cast<const uint8_t*>(json), n);

    server->start();

    applyAdvertisingName(deviceName);
    NimBLEAdvertising* advertising = NimBLEDevice::getAdvertising();
    const bool started = advertising != nullptr && advertising->start();
    if (!started) {
        RLOG_WARN("BLE", "event=advertise_start_failed name=%s", deviceName);
        sTransport.requestAdvertisingRestart(ADVERTISE_RETRY_MS);
    }

    RLOG_INFO("BLE", "event=begin name=%s service=%s advertising=%d",
              deviceName, SERVICE_UUID, started ? 1 : 0);
}

void bleTransportService() {
    sTransport.service();
}

#else // RINALINK_NO_BLE

void bleTransportBegin() {}
void bleTransportService() {}

void bleTransportDeviceName(char* out, size_t outLen) {
    if (out != nullptr && outLen > 0)
        out[0] = '\0';
}

void bleTransportDefaultDeviceName(char* out, size_t outLen) {
    if (out != nullptr && outLen > 0)
        out[0] = '\0';
}

bool bleTransportSetDeviceName(const char* name, String& error) {
    (void)name;
    error = "BLE disabled in this build";
    return false;
}

#endif // RINALINK_NO_BLE
