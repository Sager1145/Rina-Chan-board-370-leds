#!/usr/bin/env python3
"""Exercise audit boundary fixes against production protocol.cpp under ASan/UBSan."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
FW = ROOT / 'esp32s3_firmware'
HARNESS = ROOT / 'docs/stress-20260912-211559/tools/firmware'
with tempfile.TemporaryDirectory(prefix='rina-audit-protocol-') as directory:
    sandbox = Path(directory)
    harness = sandbox / 'tools/firmware'
    harness.mkdir(parents=True)
    shutil.copytree(HARNESS / 'stress_fakes', harness / 'stress_fakes')
    for name in ('stress_build.sh', 'stress_common.h'):
        shutil.copy2(HARNESS / name, harness / name)
    os.symlink(FW / 'src', sandbox / 'src')
    os.symlink(FW / '.pio', sandbox / '.pio')
    source = harness / 'audit.cpp'
    source.write_text(r'''
#include "../../src/protocol.cpp"
#include "stress_common.h"
#include <cassert>
const char* boardBootId() { return "audit-boot"; }
bool isBrightnessButtonCode(const String&) { return false; }
int main() {
    protocolBegin();
    initRuntimeScrollFrameBuffer();
    FakeTransport transport;
    TestClient client;
    assert(client.connect(transport));
    uint8_t seq = 1;
    auto begin = [&](const std::string& json) {
        return client.request(0x20, seq++, bytesOf(json));
    };
    for (const auto* json : {
        "{\"kind\":\"scroll\",\"totalBytes\":4294967295,\"totalFrames\":1}",
        "{\"kind\":\"scroll\",\"totalBytes\":48,\"totalFrames\":2}",
        "{\"kind\":\"scroll\",\"totalBytes\":94,\"totalFrames\":1}",
        "{\"kind\":\"scroll\",\"totalBytes\":47,\"totalFrames\":3073}"
    }) {
        assert(begin(json).first == 0xFF);
        assert(g_clients[client.id.slot].blob.kind == BlobKind::None);
        assert(g_clients[client.id.slot].blob.scrollBuf == nullptr);
    }
    // totalFrames is the eventual timeline size, including later appends.
    assert(begin("{\"kind\":\"scroll\",\"totalBytes\":47,\"totalFrames\":3}").first == 0xA0);
    client.request(0x23, seq++, {});
    runtimeState().scrollFrameCount = MAX_SCROLL_FRAMES;
    assert(begin("{\"kind\":\"scroll\",\"append\":true,\"totalBytes\":47,\"totalFrames\":3072}").first == 0xFF);
    runtimeState().scrollFrameCount = 1;
    assert(begin("{\"kind\":\"scroll\",\"append\":true,\"totalBytes\":47,\"totalFrames\":3}").first == 0xA0);
    client.request(0x23, seq++, {});

    DynamicJsonDocument doc(32768);
    std::string text(4096, '\x01');
    doc["sourceText"] = text;
    assert(emitJson(g_clients[client.id.slot], 0x81, seq, 0, doc));
    auto reply = client.replyFor(seq++);
    assert(reply.first == 0x81);
    DynamicJsonDocument decoded(32768);
    assert(!deserializeJson(decoded, reply.second));
    assert(decoded["sourceText"].as<std::string>() == text);
    doc["sourceText"] = std::string(30000, 'x');
    assert(emitJson(g_clients[client.id.slot], 0x81, seq, 0, doc));
    reply = client.replyFor(seq++);
    assert(reply.first == 0xFF);
    assert(!deserializeJson(decoded, reply.second));
    puts("Audit protocol: allocation bounds, staged append, complete escaped JSON and explicit oversize ERR passed");
}
''')
    binary = sandbox / 'audit'
    subprocess.run(['bash', str(harness / 'stress_build.sh'), str(source), str(binary), 'asan'], check=True)
    subprocess.run([str(binary)], check=True)
