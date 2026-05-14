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
