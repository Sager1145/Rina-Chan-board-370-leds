"""Run the production protocol host harness with one extra default-rename assertion.

No product edits or radio/hardware access; compilation and fake LittleFS stay in
its TemporaryDirectory. Existing harness requirements apply.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
source_path = ROOT / 'esp32s3_firmware/test/host/faces_transfer_test.py'
source = source_path.read_text()
needle = ' puts("PASS faces conditional writes, immutable RAM pages, generation invalidation, bulk commit conflict, display unchanged");'
probe = r'''
 const uint32_t beforeDefaultRename = savedFacesGeneration();
 auto renamedDefault = c.cmd(seq++, "{\"cmd\":\"face_rename\",\"payload\":{\"id\":\"f0\",\"name\":\"Renamed protected default\",\"expectedBootId\":\"transfer-boot\",\"expectedGen\":"+std::to_string(beforeDefaultRename)+"}}");
 assert(renamedDefault.first==0x81);
 assert(savedFacesGeneration()==beforeDefaultRename+1);
 assert(runtimeAutoFaces()[0].isDefault);
 assert(runtimeAutoFaces()[0].name=="Renamed protected default");
 puts("REPRO R4: production CMD face_rename commits a default face rename; App rejects the same action");
'''
assert source.count(needle) == 1
source = source.replace(needle, probe + needle)
exec(compile(source, str(source_path), 'exec'), {'__file__': str(source_path), '__name__': '__main__'})
