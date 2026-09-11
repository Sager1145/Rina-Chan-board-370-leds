#include "transport_ble.h"

#ifndef RINALINK_NO_BLE

#include <Arduino.h>
#include <NimBLEDevice.h>
#include <esp_mac.h>
#include <stdio.h>
#include <string.h>

#include "config.h"
#include "serial_log.h"
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
constexpr uint8_t  NOTIFY_MAX_RETRIES = 3;

class BleTransport : public rinalink::ITransport {
public:
    rinalink::Carrier carrier() const override { return rinalink::Carrier::Ble; }

    bool send(rinalink::ClientId id, const uint8_t* data, size_t len, bool isEvent = false) override {
        (void)isEvent;
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
        size_t offset = 0;
        size_t sliceIndex = 0;
        while (offset < len) {
            const size_t n = min(chunk, len - offset);
            bool ok = false;
            for (uint8_t attempt = 0; attempt < NOTIFY_MAX_RETRIES; attempt++) {
                ok = mTx->notify(data + offset, n, connHandle);
                if (ok)
                    break;
                delay(2);
            }
            if (!ok) {
                RLOG_WARN("BLE", "event=notify_failed offset=%u len=%u", static_cast<unsigned>(offset), static_cast<unsigned>(len));
                return false;
            }
            offset += n;
            ++sliceIndex;
            if (sliceCount > 4 && sliceIndex < sliceCount)
                delay(2); // Pace multi-slice bursts so the controller queue does not overrun.
            // Re-check connection state between slices; the peer may drop mid-send.
            portENTER_CRITICAL(&mMux);
            const bool stillConnected = mConnected && mClientId.slot == id.slot;
            portEXIT_CRITICAL(&mMux);
            if (!stillConnected)
                return false;
        }
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

    bool isConnected(rinalink::ClientId id) const override {
        portENTER_CRITICAL(&mMux);
        const bool result = mConnected && mClientId.slot == id.slot;
        portEXIT_CRITICAL(&mMux);
        return result;
    }

    void disconnect(rinalink::ClientId id) override {
        uint16_t connHandle;
        bool connected;
        portENTER_CRITICAL(&mMux);
        connHandle = mConnHandle;
        connected = mConnected && mClientId.slot == id.slot;
        portEXIT_CRITICAL(&mMux);
        if (connected && mServer != nullptr)
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
    void onPeerConnected(uint16_t connHandle) {
        rinalink::ClientId newId;
        if (!rinalink::transportRegisterClient(this, rinalink::Carrier::Ble, &newId)) {
            RLOG_WARN("BLE", "event=connect_rejected reason=no_slot handle=%u", static_cast<unsigned>(connHandle));
            if (mServer != nullptr)
                mServer->disconnect(connHandle);
            return;
        }
        portENTER_CRITICAL(&mMux);
        mConnHandle = connHandle;
        mClientId = newId;
        mMtu = DEFAULT_ATT_MTU;
        mConnected = true;
        mInfoDirty = true;
        portEXIT_CRITICAL(&mMux);
        RLOG_INFO("BLE", "event=connect handle=%u slot=%u", static_cast<unsigned>(connHandle), static_cast<unsigned>(newId.slot));
        // Single central: stop advertising while a peer is connected.
        if (NimBLEDevice::getAdvertising() != nullptr)
            NimBLEDevice::getAdvertising()->stop();
    }

    void onPeerDisconnected(uint16_t connHandle) {
        rinalink::ClientId idToDrop;
        bool wasConnected;
        portENTER_CRITICAL(&mMux);
        wasConnected = mConnected && mConnHandle == connHandle;
        idToDrop = mClientId;
        if (wasConnected) {
            mConnected = false;
            mMtu = DEFAULT_ATT_MTU;
        }
        portEXIT_CRITICAL(&mMux);
        if (wasConnected) {
            rinalink::transportUnregisterClient(idToDrop);
            RLOG_INFO("BLE", "event=disconnect handle=%u slot=%u", static_cast<unsigned>(connHandle), static_cast<unsigned>(idToDrop.slot));
        }
        portENTER_CRITICAL(&mMux);
        mAdvertiseRestartPending = true;
        portEXIT_CRITICAL(&mMux);
    }

    void onMtuNegotiated(uint16_t mtu) {
        portENTER_CRITICAL(&mMux);
        mMtu = mtu;
        mInfoDirty = true;
        portEXIT_CRITICAL(&mMux);
        RLOG_INFO("BLE", "event=mtu value=%u", static_cast<unsigned>(mtu));
    }

    void onRxWritten(const uint8_t* data, size_t len) {
        rinalink::ClientId activeId;
        bool connected;
        portENTER_CRITICAL(&mMux);
        activeId = mClientId;
        connected = mConnected;
        portEXIT_CRITICAL(&mMux);
        if (!connected)
            return;
        // BLE cannot back-pressure a single write like TCP can: if it would not
        // fit, drop it and force a resync (protocol.cpp sends the ERR(413)).
        size_t free = rinalink::transportInboundFree(activeId);
        if (len > free) {
            rinalink::transportMarkResyncNeeded(activeId);
            RLOG_WARN("BLE", "event=inbound_overflow len=%u free=%u", static_cast<unsigned>(len), static_cast<unsigned>(free));
            return;
        }
        rinalink::transportPushInbound(activeId, data, len);
    }

    // --- Deferred work, called from bleTransportService() on Core-0 loop() --
    void service() {
        bool restartAdvertising = false;
        bool refreshInfo = false;
        portENTER_CRITICAL(&mMux);
        if (mAdvertiseRestartPending) {
            mAdvertiseRestartPending = false;
            restartAdvertising = true;
        }
        if (mInfoDirty) {
            mInfoDirty = false;
            refreshInfo = true;
        }
        portEXIT_CRITICAL(&mMux);

        if (refreshInfo)
            updateInfoCharacteristic();

        if (restartAdvertising && NimBLEDevice::getAdvertising() != nullptr) {
            NimBLEDevice::getAdvertising()->start();
            RLOG_INFO("BLE", "event=advertise_restart");
        }
    }

private:
    void updateInfoCharacteristic() {
        if (mInfo == nullptr)
            return;
        uint16_t mtu;
        portENTER_CRITICAL(&mMux);
        mtu = mMtu;
        portEXIT_CRITICAL(&mMux);
        char json[200];
        const int n = snprintf(json, sizeof(json),
                                "{\"proto\":1,\"device\":\"%s\",\"fw\":\"%s\",\"mtu\":%u,\"tcpPort\":%u}",
                                FIRMWARE_NAME, FIRMWARE_VERSION, mtu, RINALINK_TCP_PORT);
        if (n > 0)
            mInfo->setValue(reinterpret_cast<const uint8_t*>(json), static_cast<size_t>(min(n, static_cast<int>(sizeof(json) - 1))));
    }

    mutable portMUX_TYPE mMux = portMUX_INITIALIZER_UNLOCKED;
    NimBLEServer* mServer = nullptr;
    NimBLECharacteristic* mTx = nullptr;
    NimBLECharacteristic* mInfo = nullptr;

    bool mConnected = false;
    uint16_t mConnHandle = 0;
    uint16_t mMtu = DEFAULT_ATT_MTU;
    rinalink::ClientId mClientId{0};
    bool mAdvertiseRestartPending = false;
    bool mInfoDirty = false;
};

BleTransport sTransport;

class ServerCallbacks : public NimBLEServerCallbacks {
public:
    void onConnect(NimBLEServer* server, NimBLEConnInfo& connInfo) override {
        (void)server;
        sTransport.onPeerConnected(connInfo.getConnHandle());
    }

    void onDisconnect(NimBLEServer* server, NimBLEConnInfo& connInfo, int reason) override {
        (void)server;
        (void)reason;
        sTransport.onPeerDisconnected(connInfo.getConnHandle());
    }

    void onMTUChange(uint16_t mtu, NimBLEConnInfo& connInfo) override {
        (void)connInfo;
        sTransport.onMtuNegotiated(mtu);
    }
};

class RxCallbacks : public NimBLECharacteristicCallbacks {
public:
    void onWrite(NimBLECharacteristic* characteristic, NimBLEConnInfo& connInfo) override {
        (void)connInfo;
        // NimBLECharacteristic::getValue() returns NimBLEAttValue in 2.x (was
        // std::string in 1.x); `auto` keeps this compatible with either.
        const auto value = characteristic->getValue();
        if (value.size() > 0)
            sTransport.onRxWritten(reinterpret_cast<const uint8_t*>(value.data()), value.size());
    }
};

ServerCallbacks sServerCallbacks;
RxCallbacks sRxCallbacks;

// Build the advertised local name: "RinaBoard-XXXX" from the last two bytes
// of the Bluetooth MAC address (uppercase hex), read before NimBLEDevice::init.
void buildDeviceName(char* out, size_t outLen) {
    uint8_t mac[6] = {0};
    esp_read_mac(mac, ESP_MAC_BT);
    snprintf(out, outLen, "RinaBoard-%02X%02X", mac[4], mac[5]);
}

} // namespace

void bleTransportBegin() {
    char deviceName[24];
    buildDeviceName(deviceName, sizeof(deviceName));

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
    NimBLECharacteristic* info = service->createCharacteristic(INFO_UUID, NIMBLE_PROPERTY::READ);

    sTransport.setCharacteristics(server, tx, info);

    // Seed the INFO value before the first connection (mtu unnegotiated yet).
    char json[200];
    const int n = snprintf(json, sizeof(json),
                            "{\"proto\":1,\"device\":\"%s\",\"fw\":\"%s\",\"mtu\":%u,\"tcpPort\":%u}",
                            FIRMWARE_NAME, FIRMWARE_VERSION, DEFAULT_ATT_MTU, RINALINK_TCP_PORT);
    if (n > 0)
        info->setValue(reinterpret_cast<const uint8_t*>(json), static_cast<size_t>(min(n, static_cast<int>(sizeof(json) - 1))));

    server->start();

    NimBLEAdvertising* advertising = NimBLEDevice::getAdvertising();
    NimBLEAdvertisementData advData;
    advData.setFlags(BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP);
    advData.setCompleteServices(NimBLEUUID(SERVICE_UUID));
    advData.setName(deviceName);
    advertising->setAdvertisementData(advData);
    advertising->enableScanResponse(true);
    advertising->start();

    RLOG_INFO("BLE", "event=begin name=%s service=%s", deviceName, SERVICE_UUID);
}

void bleTransportService() {
    sTransport.service();
}

#else // RINALINK_NO_BLE

void bleTransportBegin() {}
void bleTransportService() {}

#endif // RINALINK_NO_BLE
