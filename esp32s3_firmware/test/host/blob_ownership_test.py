#!/usr/bin/env python3
"""Test the production cross-carrier blob cleanup with deterministic clock/state."""
from pathlib import Path
import subprocess
import tempfile
source = (Path(__file__).resolve().parents[2] / 'src/protocol.cpp').read_text()
start = source.index('static void expireBlobSessions() {')
end = source.index('// --- Framing / reply helpers', start)
code = r'''
#include <cassert>
#include <cstdint>
#include <cstdio>
enum class BlobKind { None, Scroll, Faces, ScrollBitmap };
struct Blob { BlobKind kind=BlobKind::None; uint32_t generation=0, lastActivityMs=0; };
struct ClientSlot { Blob blob; };
ClientSlot g_clients[4];
int g_activeScrollBlobSlot=-1;
uint32_t generation=1, now=0;
uint32_t scrollSessionGeneration() { return generation; }
uint32_t millis() { return now; }
void resetBlob(ClientSlot& c) {
    if (g_activeScrollBlobSlot == &c-g_clients) g_activeScrollBlobSlot=-1;
    c.blob={};
}
''' + source[start:end] + r'''
int main() {
    for (auto kind : {BlobKind::Scroll, BlobKind::ScrollBitmap}) {
        for (int slot=0;slot<3;++slot) { // BLE and both TCP clients
            for(auto& c:g_clients) c.blob={};
            generation=10; now=100;
            g_clients[slot].blob={kind,10,100};
            g_activeScrollBlobSlot=slot;
            expireBlobSessions();
            assert(g_clients[slot].blob.kind==kind);
            ++generation; // manual/auto/serial/button takeover
            expireBlobSessions();
            assert(g_clients[slot].blob.kind==BlobKind::None && g_activeScrollBlobSlot==-1);
        }
    }
    for (auto kind : {BlobKind::Scroll, BlobKind::ScrollBitmap, BlobKind::Faces}) {
        g_clients[0].blob={kind,generation,UINT32_MAX-10};
        now=20;
        expireBlobSessions();
        assert(g_clients[0].blob.kind==kind); // timer wrap is not expiry
        now=30000;
        expireBlobSessions();
        assert(g_clients[0].blob.kind==BlobKind::None);
    }
    now=100;
    g_clients[0].blob={BlobKind::Faces,0,100};
    ++generation;
    expireBlobSessions();
    assert(g_clients[0].blob.kind==BlobKind::Faces); // display changes don't abort storage uploads
    std::puts("Blob ownership: BLE + two TCP slots, raw/bitmap takeover, idle timeout/wrap and faces isolation passed");
}
'''
code = '#include <initializer_list>\n' + code
with tempfile.TemporaryDirectory(prefix='rina-blob-test-') as directory:
    cpp = Path(directory) / 'test.cpp'
    binary = Path(directory) / 'test'
    cpp.write_text(code)
    subprocess.run(['c++', '-std=c++17', '-Wall', '-Wextra', '-Werror', str(cpp), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
