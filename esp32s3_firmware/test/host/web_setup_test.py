#!/usr/bin/env python3
"""Check embedded setup UI and execute its local-only flows with a fake DOM.

Requires Node.js for JavaScript parsing/execution; never opens a network socket.
"""
from html.parser import HTMLParser
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / "src/web_setup.cpp").read_text()
page = source.split('R"HTML(', 1)[1].split(')HTML";', 1)[0]
script = page.split("<script>", 1)[1].split("</script>", 1)[0]


class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = set()
        self.translation_keys = set()
        self.modes = set()

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.add(attrs["id"])
        for key in ("data-i18n", "data-i18n-placeholder"):
            if key in attrs:
                self.translation_keys.add(attrs[key])
        if tag == "option" and attrs.get("value") in {"off", "ap", "sta", "sta_or_ap"}:
            self.modes.add(attrs["value"])


parsed = Page()
parsed.feed(page)
assert not parsed.ids & {"hs", "hssid", "hpass", "hsMsg"}, "phone hotspot form remains"
assert parsed.modes == {"off", "ap", "sta", "sta_or_ap"}
assert {"ssid", "pass", "nets", "apssid", "appass", "modeSel"} <= parsed.ids
assert "/api/wifi/hotspot" not in script, "phone hotspot UI still submits credentials"

node = shutil.which("node")
if not node:
    raise SystemExit("Node.js is required to verify the embedded setup JavaScript")

probe = r'''
const fs = require('fs'), vm = require('vm'), assert = require('assert');
const fixture = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const elements = Object.fromEntries(fixture.ids.map(id => [id, {
  value:'', textContent:'', innerHTML:'', children:[], attrs:{},
  setAttribute(k,v){this.attrs[k]=v}, getAttribute(k){return this.attrs[k]},
  removeAttribute(k){delete this.attrs[k]}, appendChild(child){this.children.push(child)}
}]));
const calls=[];
const status={mode:'sta_or_ap',staConnected:true,ssid:'Fixture LAN',ip:'10.0.0.9',
  rssi:-40,apActive:true,apSsid:'Fixture board AP',apIp:'192.168.1.14',
  hostname:'fixture-board',clients:1,activeProfile:'home'};
const context={window:{}, navigator:{languages:['en']}, localStorage:{getItem(){},setItem(){}},
 document:{documentElement:{},getElementById(id){assert(id in elements,`missing DOM ${id}`);return elements[id]},
   querySelectorAll(){return []},createElement(){return {}}},
 setInterval(){},setTimeout(){throw new Error('unexpected incomplete scan')},
 fetch:async(url,options)=>{calls.push({url,options});assert(url.startsWith('/api/wifi/'));
   let reply=url==='/api/wifi/status'?status:{ok:true};
   if(url==='/api/wifi/scan'&&!options)reply={ok:true,scanning:false,networks:[{ssid:'Fixture LAN',rssi:-40,secure:true}]};
   return {json:async()=>reply}}};
vm.createContext(context);
vm.runInContext(fixture.script,context);
const drain=()=>new Promise(resolve=>setImmediate(resolve));
(async()=>{
 await drain();
 for(const [language,messages] of Object.entries(context.M)){
   for(const key of fixture.translation_keys)assert(key in messages,`${language}: missing ${key}`);
   for(const key of ['hotspot.phone','placeholder.phoneHotspot','profile.hotspot'])assert(!(key in messages));
   context.setLang(language);await drain();
 }
 context.scan();await drain();
 assert(elements.nets.children.length===1);elements.nets.children[0].onclick();
 assert(elements.ssid.value==='Fixture LAN');
 elements.pass.value='fixture password';context.connect();await drain();context.refresh();await drain();
 assert(context.window._connecting===false);
 elements.modeSel.value='ap';context.setMode();await drain();
 elements.apssid.value='Fixture board AP';elements.appass.value='fixture password';context.setAp();await drain();
 for(const url of ['/api/wifi/status','/api/wifi/scan','/api/wifi/credentials','/api/wifi/mode','/api/wifi/ap'])
   assert(calls.some(call=>call.url===url),`missing flow ${url}`);
 assert(!calls.some(call=>call.url==='/api/wifi/hotspot'));
 console.log('PASS: setup modes, translations, scan/select, local provisioning, board AP settings and valid DOM references');
})().catch(error=>{console.error(error);process.exitCode=1});
'''

with tempfile.TemporaryDirectory(prefix="rina-web-setup-") as directory:
    directory = Path(directory)
    js = directory / "page.js"
    js.write_text(script)
    subprocess.run([node, "--check", str(js)], check=True)
    fixture = directory / "fixture.json"
    fixture.write_text(json.dumps({"ids": sorted(parsed.ids), "translation_keys": sorted(parsed.translation_keys),
                                   "script": script}))
    harness = directory / "probe.js"
    harness.write_text(probe)
    subprocess.run([node, str(harness), str(fixture)], check=True)
