#!/usr/bin/env python3
"""Run production ownership/queue routines against deterministic host fakes."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
def function(file, signature):
    source = (ROOT / 'src' / file).read_text()
    start = source.index(signature)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

code = r'''
#include <cassert>
#include <cstdint>
#include <cstring>
#include <string>
#include <algorithm>
#include <iostream>
constexpr unsigned FRAME_BYTES=2, MAX_SCROLL_FRAMES=4;
constexpr unsigned MIN_SCROLL_INTERVAL_MS=1, MAX_SCROLL_INTERVAL_MS=1000;
constexpr unsigned SCROLL_DRIFT_RESET_INTERVALS=3;
constexpr unsigned PACKED_FRAME_QUEUE_DEPTH=8, PACKED_FRAME_REASON_CHARS=40;
constexpr unsigned PACKED_FRAME_MIN_INTERVAL_MS=20;
using String=std::string;
struct LedPresentationContext {};
enum class LedPresentationSource { ScrollTick };
struct Runtime {
 bool firmwareScrollActive=true, firmwareScrollPaused=false;
 bool firmwareScrollUserPaused=false, firmwareScrollSystemPaused=false, paused=false;
 bool scrollLoop=true;
 String playback="scroll";
 uint16_t scrollFrameIndex=0, scrollFrameCount=2, scrollIntervalMs=10;
 uint32_t lastScrollFrameMs=1, framesAccepted=0, framesDropped=0, framesQueued=0;
} rs;
struct Meta { uint16_t framesReceived=0, nextChunkIndex=0, totalFramesExpected=0; uint8_t uiFps=0; bool uploadComplete=false; char timelineId[8]={}; } meta;
using ScrollTimelineMeta=Meta;
struct ScrollUploadTxn { uint32_t generation=0; uint16_t baseIndex=0,framesReceivedBase=0,nextChunkIndex=0; bool append=false; };
struct ScrollUploadResult { bool valid=false; uint16_t frameCount=0; bool uploadComplete=false; char timelineId[8]={}; };
uint32_t sScrollGeneration=5, nowMs=21;
bool sScrollEndPausePending=false;
uint8_t scrollBits[MAX_SCROLL_FRAMES][FRAME_BYTES]={{1,0},{2,0}}, frame[FRAME_BYTES]={};
Runtime& runtimeState(){return rs;}
Meta& runtimeScrollMeta(){return meta;}
bool runtimeScrollFrameBufferReady(){return true;}
uint8_t* runtimeScrollFrameBits(uint16_t i){return scrollBits[i];}
uint8_t* runtimeFrameBits(){return frame;}
template<class T,class A,class B> T constrain(T v, A a, B b){return std::max(T(a),std::min(v,T(b)));}
uint8_t normalizedUiFps(uint8_t v,uint16_t){return v;}
uint32_t millis(){return nowMs;}
bool millisElapsed(uint32_t n,uint32_t p,uint32_t d){return n-p>=d;}
bool scrollLocked=false, takeOverOnUnlock=false;
template<class F> auto withScrollLock(F f) -> decltype(f()) {
 scrollLocked=true; f(); scrollLocked=false;
 if(takeOverOnUnlock){rs.firmwareScrollActive=false; frame[0]=99; takeOverOnUnlock=false;}
}
template<class F> auto withFrameLock(F f) -> decltype(f()) {return f();}
void scrollSessionFillPresentationContextLocked(LedPresentationContext&,LedPresentationSource,const char*,bool){}
void setPendingLedPresentationContext(const LedPresentationContext&){}
bool consumeLedRenderRequest(){return false;}
void renderCurrentFrameToLedStrip(){}
bool rinaLogShouldEmit(int){return false;}
bool rinaLogRateReady(uint32_t&,int){return false;}
#define RINA_LOG_TRACE 0
#define RLOG_TRACE(...) ((void)0)
#define RLOG_INFO(...) ((void)0)
void touchRuntimeState(){}
#define pdTRUE 1
#define pdMS_TO_TICKS(n) n
struct EndIteration {};
void ulTaskNotifyTake(int,int){throw EndIteration{};}
struct QueuedPackedFrame {uint8_t bits[FRAME_BYTES]={}; char reason[PACKED_FRAME_REASON_CHARS]={};};
QueuedPackedFrame packedFrameQueue[PACKED_FRAME_QUEUE_DEPTH];
uint8_t packedFrameQueueHead=0,packedFrameQueueCount=0;
uint32_t lastPackedFrameApplyMs=20;
void publishPackedFrameNow(const uint8_t* bits,const char*){memcpy(frame,bits,FRAME_BYTES);lastPackedFrameApplyMs=millis();}
'''
for file, signature in [
    ('scroll_session.cpp','bool scrollSessionTickCursorLocked('),
    ('scroll_session.cpp','static bool setFirmwareScrollPauseFlag('),
    ('scroll_session.cpp','bool scrollSessionWriteFrames('),
    ('scroll_session.cpp','ScrollUploadResult scrollSessionCommitUpload('),
    ('scroll.cpp','static void scrollRenderTask('),
    ('led_renderer.cpp','static bool packedFrameRateReady('),
    ('led_renderer.cpp','static void copyText('),
    ('led_renderer.cpp','static void enqueuePackedFrame('),
]:
    code += '\n'+function(file,signature)+'\n'
code += r'''
int main(){
 // Force a new face to take ownership the instant Scroll unlocks. The old
 // snapshot-then-publish implementation overwrote 99 with tick bits (2).
 takeOverOnUnlock=true;
 try {scrollRenderTask(nullptr);} catch(const EndIteration&){}
 assert(frame[0]==99);
 assert(rs.scrollFrameIndex==1);
 // Stop/pause must prevent ticks, including a paused step frame.
 uint8_t out[FRAME_BYTES]={};
 assert(!scrollSessionTickCursorLocked(40,out));
 rs.firmwareScrollActive=true; rs.firmwareScrollPaused=true;
 assert(!scrollSessionTickCursorLocked(40,out));
 // A stopped upload may neither write memory nor revive frameCount on END.
 ScrollUploadTxn stale; stale.generation=4;
 uint8_t bits[FRAME_BYTES]={7,0};
 assert(!scrollSessionWriteFrames(stale,2,bits,1));
 assert(scrollBits[2][0]==0);
 assert(!scrollSessionCommitUpload(stale,3,false,10,0).valid);
 assert(rs.scrollFrameCount==2);
 // Current append is accepted and never overwrites the playable range.
 ScrollUploadTxn current; current.generation=5; current.append=true; current.baseIndex=2;
 assert(!scrollSessionWriteFrames(current,1,bits,1));
 assert(scrollSessionWriteFrames(current,2,bits,1));
 assert(scrollSessionCommitUpload(current,1,false,10,0).valid);
 assert(rs.scrollFrameCount==3 && scrollBits[2][0]==7);
 // An old overlay cannot start an uploaded-but-inactive session.
 rs.firmwareScrollActive=false; rs.firmwareScrollPaused=false;
 assert(!setFirmwareScrollPauseFlag(false,false));
 assert(!rs.firmwareScrollActive);
 // Removing a system overlay preserves the user's pause; user resume clears it.
 rs.firmwareScrollActive=true; rs.firmwareScrollUserPaused=true;
 assert(setFirmwareScrollPauseFlag(false,true));
 assert(setFirmwareScrollPauseFlag(false,false));
 assert(rs.firmwareScrollPaused && rs.firmwareScrollUserPaused);
 assert(setFirmwareScrollPauseFlag(true,false));
 assert(!rs.firmwareScrollPaused && rs.playback=="scroll");
 // Bursty preview retains exactly the latest pending frame.
 for(uint8_t i=1;i<=100;++i){bits[0]=i;enqueuePackedFrame(bits,"preview");}
 assert(packedFrameQueueCount==1);
 assert(packedFrameQueue[0].bits[0]==100);
 assert(rs.framesDropped==99);
 std::cout << "PASS: tick takeover, inactive/paused ticks, stale upload write/commit, current append, overlay/user pause ownership, latest preview (100 frames)\n";
}
'''
with tempfile.TemporaryDirectory(prefix='rina-playback-test-') as d:
    src=Path(d)/'test.cpp'
    exe=Path(d)/'test'
    src.write_text(code)
    subprocess.run(['c++','-std=c++17','-Wall','-Wextra','-Werror',str(src),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)

# Exercise the shared handoff with external playback labeled "scroll", where
# calling stopFirmwareScroll previously forced a blank for every streamed frame.
handoff_code = r'''
#include <cassert>
#include <cstring>
#include <string>
bool deferred=true, active=true, autoMode=true;
unsigned generation=0, queued=3, blanks=0;
std::string playback="scroll";
void cancelDeferredFaceRestore(){deferred=false;}
void scrollSessionStop(bool restoreAuto,bool clearDisplay){
 assert(!restoreAuto);
 if(clearDisplay) ++blanks;
 ++generation; active=false; playback="frame";
}
void clearQueuedPackedFrames(){queued=0;}
bool setMode(const char* mode,bool persist){
 assert(!persist && !active && playback!="scroll");
 assert(strcmp(mode,"manual")==0); autoMode=false; return true;
}
'''+function('faces.cpp','void takeOverExternalFrame(')+r'''
int main(){
 for(unsigned i=1;i<=100;++i){
  playback="scroll"; queued=3; deferred=true;
  takeOverExternalFrame();
  assert(!active && !autoMode && !deferred && queued==0);
  assert(generation==i && blanks==0);
 }
}
'''
with tempfile.TemporaryDirectory(prefix='rina-handoff-test-') as d:
    src=Path(d)/'test.cpp'
    exe=Path(d)/'test'
    src.write_text(handoff_code)
    subprocess.run(['c++','-std=c++17','-Wall','-Wextra','-Werror',str(src),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
print('PASS: external frame handoff cancels auto/deferred/queue/upload ownership without blank (100 frames)')
