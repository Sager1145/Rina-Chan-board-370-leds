// F7 support: does jsonCapacityFor() (utils.cpp) hold saved_faces.json documents on
// the ESP32-S3? The host is 64-bit (VariantSlot = 32 B); the device is 32-bit
// (VariantSlot = 16 B: 8 B union + flags + int16 next + 4 B key ptr). We parse on
// the host with ample capacity, count slots by walking the tree, derive string
// bytes, and recompute the device requirement. Pure model; uses real utils.cpp.
// Build: stress_build.sh stress_json_capacity.cpp /tmp/cap && /tmp/cap <data/resources/saved_faces.json>
#include <Arduino.h>
#include <ArduinoJson.h>
#include "utils.h"
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

static size_t countSlots(JsonVariantConst v) {
    size_t n = 0;
    if (v.is<JsonObjectConst>()) for (JsonPairConst p : v.as<JsonObjectConst>()) n += 1 + countSlots(p.value());
    else if (v.is<JsonArrayConst>()) for (JsonVariantConst e : v.as<JsonArrayConst>()) n += 1 + countSlots(e);
    return n;
}
struct Need { size_t src, slots, strings, device, host, capLoad, capMutate; };
static Need measure(const std::string& json) {
    DynamicJsonDocument d(json.size() * 40 + 65536);
    if (deserializeJson(d, json.data(), json.size())) { std::cerr << "parse failed\n"; std::exit(3); }
    Need n{};
    n.src = json.size();
    n.slots = countSlots(d.as<JsonVariantConst>());
    n.host = d.memoryUsage();
    const size_t hostSlot = n.host >= n.slots * 32 ? 32 : 24;
    n.strings = n.host - n.slots * hostSlot;
    n.device = n.slots * 16 + n.strings;
    n.capLoad = jsonCapacityFor(n.src);          // loadSavedFaces + BLOB_END faces
    n.capMutate = jsonCapacityFor(n.src) + 8192; // mutateFacesDocument
    return n;
}
static std::string reserialize(const std::string& in) {
    DynamicJsonDocument d(in.size() * 40 + 65536); deserializeJson(d, in); std::string out; serializeJson(d, out); return out;
}

int main(int argc, char** argv) {
    std::string shipped;
    if (argc > 1) { std::ifstream f(argv[1]); std::stringstream ss; ss << f.rdbuf(); shipped = ss.str(); }
    unsigned pass = 0, fail = 0;
    auto rec = [&](const std::string& id, bool ok, const std::string& m) {
        (ok ? pass : fail)++;
        std::cout << "CASE," << id << ",fw-json-capacity-model,1,-," << (ok ? "PASS" : "FAIL") << "," << m << ",logs/firmware/json_capacity.log" << std::endl;
    };
    DynamicJsonDocument base(shipped.size() * 40 + 65536);
    if (!shipped.empty() && !deserializeJson(base, shipped)) {
        const std::string canon = reserialize(shipped);
        Need n = measure(canon);
        size_t faces = base["faces"].size();
        rec("F7-CAPACITY-SHIPPED-SAVED-FACES", n.device <= n.capLoad,
            "faces=" + std::to_string(faces) + " fileBytes=" + std::to_string(n.src) + " slots=" + std::to_string(n.slots) +
                " deviceNeed=" + std::to_string(n.device) + " jsonCapacityFor=" + std::to_string(n.capLoad) + " hostNeed=" + std::to_string(n.host));
        // Grow the shipped document by cloning its own faces (realistic ids/names/frames) up to 128.
        size_t firstFail = 0, firstFailMutate = 0; Need at128{};
        JsonArray arr = base["faces"].as<JsonArray>();
        std::vector<std::string> proto;
        for (JsonObject f : arr) { std::string s; serializeJson(f, s); proto.push_back(s); }
        for (size_t total = faces; total <= 128; ++total) {
            std::string doc = "{\"category\":\"unified_saved_faces\",\"faces\":[";
            for (size_t i = 0; i < total; ++i) {
                std::string f = proto[i % proto.size()];
                if (i >= proto.size()) { size_t p = f.find("\"id\":\""); if (p != std::string::npos) f.insert(p + 6, "c" + std::to_string(i) + "_"); }
                doc += f + (i + 1 < total ? "," : "");
            }
            doc += "]}";
            Need n2 = measure(reserialize(doc));
            if (!firstFail && n2.device > n2.capLoad) firstFail = total;
            if (!firstFailMutate && n2.device > n2.capMutate) firstFailMutate = total;
            if (total == 128) at128 = n2;
        }
        rec("F7-CAPACITY-128-FACES-DEVICE", firstFail == 0,
            "firstFaceCountExceedingLoad/BLOB=" + std::to_string(firstFail) + " firstExceedingMutate=" + std::to_string(firstFailMutate) +
                " at128: fileBytes=" + std::to_string(at128.src) + " deviceNeed=" + std::to_string(at128.device) + " capacity=" + std::to_string(at128.capLoad));
    } else {
        rec("F7-CAPACITY-SHIPPED-SAVED-FACES", false, "shipped saved_faces.json not readable");
    }
    std::cout << "SUMMARY CAP pass=" << pass << " fail=" << fail << std::endl;
    return 0;
}
