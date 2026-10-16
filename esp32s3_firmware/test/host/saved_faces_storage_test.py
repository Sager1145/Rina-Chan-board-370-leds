#!/usr/bin/env python3
"""Exercise production saved-face materialization and transactional install under ASan."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
FW = ROOT / 'esp32s3_firmware'
HARNESS = ROOT / 'docs/stress-20260912-211559/tools/firmware'

with tempfile.TemporaryDirectory(prefix='rina-saved-faces-') as directory:
    sandbox = Path(directory)
    harness = sandbox / 'tools/firmware'
    harness.mkdir(parents=True)
    shutil.copytree(HARNESS / 'stress_fakes', harness / 'stress_fakes')
    # Instrument the copied filesystem shim, leaving shared harness sources
    # untouched: assert payload calls are bounded and yields release both locks.
    fake_platform = harness / 'stress_fakes/fake_platform.cpp'
    fake_code = fake_platform.read_text().replace(
        'uint64_t g_fakeMicros =',
        'size_t g_maxReadRequest = 0, g_maxWriteRequest = 0;\n'
        'size_t g_readRemainingBudget = SIZE_MAX;\n'
        'unsigned g_storageDelayCount = 0, g_delayUnderStorage = 0;\nuint64_t g_fakeMicros =')
    fake_code = fake_code.replace('size_t File::readBytes(char* out, size_t n) {',
                                  'size_t File::readBytes(char* out, size_t n) { g_maxReadRequest = std::max(g_maxReadRequest, n);')
    fake_code = fake_code.replace('size_t File::write(const uint8_t* p, size_t n) {',
                                  'size_t File::write(const uint8_t* p, size_t n) { g_maxWriteRequest = std::max(g_maxWriteRequest, n);')
    fake_code = fake_code.replace('size_t c = std::min(n, data_.size() - pos_);',
                                  'size_t c = std::min({n, data_.size() - pos_, g_readRemainingBudget}); g_readRemainingBudget -= c;')
    fake_platform.write_text(fake_code)
    fake_arduino = harness / 'stress_fakes/Arduino.h'
    fake_arduino.write_text(fake_arduino.read_text().replace(
        'inline void delay(uint32_t ms) {',
        'extern unsigned g_lockHeld[4], g_storageDelayCount, g_delayUnderStorage;\n'
        'inline void delay(uint32_t ms) { ++g_storageDelayCount; '
        'if (g_lockHeld[2] || g_lockHeld[3]) ++g_delayUnderStorage;'))
    for name in ('stress_build.sh', 'stress_common.h'):
        shutil.copy2(HARNESS / name, harness / name)
    os.symlink(FW / 'src', sandbox / 'src')
    os.symlink(FW / '.pio', sandbox / '.pio')
    source = harness / 'saved_faces_storage.cpp'
    source.write_text(r'''
#include "../../src/protocol.cpp"
#include "stress_common.h"
#include <cassert>
#include <cstring>
extern size_t g_maxReadRequest, g_maxWriteRequest;
extern size_t g_readRemainingBudget;
extern unsigned g_storageDelayCount, g_delayUnderStorage;

static void addBytes(JsonObject face, const uint8_t* frame) {
    JsonArray bytes = face.createNestedArray("frameBytes");
    for (size_t i = 0; i < FRAME_BYTES; ++i) bytes.add(frame[i]);
}
static JsonObject partsFace(JsonArray faces, const char* id, int order) {
    JsonObject face = faces.createNestedObject();
    face["id"] = id; face["name"] = id; face["order"] = order; face["type"] = "parts";
    face["partsCatalog"] = "rina_expression_parts_370_runtime_v4";
    face["partsVersion"] = 4;
    JsonObject call = face.createNestedObject("call");
    call["leye"] = "101"; call["reye"] = "201"; call["mouth"] = "301"; call["cheek"] = "400";
    return face;
}
int main(int argc, char** argv) {
    assert(argc == 2); resetFakeFs(argv[1]); assert(mountFilesystem());
    PsramJsonDocument doc(savedFacesJsonCapacityFor(4096));
    doc["category"] = "unified_saved_faces";
    JsonArray faces = doc.createNestedArray("faces");
    JsonObject base = faces.createNestedObject();
    base["id"] = "face_1"; base["name"] = "Default"; base["order"] = 1; base["type"] = "default";
    uint8_t zero[FRAME_BYTES] = {}; addBytes(base, zero);
    JsonObject face = partsFace(faces, "parts_1", 2);
    String error; uint8_t composed[FRAME_BYTES];
    assert(materializeSavedFace(face, composed, error));
    bool anyLit = false; for (uint8_t value : composed) anyLit |= value != 0;
    assert(anyLit && (composed[FRAME_BYTES-1] & 0xfc) == 0);
    assert(validateSavedFaces(doc.as<JsonVariant>(), error));
    assert(writeSavedFaces(doc.as<JsonVariant>(), error) > 0);
    assert(runtimeAutoFaceCount() == 2);
    assert(memcmp(runtimeAutoFaces()[1].frameBits, composed, FRAME_BYTES) == 0);
    String disk; assert(readStringFromFileLocked(SAVED_FACES_PATH, disk));
    PsramJsonDocument stored(savedFacesJsonCapacityFor(disk.length()));
    assert(!deserializeJson(stored, disk));
    assert(stored["faces"][1]["frameBytes"].isNull());
    assert(expandSavedFacesDocument(stored.as<JsonVariant>(), error));
    assert(stored["faces"][1]["frameBytes"].size() == FRAME_BYTES);
    // Canonicalize old parts+frameBytes only when exact composition matches.
    addBytes(face, composed);
    face.remove("partsCatalog"); face.remove("partsVersion");
    assert(canonicalizeSavedFaces(doc.as<JsonVariant>(), error));
    assert(face["frameBytes"].isNull() && face["partsVersion"].as<int>() == 4);
    // Manual edit wins over stale metadata; unsupported legacy versions remain bitmap custom.
    addBytes(face, zero);
    assert(canonicalizeSavedFaces(doc.as<JsonVariant>(), error));
    assert(std::string(face["type"] | "") == "custom");
    assert(face["call"].isNull() && face["frameBytes"].size() == FRAME_BYTES);
    face["type"] = "parts"; face["partsCatalog"] = "future"; face["partsVersion"] = 99;
    assert(canonicalizeSavedFaces(doc.as<JsonVariant>(), error));
    assert(std::string(face["type"] | "") == "custom");
    // ID-only unknown versions/IDs/wrong groups fail, with no disk/runtime changes.
    face.remove("frameBytes"); face["type"] = "parts";
    face["partsCatalog"] = "future"; face["partsVersion"] = 99;
    const uint32_t gen = savedFacesGeneration();
    assert(writeSavedFaces(doc.as<JsonVariant>(), error) == 0);
    assert(savedFacesGeneration() == gen && runtimeAutoFaceCount() == 2);
    face["partsCatalog"] = "rina_expression_parts_370_runtime_v4"; face["partsVersion"] = 4;
    JsonObject call = face.createNestedObject("call");
    call["leye"] = "201"; call["reye"] = "201"; call["mouth"] = "301"; call["cheek"] = "400";
    assert(!materializeSavedFace(face, zero, error));
    call["leye"] = "101";
    runtimeFrameBits()[0] = 0x55;
    runtimeState().autoFaceIndex = 1;
    // A successful write installs updated metadata without changing the displayed frame.
    face["name"] = "Renamed";
    assert(writeSavedFaces(doc.as<JsonVariant>(), error) > 0);
    assert(runtimeState().autoFaceIndex == 1 && runtimeFrameBits()[0] == 0x55);
    assert(runtimeAutoFaces()[1].name == "Renamed");
    assert(readStringFromFileLocked(SAVED_FACES_PATH, disk));
    // ENOSPC, rename, staging allocation, and serialization allocation failures
    // retain the exact file and complete runtime table.
    for (int fault = 0; fault < 4; ++fault) {
        face["name"] = "Uncommitted";
        const uint32_t beforeGen = savedFacesGeneration();
        if (fault == 0) g_fsFaults.writeLimitBytes = 3;
        if (fault == 1) g_fsFaults.failRename = true;
        if (fault == 2) g_fakeMallocFailAbove = 0;
        if (fault == 3) {
            assert(disk.length() > 2 * sizeof(RuntimeFace));
            g_fakeMallocFailAbove = 2 * sizeof(RuntimeFace);
        }
        assert(writeSavedFaces(doc.as<JsonVariant>(), error) == 0);
        g_fakeMallocFailAbove = SIZE_MAX; g_fsFaults.writeLimitBytes = -1; g_fsFaults.failRename = false;
        String actual; assert(readStringFromFileLocked(SAVED_FACES_PATH, actual));
        assert(actual == disk && savedFacesGeneration() == beforeGen);
        assert(runtimeAutoFaceCount() == 2 && runtimeAutoFaces()[1].name == "Renamed");
        assert(memcmp(runtimeAutoFaces()[1].frameBits, composed, FRAME_BYTES) == 0);
        assert(runtimeFrameBits()[0] == 0x55);
    }
    // Startup keeps the source file intact and skips individual damaged records.
    size_t written = 0;
    face["call"]["leye"] = "999";
    assert(writeJsonFileAtomic(SAVED_FACES_PATH, doc.as<JsonVariant>(), written, error));
    assert(loadSavedFaces(false));
    assert(runtimeAutoFaceCount() == 1 && runtimeAutoFaces()[0].id == "face_1");
    String unchanged; assert(readStringFromFileLocked(SAVED_FACES_PATH, unchanged));
    assert(std::string(unchanged.c_str()).find("999") != std::string::npos);
    base["frameBytes"][FRAME_BYTES-1] = 4; // invalid padding bits
    assert(writeJsonFileAtomic(SAVED_FACES_PATH, doc.as<JsonVariant>(), written, error));
    assert(!loadSavedFaces(false)); // an existing usable runtime table survives
    assert(runtimeAutoFaceCount() == 1 && runtimeAutoFaces()[0].id == "face_1");
    // Exercise the supported table maximum and the complete expanded old-client
    // document, rather than estimating capacity from a tiny fixture.
    PsramJsonDocument maximum(savedFacesJsonCapacityFor(65536));
    maximum["category"] = "unified_saved_faces";
    JsonArray maximumFaces = maximum.createNestedArray("faces");
    assert(maximumFaces.add(faces[0]));
    maximumFaces[0]["frameBytes"][FRAME_BYTES-1] = 0;
    for (uint16_t i = 1; i < MAX_AUTO_FACES; ++i) {
        String id = String("parts_") + i;
        JsonObject added = partsFace(maximumFaces, "temporary", i+1);
        assert(added["id"].set(id));
    }
    g_maxWriteRequest = 0; g_storageDelayCount = 0;
    assert(writeSavedFaces(maximum.as<JsonVariant>(), error) > 0);
    assert(g_maxWriteRequest <= 2048 && g_storageDelayCount > 0 && g_delayUnderStorage == 0);
    assert(runtimeAutoFaceCount() == MAX_AUTO_FACES);
    char* content = nullptr; size_t length = 0;
    g_maxReadRequest = 0; g_storageDelayCount = 0;
    assert(readBufferFromFileLocked(SAVED_FACES_PATH, content, length));
    assert(g_maxReadRequest <= 2048 && g_storageDelayCount > 0 && g_delayUnderStorage == 0);
    String completeFile; assert(readStringFromFileLocked(SAVED_FACES_PATH, completeFile));
    assert(length == completeFile.length() && memcmp(content, completeFile.c_str(), length+1) == 0);
    free(content);
    g_readRemainingBudget = 5000;
    assert(!readBufferFromFileLocked(SAVED_FACES_PATH, content, length));
    assert(content == nullptr && length == 0);
    g_readRemainingBudget = SIZE_MAX;
    // A short write after several chunks retains the full prior file/table.
    const uint32_t maximumGen = savedFacesGeneration();
    maximumFaces[1]["name"] = "Failed multi-chunk update";
    g_fsFaults.writeLimitBytes = 5000;
    assert(writeSavedFaces(maximum.as<JsonVariant>(), error) == 0);
    g_fsFaults.writeLimitBytes = -1;
    String afterPartial; assert(readStringFromFileLocked(SAVED_FACES_PATH, afterPartial));
    assert(afterPartial == completeFile && savedFacesGeneration() == maximumGen);
    assert(runtimeAutoFaces()[1].name == "temporary");
    assert(expandSavedFacesDocument(maximum.as<JsonVariant>(), error));
    assert(maximumFaces[MAX_AUTO_FACES-1]["frameBytes"].size() == FRAME_BYTES);
    assert(measureJson(maximum) <= MAX_FACES_DOCUMENT_BYTES);
    std::cout << "Saved-face storage: canonical parts, bitmap preservation, projection, rollback, startup recovery passed\n";
}
''')
    binary = sandbox / 'saved_faces_storage'
    subprocess.run(['bash', str(harness / 'stress_build.sh'), str(source), str(binary), 'asan'], check=True)
    subprocess.run([str(binary), str(sandbox / 'fakefs')], check=True)
