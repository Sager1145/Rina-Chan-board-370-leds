#!/usr/bin/env python3
"""Run the event/storage/blob stress regressions that found FW-D1..D4."""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[3]
FW = ROOT / "esp32s3_firmware"
STRESS = ROOT / "docs/stress-20260912-211559/tools/firmware"
ARDUINOJSON = FW / ".pio/libdeps/esp32s3-rmt-dma/ArduinoJson/src"

if not STRESS.exists():
    raise SystemExit(f"missing stress harness sources: {STRESS}")
if not ARDUINOJSON.exists():
    raise SystemExit("ArduinoJson host headers are missing; run the firmware PlatformIO build first")

with tempfile.TemporaryDirectory(prefix="rina-fw-findings-") as directory:
    sandbox = Path(directory)
    tools = sandbox / "tools/firmware"
    tools.mkdir(parents=True)
    shutil.copytree(STRESS / "stress_fakes", tools / "stress_fakes")
    for name in (
        "stress_build.sh",
        "stress_common.h",
        "stress_f4_events.cpp",
        "stress_f5_f7_blob.cpp",
    ):
        shutil.copy2(STRESS / name, tools / name)
    os.symlink(FW / "src", sandbox / "src")
    os.symlink(FW / ".pio", sandbox / ".pio")

    build = tools / "stress_build.sh"
    cases = (
        ("events", tools / "stress_f4_events.cpp", []),
        ("blob", tools / "stress_f5_f7_blob.cpp", [str(sandbox / "fakefs")]),
    )
    for name, source, args in cases:
        binary = sandbox / name
        subprocess.run(["bash", str(build), str(source), str(binary), "asan"], check=True)
        result = subprocess.run([str(binary), *args], check=True, text=True, capture_output=True)
        summaries = [line for line in result.stdout.splitlines() if line.startswith("SUMMARY")]
        if not summaries or "fail=0" not in summaries[-1]:
            raise AssertionError(result.stdout)
        print(summaries[-1])

    # A minimal valid face uses many one-byte JSON numbers, the densest normal
    # representation that defeated source-size multipliers. Compile against
    # the real target-dependent JSON_*_SIZE calculation and parser.
    capacity_source = sandbox / "capacity.cpp"
    capacity_source.write_text(
        r'''
#include <Arduino.h>
#include <ArduinoJson.h>
#include "utils.h"
#include <cassert>
#include <iostream>
#include <string>
int main() {
    std::string json = "{\"category\":\"unified_saved_faces\",\"faces\":[";
    for (unsigned i = 0; i < 128; ++i) {
        if (i) json += ',';
        json += "{\"id\":\"f" + std::to_string(i) +
                "\",\"name\":\"x\",\"type\":\"" +
                std::string(i == 0 ? "default" : "custom") +
                "\",\"order\":" + std::to_string(i + 1) +
                ",\"frameBytes\":[";
        for (unsigned b = 0; b < 47; ++b) json += b ? ",0" : "0";
        json += "]}";
    }
    json += "]}";
    DynamicJsonDocument document(savedFacesJsonCapacityFor(json.size()));
    const auto error = deserializeJson(document, json.data(), json.size());
    assert(!error);
    assert(document["faces"].size() == 128);
    std::cout << "saved-face capacity: 128 dense valid faces passed\n";
}
'''
    )
    capacity_binary = sandbox / "capacity"
    fake_include = tools / "stress_fakes"
    subprocess.run(
        [
            "c++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
            f"-I{fake_include}", f"-I{FW / 'src'}", f"-I{ARDUINOJSON}",
            "-DARDUINOJSON_ENABLE_ARDUINO_STRING=1",
            str(capacity_source), str(FW / "src/utils.cpp"),
            str(tools / "stress_fakes/fake_platform.cpp"),
            "-o", str(capacity_binary),
        ],
        check=True,
    )
    subprocess.run([str(capacity_binary)], check=True)

faces = (FW / "src/faces.cpp").read_text()
storage = (FW / "src/storage.cpp").read_text()
config = (FW / "src/config.h").read_text()
assert "scheduleRuntimeSettingsSave();" in faces
assert "written == content.length()" in storage
assert "serializedBytes != expected" in storage
assert "PACKED_FRAME_QUEUE_DEPTH = 1" in config
print("PASS: deferred mode persistence, full-write commit, serialization, and latest-only queue contract")
