#include "protocol.cpp"
#include "scroll.cpp"
#include "main.cpp"
#include "stress_common.h"
#include <Preferences.h>
#include <WiFi.h>
#include <esp_netif.h>

static void require(bool condition, const char* message) {
    if (!condition) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
}

static JsonObject wifiStatus(DynamicJsonDocument& doc) {
    JsonObject status = doc.to<JsonObject>(); wifiManagerGetStatusJson(status); return status;
}

static void apAddressDefaults() {
    Preferences::values["ssid"] = "Existing home";
    Preferences::values["appass"] = "12345678";
    wifiManagerBegin();
    require(apIP().toString() == "10.0.0.1", "fresh default uses physical identity");
    require(Preferences::values["apip"] == "10.0.0.1", "default persisted on first boot");
    require(Preferences::values["ssid"] == "Existing home", "default migration preserves home profile");
    require(IPAddress(g_fakeDhcpLease.start_ip.addr).toString() == "10.0.0.32" &&
            IPAddress(g_fakeDhcpLease.end_ip.addr).toString() == "10.0.0.47", "low gateway gets safe pool");
    DynamicJsonDocument doc(2048);
    require(wifiStatus(doc)["apIp"] == "10.0.0.1", "BLE-readable status reports actual IP");
    Preferences::values["apip"] = "8.8.8.8"; wifiManagerBegin();
    require(apIP().toString() == "10.0.0.1" && Preferences::values["apip"] == "10.0.0.1",
            "invalid persisted IP falls back to unique factory default");
}

static void apAddressOverride() {
    wifiManagerBegin(); require(wifiManagerSetAp("Custom board", "12345678"), "custom credentials saved");
    require(wifiManagerSetAp("", "", "172.20.4.200"), "IP-only change succeeds");
    require(wifiManagerApSsid() == "Custom board" && Preferences::values["appass"] == "12345678",
            "IP-only edit preserves both credentials");
    require(apIP().toString() == "172.20.4.200" && WiFi.softAPIP().toString() == "172.20.4.200",
            "runtime and actual driver addresses agree");
    require(IPAddress(g_fakeDhcpLease.start_ip.addr).toString() == "172.20.4.1" &&
            IPAddress(g_fakeDhcpLease.end_ip.addr).toString() == "172.20.4.16", "high gateway gets safe pool");
    setApIP(factoryApIP()); wifiManagerBegin();
    require(apIP().toString() == "172.20.4.200", "reboot loads persisted override");
    require(wifiManagerSetAp("Renamed board", "abcdefgh"), "legacy credentials command succeeds");
    require(apIP().toString() == "172.20.4.200", "omitted IP retains current override");
    FakeTransport ble(Carrier::Ble); TestClient client;
    require(client.connect(ble), "BLE connected through factory reset");
    WiFi.AP.clients = 1;
    const auto resetEndCalls = WiFi.AP.endCalls;
    wifiManagerFactoryReset();
    require(apIP().toString() == "10.0.0.1" && Preferences::values["apip"] == "10.0.0.1",
            "factory reset restores hardware default");
    require(WiFi.AP.endCalls == resetEndCalls + 1 && WiFi.AP.clients == 0 &&
            !g_fakeApClientsKeptOldSubnet && WiFi.AP.active && WiFi.getMode() == WIFI_AP &&
            WiFi.softAPIP().toString() == "10.0.0.1" &&
            IPAddress(g_fakeDhcpLease.start_ip.addr).toString() == "10.0.0.32" &&
            IPAddress(g_fakeDhcpLease.end_ip.addr).toString() == "10.0.0.47",
            "factory subnet reset detaches clients and recreates safe default DHCP/AP");
    require(clientActive(g_clients[client.id.slot]) && ble.disconnects == 0,
            "factory AP restart preserves BLE control");
    WiFi.AP.clients = 1;
    wifiManagerFactoryReset();
    require(WiFi.AP.endCalls == resetEndCalls + 1 && WiFi.AP.clients == 1,
            "factory reset at unchanged subnet needs no additional AP restart");
}

static void apAddressFailures() {
    wifiManagerBegin(); require(wifiManagerSetAp("Good board", "12345678"), "initial credentials saved");
    const auto values = Preferences::values; const auto writes = Preferences::writes;
    for (const char* ip : {"8.8.8.8", "10.0.0.0", "10.0.0.255", "010.0.0.1", "", " 10.0.0.1"}) {
        require(!wifiManagerSetAp("Changed board", "abcdefgh", ip), "invalid update rejected");
        require(Preferences::values == values && Preferences::writes == writes, "invalid update never writes NVS");
        require(apIP().toString() == "10.0.0.1" && wifiManagerApSsid() == "Good board", "invalid update atomic");
    }
    WiFi.AP.endResult = false;
    require(!wifiManagerSetAp("Changed board", "abcdefgh", "10.2.3.40"), "AP stop failure reported");
    require(Preferences::values == values && Preferences::writes == writes &&
            apIP().toString() == "10.0.0.1" && wifiManagerApSsid() == "Good board" && WiFi.AP.active,
            "AP stop failure preserves original live and stored config");
    WiFi.AP.endResult = true;
    g_fakeDhcpOptionFailures = 1;
    require(!wifiManagerSetAp("Changed board", "abcdefgh", "10.2.3.40"), "DHCP option failure reported");
    require(Preferences::values == values && Preferences::writes == writes, "driver failure never writes NVS");
    require(apIP().toString() == "10.0.0.1" && WiFi.softAPIP().toString() == "10.0.0.1" &&
            wifiManagerApSsid() == "Good board" && g_fakeDhcpRunning, "driver failure rolls back AP and DHCP");
    g_fakeDhcpStartFailures = 1;
    require(!wifiManagerSetAp("", "", "192.168.40.254"), "DHCP start failure reported");
    require(Preferences::values == values && apIP().toString() == "10.0.0.1" &&
            WiFi.softAPIP().toString() == "10.0.0.1" && g_fakeDhcpRunning, "DHCP start failure restores previous config");
    const auto endCalls = WiFi.AP.endCalls;
    Preferences::failedPuts = 1;
    require(!wifiManagerSetAp("", "", "192.168.40.254"), "NVS failure reported after candidate applied");
    require(Preferences::values == values && Preferences::writes == writes &&
            apIP().toString() == "10.0.0.1" && WiFi.softAPIP().toString() == "10.0.0.1" &&
            g_fakeDhcpRunning && WiFi.AP.active && WiFi.AP.endCalls == endCalls + 2,
            "NVS failure restarts and restores original AP, DHCP and stored config");
}

static void apAddressRestart(bool stationActive) {
    wifiManagerBegin();
    require(wifiManagerSetAp("Same SSID", "12345678"), "original AP configured");
    if (stationActive) {
        require(wifiManagerSetMode("sta_or_ap"), "AP+STA mode enabled");
        WiFi.stationStatus = WL_CONNECTED; WiFi.joinedSsid = "Existing router";
    }
    const auto originalMode = WiFi.getMode();
    FakeTransport ble(Carrier::Ble); TestClient client;
    require(client.connect(ble), "BLE controls address edit");
    WiFi.AP.clients = 1;
    const auto endCalls = WiFi.AP.endCalls;
    auto reply = parse(client.cmd(1, "{\"cmd\":\"wifi_set_ap\",\"ip\":\"192.168.88.254\"}").second);
    require(reply["ok"].as<bool>() && reply["apIp"] == "192.168.88.254", "cross-subnet edit acknowledged over BLE");
    require(WiFi.AP.endCalls == endCalls + 1 && WiFi.AP.clients == 0 && !g_fakeApClientsKeptOldSubnet,
            "cross-subnet edit removes existing DHCP clients before reconfiguration");
    require(WiFi.getMode() == originalMode && (!stationActive ||
            (WiFi.status() == WL_CONNECTED && WiFi.joinedSsid == "Existing router")),
            "AP restart preserves original STA bit and router association");
    require(WiFi.AP.active && wifiManagerApSsid() == "Same SSID" &&
            IPAddress(g_fakeDhcpLease.start_ip.addr).toString() == "192.168.88.1" &&
            IPAddress(g_fakeDhcpLease.end_ip.addr).toString() == "192.168.88.16",
            "same SSID returns with DHCP pool in new subnet");
    require(clientActive(g_clients[client.id.slot]) && ble.disconnects == 0, "AP restart leaves BLE connected");
    // A newly rejoined client and unchanged-address settings must not get
    // disconnected by an unnecessary AP interface restart.
    WiFi.AP.clients = 1;
    require(wifiManagerSetAp("", "", "192.168.88.254"), "same IP accepted");
    require(wifiManagerSetAp("Same SSID", "abcdefgh"), "legacy credentials update accepted");
    require(WiFi.AP.endCalls == endCalls + 1 && WiFi.AP.clients == 1,
            "unchanged or omitted address retains AP interface");
    Preferences::failedPuts = 1;
    auto failed = parse(client.cmd(2, "{\"cmd\":\"wifi_set_ap\",\"ip\":\"10.20.30.1\"}").second);
    require(!failed["ok"].as<bool>() && failed["apIp"] == "192.168.88.254", "failed persisted edit reports restored IP");
    require(WiFi.getMode() == originalMode && (!stationActive || WiFi.status() == WL_CONNECTED) &&
            clientActive(g_clients[client.id.slot]) && ble.disconnects == 0,
            "failed edit rollback retains STA and BLE connections");
}

static void apAddressProtocol() {
    wifiManagerBegin(); const auto writes = Preferences::writes;
    FakeTransport tcp; TestClient tcpClient; require(tcpClient.connect(tcp), "TCP client connected");
    auto rejected = parse(tcpClient.cmd(1, "{\"cmd\":\"wifi_set_ap\",\"ip\":\"10.2.3.4\"}").second);
    require(!rejected["ok"].as<bool>() && rejected["apIp"] == "10.0.0.1", "TCP gets error reply before disruptive edit");
    require(Preferences::writes == writes && apIP().toString() == "10.0.0.1", "TCP IP edit rejection has no mutation");
    auto legacy = parse(tcpClient.cmd(2, "{\"cmd\":\"wifi_set_ap\",\"ssid\":\"Legacy client\",\"password\":\"12345678\"}").second);
    require(legacy["ok"].as<bool>(), "credential-only TCP API retained");
    FakeTransport ble(Carrier::Ble); TestClient bleClient; require(bleClient.connect(ble), "BLE client connected");
    auto reply = parse(bleClient.cmd(3, "{\"cmd\":\"wifi_set_ap\",\"payload\":{\"ssid\":\"\",\"password\":\"\",\"ip\":\"10.2.3.4\"}}").second);
    require(reply["ok"].as<bool>() && reply["apIp"] == "10.2.3.4", "BLE edit replies with applied address");
    require(wifiManagerApSsid() == "Legacy client" && Preferences::values["appass"] == "12345678", "protocol IP-only edit preserves credentials");
    require(clientActive(g_clients[bleClient.id.slot]) && ble.disconnects == 0, "IP update keeps BLE connected");
    for (const std::string value : {"null", "123", "\"\"", "\"10.0.0.255\""}) {
        const auto before = Preferences::writes;
        auto bad = parse(bleClient.cmd(4, "{\"cmd\":\"wifi_set_ap\",\"ip\":" + value + "}").second);
        require(!bad["ok"].as<bool>() && Preferences::writes == before, "malformed explicit JSON IP rejected atomically");
    }
}

int main(int argc, char** argv) {
    require(argc == 3, "case and isolated filesystem required"); resetFakeFs(argv[2]);
    initRuntimeScrollFrameBuffer(); protocolBegin(); const std::string name = argv[1];
    if (name == "ap_address_defaults") apAddressDefaults();
    else if (name == "ap_address_override") apAddressOverride();
    else if (name == "ap_address_failures") apAddressFailures();
    else if (name == "ap_address_protocol") apAddressProtocol();
    else if (name == "ap_address_restart_ap") apAddressRestart(false);
    else if (name == "ap_address_restart_sta") apAddressRestart(true);
    else require(false, "unknown address case");
    require(g_lockRecursion == 0 && g_lockOrderViolations == 0, "production lock discipline");
    std::cout << "PASS: " << name << '\n';
}
