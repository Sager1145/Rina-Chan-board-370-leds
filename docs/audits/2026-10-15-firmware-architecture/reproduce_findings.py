#!/usr/bin/env python3
"""Reproduce current audit findings against production code; asserts observed defects, not desired behavior."""
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
    uint8_t seq=1;
    auto noTimeline=client.cmd(seq++, R"({"cmd":"start_scroll"})");
    auto noTimelineJson=parse(noTimeline.second);
    assert(noTimelineJson["ok"].as<bool>() && !runtimeState().firmwareScrollActive);
    std::cout << "empty_start: ok=true active=false reply_bytes=" << noTimeline.second.size() << '\n';
    runtimeState().scrollFrameCount=4;
    runtimeScrollMeta().framesReceived=4;
    runtimeScrollMeta().uploadComplete=true;
    assert(scrollSessionGroupStart(g_fakeMicros,0,1500,true));
    auto paused=client.cmd(seq++, R"({"cmd":"pause"})");
    assert(parse(paused.second)["ok"].as<bool>());
    assert(runtimeState().paused && !runtimeState().firmwareScrollPaused);
    advanceMs(1500);
    uint8_t frame[FRAME_BYTES];
    assert(scrollSessionTickCursorLocked(millis(), frame));
    assert(runtimeState().scrollFrameIndex==1);
    std::cout << "generic_pause: paused=true firmwareScrollPaused=false cursor_advanced=1\n";
    assert(scrollSessionGroupStart(g_fakeMicros,0,1500,true));
    client.cmd(seq++, R"({"cmd":"pause_scroll"})");
    client.cmd(seq++, R"({"cmd":"resume_scroll"})");
    assert(!runtimeState().groupTimed && runtimeState().scrollIntervalMs==1500);
    const auto before=runtimeState().scrollFrameIndex;
    advanceMs(1000);
    assert(scrollSessionTickCursorLocked(millis(),frame));
    assert(runtimeState().scrollFrameIndex!=before);
    std::cout << "group_exit: reported_interval_ms=1500 actual_advance_after_ms=1000\n";
    auto bright=client.cmd(seq++, R"({"cmd":"set_brightness","payload":{"raw":50}})");
    assert(parse(bright.second)["ok"].as<bool>());
    std::cout << "set_brightness_reply_bytes=" << bright.second.size() << '\n';
    Bytes incoming(2+FRAME_BYTES,0);
    auto setFrame=client.request(0x10,seq++,incoming);
    assert(parse(setFrame.second)["ok"].as<bool>());
    std::cout << "set_frame_request_payload_bytes=" << incoming.size()
              << " reply_bytes=" << setFrame.second.size() << '\n';
}
''')
    binary = sandbox / 'audit'
    subprocess.run(['bash', str(harness / 'stress_build.sh'), str(source), str(binary), 'asan'], check=True)
    subprocess.run([str(binary)], check=True)
