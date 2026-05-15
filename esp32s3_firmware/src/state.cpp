#include "state.h"

RuntimeStore& RuntimeStore::instance() {
    static RuntimeStore store;
    return store;
}

RuntimeState& runtimeState() {
    return RuntimeStore::instance().state();
}

RuntimeFace* runtimeAutoFaces() {
    return RuntimeStore::instance().autoFaces();
}

uint16_t& runtimeAutoFaceCount() {
    return RuntimeStore::instance().autoFaceCount();
}

uint8_t* runtimeFrameBits() {
    return RuntimeStore::instance().frameBits();
}

uint8_t* runtimeScrollFrameBits(uint16_t index) {
    return RuntimeStore::instance().scrollFrameBits(index);
}

bool& runtimeFsMounted() {
    return RuntimeStore::instance().fsMounted();
}

uint32_t runtimeStateVersion() {
    return runtimeState().stateVersion;
}

void touchRuntimeState() {
    ++runtimeState().stateVersion;
    if (runtimeState().stateVersion == 0) runtimeState().stateVersion = 1;
}

void touchRuntimeStateSlow() {
    runtimeState().slowUiDirty = true;
}

void serviceRuntimeSlowStatePublish() {
    RuntimeState& state = runtimeState();
    if (!state.slowUiDirty) return;
    const uint32_t now = millis();
    if (now - state.lastSlowUiPublishMs < POWER_WEB_SLOW_PUBLISH_MS) return;
    state.slowUiDirty = false;
    state.lastSlowUiPublishMs = now;
    touchRuntimeState();
}
