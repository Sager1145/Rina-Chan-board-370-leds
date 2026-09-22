#!/usr/bin/env python3
"""Two-phone saved-face identity regressions against production protocol.cpp under ASan/UBSan.

apply_saved_face id (findings: a reorder/delete by another client between a
phone's list refresh and its tap must not apply the wrong face by stale
index) and face_upsert expect (an editor that loaded face X must not
silently clobber what another client saved to the same id in between).
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
FW = ROOT / 'esp32s3_firmware'
HARNESS = ROOT / 'docs/stress-20260912-211559/tools/firmware'

if not HARNESS.exists():
    raise SystemExit(f"missing stress harness sources: {HARNESS}")

with tempfile.TemporaryDirectory(prefix='rina-face-identity-') as directory:
    sandbox = Path(directory)
    harness = sandbox / 'tools/firmware'
    harness.mkdir(parents=True)
    shutil.copytree(HARNESS / 'stress_fakes', harness / 'stress_fakes')
    fake_platform = harness / 'stress_fakes/fake_platform.cpp'
    with fake_platform.open('a') as stream:
        stream.write('\nconst char* boardBootId() { return "face-identity-boot"; }\n'
                     'bool isBrightnessButtonCode(const String&) { return false; }\n')
    for name in ('stress_build.sh', 'stress_common.h'):
        shutil.copy2(HARNESS / name, harness / name)
    os.symlink(FW / 'src', sandbox / 'src')
    os.symlink(FW / '.pio', sandbox / '.pio')
    fakefs = sandbox / 'fakefs'
    source = harness / 'face_identity.cpp'
    source.write_text(r'''
#include "../../src/protocol.cpp"
#include "stress_common.h"
#include <cassert>
#include <iostream>
#include <string>
#include <vector>

// Every byte is `byte` except the last, whose bits beyond LED_COUNT must be
// zero (validatePackedFrame rejects non-zero padding bits).
static std::string hexOf(uint8_t byte, size_t count) {
    static const char* digits = "0123456789abcdef";
    std::string out;
    out.reserve(count * 2);
    const size_t usedBitsInLastByte = LED_COUNT % 8;
    const uint8_t lastMask = usedBitsInLastByte == 0 ? 0xFF : static_cast<uint8_t>((1u << usedBitsInLastByte) - 1u);
    for (size_t i = 0; i < count; ++i) {
        const uint8_t b = (i + 1 == count) ? static_cast<uint8_t>(byte & lastMask) : byte;
        out.push_back(digits[(b >> 4) & 0xF]);
        out.push_back(digits[b & 0xF]);
    }
    return out;
}

static std::string zeroFrameBytesJson() {
    std::string out = "[";
    for (size_t i = 0; i < FRAME_BYTES; ++i) {
        if (i) out += ',';
        out += "0";
    }
    out += "]";
    return out;
}

static std::vector<uint8_t> bytesFromHex(const std::string& hex) {
    std::vector<uint8_t> out;
    out.reserve(hex.size() / 2);
    for (size_t i = 0; i + 1 < hex.size(); i += 2) {
        out.push_back(static_cast<uint8_t>(std::stoul(hex.substr(i, 2), nullptr, 16)));
    }
    return out;
}

// Finds face `id` in a GET_FACES reply and asserts its stored name and
// frame bytes are exactly `expectedName`/`expectedFrameHex` — used after a
// rejected write to prove the board kept the pre-conflict content.
static void assertStoredFace(TestClient& client, uint8_t& seq, const std::string& id,
                              const std::string& expectedName, const std::string& expectedFrameHex) {
    auto reply = client.request(msg::GET_FACES, seq++, {});
    assert(reply.first == (uint8_t)(msg::GET_FACES | 0x80));
    assert(reply.second.size() > 4);
    std::string body = reply.second.substr(4);
    auto doc = parse(body);
    const std::vector<uint8_t> expectedBytes = bytesFromHex(expectedFrameHex);
    bool found = false;
    for (JsonObject face : doc["faces"].as<JsonArray>()) {
        if (std::string(face["id"] | "") == id) {
            found = true;
            assert(std::string(face["name"] | "") == expectedName);
            JsonArray fb = face["frameBytes"].as<JsonArray>();
            assert(fb.size() == expectedBytes.size());
            size_t idx = 0;
            for (JsonVariant v : fb) {
                assert(v.as<int>() == expectedBytes[idx]);
                ++idx;
            }
        }
    }
    assert(found);
}

int main(int argc, char** argv) {
    assert(argc == 2);
    resetFakeFs(argv[1]);
    writeFile(std::string(argv[1]) + "/resources/saved_faces.json",
        std::string("{\"category\":\"unified_saved_faces\",\"faces\":[") +
        "{\"id\":\"default1\",\"name\":\"Default\",\"type\":\"default\",\"order\":1,\"frameBytes\":" +
        zeroFrameBytesJson() + "}]}");
    assert(mountFilesystem());

    protocolBegin();
    initRuntimeScrollFrameBuffer();
    FakeTransport transport;
    TestClient client;
    assert(client.connect(transport));
    uint8_t seq = 1;

    const std::string frameA = hexOf(0x11, FRAME_BYTES);
    const std::string frameAWrong = hexOf(0x22, FRAME_BYTES);
    const std::string frameAExpectWrong = hexOf(0x33, FRAME_BYTES);
    const std::string frameB = hexOf(0x44, FRAME_BYTES);

    // (a) face_upsert create -> ok.
    {
        std::string json = "{\"cmd\":\"face_upsert\",\"payload\":{\"face\":{\"id\":\"custom1\","
            "\"type\":\"custom\",\"name\":\"Alpha\",\"frameHex\":\"" + frameA + "\"}}}";
        auto reply = client.cmd(seq++, json);
        assert(reply.first == 0x81);
        auto doc = parse(reply.second);
        assert(doc["ok"].as<bool>() == true);
    }

    // (b) face_upsert same id with wrong expect -> 409, document not modified.
    {
        std::string json = "{\"cmd\":\"face_upsert\",\"payload\":{\"face\":{\"id\":\"custom1\","
            "\"type\":\"custom\",\"name\":\"AlphaWrong\",\"frameHex\":\"" + frameAWrong + "\","
            "\"expect\":{\"name\":\"Alpha\",\"frameHex\":\"" + frameAExpectWrong + "\"}}}}";
        auto reply = client.cmd(seq++, json);
        assert(reply.first == 0xFF);
        auto doc = parse(reply.second);
        assert(doc["ok"].as<bool>() == false);
        assert(doc["code"].as<int>() == 409);
    }
    assertStoredFace(client, seq, "custom1", "Alpha", frameA);

    // (b2) face_upsert same id, correct frame but wrong expected name -> 409,
    // document not modified (name and frame both prove nothing was written).
    {
        std::string json = "{\"cmd\":\"face_upsert\",\"payload\":{\"face\":{\"id\":\"custom1\","
            "\"type\":\"custom\",\"name\":\"AlphaWrong\",\"frameHex\":\"" + frameAWrong + "\","
            "\"expect\":{\"name\":\"NotAlpha\",\"frameHex\":\"" + frameA + "\"}}}}";
        auto reply = client.cmd(seq++, json);
        assert(reply.first == 0xFF);
        auto doc = parse(reply.second);
        assert(doc["ok"].as<bool>() == false);
        assert(doc["code"].as<int>() == 409);
    }
    assertStoredFace(client, seq, "custom1", "Alpha", frameA);

    // (c) face_upsert same id with correct expect -> ok, content updated.
    {
        std::string json = "{\"cmd\":\"face_upsert\",\"payload\":{\"face\":{\"id\":\"custom1\","
            "\"type\":\"custom\",\"name\":\"Beta\",\"frameHex\":\"" + frameB + "\","
            "\"expect\":{\"name\":\"Alpha\",\"frameHex\":\"" + frameA + "\"}}}}";
        auto reply = client.cmd(seq++, json);
        assert(reply.first == 0x81);
        auto doc = parse(reply.second);
        assert(doc["ok"].as<bool>() == true);
    }
    assertStoredFace(client, seq, "custom1", "Beta", frameB);

    // (d) apply_saved_face with the created id AND a conflicting index (0 is
    // "default1") -> id wins, proving id pinning beats a stale index even
    // when both are present in the same payload.
    {
        std::string json = "{\"cmd\":\"apply_saved_face\",\"payload\":{\"id\":\"custom1\",\"index\":0}}";
        auto reply = client.cmd(seq++, json);
        assert(reply.first == 0x81);
        auto doc = parse(reply.second);
        assert(doc["ok"].as<bool>() == true);
        assert(std::string(doc["autoFaceId"] | "") == "custom1");
    }

    // (e) apply_saved_face with id "nope" -> rejected.
    {
        std::string json = "{\"cmd\":\"apply_saved_face\",\"payload\":{\"id\":\"nope\"}}";
        auto reply = client.cmd(seq++, json);
        assert(reply.first == 0xFF);
        auto doc = parse(reply.second);
        assert(doc["ok"].as<bool>() == false);
        assert(doc["code"].as<int>() == 404);
    }

    // (f) apply_saved_face with only index still works.
    {
        std::string json = "{\"cmd\":\"apply_saved_face\",\"payload\":{\"index\":0}}";
        auto reply = client.cmd(seq++, json);
        assert(reply.first == 0x81);
        auto doc = parse(reply.second);
        assert(doc["ok"].as<bool>() == true);
        assert(std::string(doc["autoFaceId"] | "") == "default1");
    }

    std::cout << "Face identity: apply_saved_face id pinning and face_upsert optimistic-concurrency expect passed\n";
}
''')
    binary = sandbox / 'face_identity'
    subprocess.run(['bash', str(harness / 'stress_build.sh'), str(source), str(binary), 'asan'], check=True)
    subprocess.run([str(binary), str(fakefs)], check=True)
