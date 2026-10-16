#!/usr/bin/env python3
"""Production protocol regressions: conditional writes, RAM paging, display isolation."""
from pathlib import Path
import os, shutil, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[3]
FW=ROOT/'esp32s3_firmware'
H=ROOT/'docs/stress-20260912-211559/tools/firmware'
with tempfile.TemporaryDirectory(prefix='rina-faces-transfer-') as directory:
 p=Path(directory);h=p/'tools/firmware';h.mkdir(parents=True)
 shutil.copytree(H/'stress_fakes',h/'stress_fakes')
 for name in ('stress_build.sh','stress_common.h'):shutil.copy2(H/name,h/name)
 os.symlink(FW/'src',p/'src');os.symlink(FW/'.pio',p/'.pio')
 source=h/'faces_transfer.cpp'
 source.write_text(r'''
#include "../../src/protocol.cpp"
#include "../../src/expression_parts.h"
#include "stress_common.h"
#include <cassert>
const char* boardBootId() { return "transfer-boot"; }
bool isBrightnessButtonCode(const String&) { return false; }
static std::string zeroFrameBytesJson(){std::string out="[";for(size_t i=0;i<FRAME_BYTES;++i){if(i)out+=",";out+="0";}return out+"]";}
int main(int argc,char**argv) {
 assert(argc==2);resetFakeFs(argv[1]);assert(mountFilesystem());
 std::string path=std::string(argv[1])+"/resources/saved_faces.json";
 std::string original="{\"category\":\"unified_saved_faces\",\"faces\":[";
 for(int i=0;i<64;++i){if(i)original+=",";original+="{\"id\":\"f"+std::to_string(i)+"\",\"name\":\"Face "+std::to_string(i)+"\",\"type\":\""+(i==0?std::string("default"):std::string("custom"))+"\",\"order\":"+std::to_string(i+1)+",\"frameBytes\":"+zeroFrameBytesJson()+"}";}
 original+="]}";writeFile(path,original);assert(loadSavedFaces(true));
 protocolBegin();initRuntimeScrollFrameBuffer();FakeTransport t;TestClient c;assert(c.connect(t));uint8_t seq=1;
 const auto before=readFrameStateSnapshot();
 auto stale=c.cmd(seq++,"{\"cmd\":\"face_rename\",\"payload\":{\"id\":\"f1\",\"name\":\"bad\",\"expectedBootId\":\"transfer-boot\",\"expectedGen\":99}}");
 assert(stale.first==0xFF);assert(parse(stale.second)["code"].as<int>()==409);assert(savedFacesGeneration()==0);
 auto wrongBoot=c.cmd(seq++,"{\"cmd\":\"face_delete\",\"payload\":{\"id\":\"f1\",\"expectedBootId\":\"old-boot\",\"expectedGen\":0}}");assert(wrongBoot.first==0xFF);
 std::string frame(94,'0');
 auto duplicate=c.cmd(seq++,"{\"cmd\":\"face_upsert\",\"payload\":{\"createOnly\":true,\"face\":{\"id\":\"f1\",\"name\":\"duplicate\",\"type\":\"custom\",\"frameHex\":\""+frame+"\"}}}");assert(duplicate.first==0xFF);assert(parse(duplicate.second)["code"].as<int>()==409);
 // First page pins a RAM projection. Even direct file damage cannot change later pages.
 auto first=c.request(msg::GET_FACES,seq++,{});assert(first.first==0xA4);assert(first.second.size()>4);
 auto unchanged=c.request(msg::GET_FACES,seq++,bytesOf("{\"offset\":0,\"gen\":0,\"bootId\":\"transfer-boot\",\"ifUnchanged\":true}"));assert(unchanged.first==0xA4);assert(unchanged.second.size()==4);
 std::string collected=first.second.substr(4);writeFile(path,"broken external flash content");
 while(true){auto page=c.request(msg::GET_FACES,seq++,bytesOf("{\"offset\":"+std::to_string(collected.size())+",\"gen\":0}"));assert(page.first==0xA4);auto data=page.second.substr(4);if(data.empty())break;collected+=data;}
 DynamicJsonDocument doc(savedFacesJsonCapacityFor(collected.size()));assert(!deserializeJson(doc,collected));assert(doc["faces"].size()==64);
 const auto after=readFrameStateSnapshot();assert(before.framesAccepted==after.framesAccepted);assert(before.litLeds==after.litLeds);assert(queuedPackedFrameCount()==0);
 writeFile(path,original);
 auto good=c.cmd(seq++,"{\"cmd\":\"face_rename\",\"payload\":{\"id\":\"f1\",\"name\":\"renamed\",\"expectedBootId\":\"transfer-boot\",\"expectedGen\":0}}");assert(good.first==0x81);assert(savedFacesGeneration()==1);
 auto oldPage=c.request(msg::GET_FACES,seq++,bytesOf("{\"offset\":10,\"gen\":0}"));assert(oldPage.first==0xFF);assert(parse(oldPage.second)["code"].as<int>()==409);
 // A bulk upload begun before another writer commits must fail at END.
 auto begin=c.request(msg::BLOB_BEGIN,seq++,bytesOf("{\"kind\":\"faces\",\"totalBytes\":2,\"expectedBootId\":\"transfer-boot\",\"expectedGen\":1}"));assert(begin.first==0xA0);
 std::vector<uint8_t> chunk={0,0,0,0,'{','}'};assert(c.request(msg::BLOB_CHUNK,seq++,chunk).first==0xA1);
 auto rename=c.cmd(seq++,"{\"cmd\":\"face_rename\",\"payload\":{\"id\":\"f1\",\"name\":\"later\"}}");assert(rename.first==0x81);
 auto end=c.request(msg::BLOB_END,seq++,{});assert(end.first==0xFF);assert(parse(end.second)["code"].as<int>()==409);
 // A default face keeps its name: rename is refused like delete/overwrite, and nothing commits.
 const uint32_t beforeDefaultRename=savedFacesGeneration();
 auto renamedDefault=c.cmd(seq++,"{\"cmd\":\"face_rename\",\"payload\":{\"id\":\"f0\",\"name\":\"Renamed default\",\"expectedBootId\":\"transfer-boot\",\"expectedGen\":"+std::to_string(beforeDefaultRename)+"}}");
 assert(renamedDefault.first==0xFF);assert(parse(renamedDefault.second)["code"].as<int>()==400);
 assert(savedFacesGeneration()==beforeDefaultRename);assert(runtimeAutoFaces()[0].isDefault);assert(runtimeAutoFaces()[0].name!="Renamed default");
 // face_upsert answers with the record as stored and expanded like GET_FACES,
 // so the app can confirm a save without reading the whole library back.
 {
  uint16_t ids[4];const char* raw[4]={"101","201","301","400"};
  for(int i=0;i<4;++i)assert(expression_parts::parseId(raw[i],ids[i]));
  uint8_t composed[FRAME_BYTES];assert(expression_parts::compose(ids,composed));
  char hex[FRAME_BYTES*2+1];writePackedFrameHex(composed,hex);
  const std::string call="\"call\":{\"leye\":\"101\",\"reye\":\"201\",\"mouth\":\"301\",\"cheek\":\"400\"}";
  const uint32_t g0=savedFacesGeneration();
  auto pure=c.cmd(seq++,"{\"cmd\":\"face_upsert\",\"payload\":{\"createOnly\":true,\"expectedBootId\":\"transfer-boot\",\"expectedGen\":"+std::to_string(g0)+",\"face\":{\"id\":\"user_pure\",\"name\":\"Pure\",\"type\":\"parts\",\"frameHex\":\""+hex+"\","+call+"}}}");
  assert(pure.first==0x81);auto pr=parse(pure.second);
  assert(pr["gen"].as<uint32_t>()==g0+1);
  JsonObject pf=pr["face"];assert(!pf.isNull());
  assert(std::string(pf["id"]|"")=="user_pure"&&std::string(pf["name"]|"")=="Pure");
  assert(std::string(pf["type"]|"")=="parts"&&std::string(pf["partsCatalog"]|"")==expression_parts::CATALOG);
  assert(pf["order"].as<int>()==65&&pf["frameBytes"].size()==FRAME_BYTES);
  for(size_t i=0;i<FRAME_BYTES;++i)assert(pf["frameBytes"][i].as<uint8_t>()==composed[i]);
  // A stale call with drawn pixels is stored, and reported, as custom.
  auto drawn=c.cmd(seq++,"{\"cmd\":\"face_upsert\",\"payload\":{\"expectedBootId\":\"transfer-boot\",\"expectedGen\":"+std::to_string(g0+1)+",\"face\":{\"id\":\"user_pure\",\"name\":\"Drawn\",\"type\":\"parts\",\"frameHex\":\""+frame+"\","+call+"}}}");
  assert(drawn.first==0x81);auto dr=parse(drawn.second);JsonObject df=dr["face"];
  assert(std::string(df["type"]|"")=="custom"&&df["call"].isNull()&&df["partsCatalog"].isNull());
  assert(std::string(df["name"]|"")=="Drawn"&&df["order"].as<int>()==65);
  for(size_t i=0;i<FRAME_BYTES;++i)assert(df["frameBytes"][i].as<uint8_t>()==0);
 }
 puts("PASS faces conditional writes, immutable RAM pages, generation invalidation, bulk commit conflict, display unchanged");
}
''')
 binary=p/'test'
 subprocess.run(['bash',str(h/'stress_build.sh'),str(source),str(binary),'asan'],check=True)
 subprocess.run([str(binary),str(p/'fakefs')],check=True)
