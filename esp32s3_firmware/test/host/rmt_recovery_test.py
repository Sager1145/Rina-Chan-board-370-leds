#!/usr/bin/env python3
"""Fault-inject the production RMT recovery functions with a host C++ compiler.

Run from any directory: python3 esp32s3_firmware/test/host/rmt_recovery_test.py
The SDK calls are mocked; this checks recovery ordering and buffer ownership,
not actual RMT timing or hardware behaviour.
"""
import subprocess
import tempfile
from pathlib import Path
src=(Path(__file__).resolve().parents[2] / 'src/led_driver.cpp').read_text().split('#elif RINACHAN_LED_BACKEND == RINACHAN_LED_BACKEND_RMT')[1]
def extract(sig):
 s=src.index(sig); a=src.index('{',s); n=1; i=a+1
 while n:
  n+=(src[i]=='{')-(src[i]=='}'); i+=1
 return src[s:i]
prefix=r'''
#include <cstdint>
#include <cstring>
#include <cassert>
#include <vector>
#include <cstdio>
using esp_err_t=int;
constexpr int ESP_OK=0, ESP_ERR_TIMEOUT=1, ESP_FAIL=2, LED_COUNT=370;
static bool sReady=true;
static int sChannel=1,sEncoder=1;
static uint32_t sRefreshFail=0;
static uint8_t sPixels[LED_COUNT*3]={},sBrightness=255;
static std::vector<int> calls;
static bool timeoutTx=false,failDisable=false,failDrain=false,failReset=false,failEnable=false,failSubmit=false;
struct rmt_transmit_config_t { int loop_count; struct { unsigned queue_nonblocking; } flags; };
unsigned micros(){return 1;}
void recordRefresh(unsigned,bool){}
uint8_t scale8(uint8_t x,uint8_t b){return unsigned(x)*b/255;}
const char* backendName(){return "mock";}
#define RLOG_WARN(...) ((void)0)
int rmt_transmit(int,int,void*,unsigned,const rmt_transmit_config_t* c){assert(c->flags.queue_nonblocking);calls.push_back(1);return failSubmit?ESP_FAIL:ESP_OK;}
int rmt_tx_wait_all_done(int,int ms){calls.push_back(ms?2:4);return ms?(timeoutTx?ESP_ERR_TIMEOUT:ESP_OK):(failDrain?ESP_FAIL:ESP_OK);}
int rmt_disable(int){calls.push_back(3);return failDisable?ESP_FAIL:ESP_OK;}
int rmt_encoder_reset(int){calls.push_back(5);return failReset?ESP_FAIL:ESP_OK;}
int rmt_enable(int){calls.push_back(6);return failEnable?ESP_FAIL:ESP_OK;}
'''
tests=r'''
void reset(){sReady=true; calls.clear();timeoutTx=false;failDisable=false;failDrain=false;failReset=false;failEnable=false;failSubmit=false;memset(sPixels,17,sizeof(sPixels));}
int main(){
 reset();assert(refresh());assert((calls==std::vector<int>{1,2}));
 reset();timeoutTx=true;assert(!refresh());assert(sReady);assert((calls==std::vector<int>{1,2,3,4,5,6}));timeoutTx=false;assert(refresh());
 for(int stage=0;stage<4;++stage){
  reset();timeoutTx=true;
  if(stage==0)failDisable=true;if(stage==1)failDrain=true;if(stage==2)failReset=true;if(stage==3)failEnable=true;
  assert(!refresh());assert(!sReady);auto before=calls.size();setPixel(0,255,255,255);clear();assert(sPixels[0]==17);assert(!refresh());assert(calls.size()==before);
 }
 reset();failSubmit=true;assert(!refresh());assert((calls==std::vector<int>{1}));
 puts("RMT recovery fault injection: success, timeout recovery, four recovery failures, rejected submit passed");
}
'''
with tempfile.TemporaryDirectory(prefix="rina-rmt-test-") as directory:
    source = Path(directory) / "test.cpp"
    binary = Path(directory) / "test"
    source.write_text(prefix+'\n'.join(extract(s) for s in ['void setPixel(', 'void clear()', 'bool refresh()'])+tests)
    subprocess.run(["c++", "-std=c++17", "-Wall", "-Wextra", "-Werror", str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
