/* WebUI test helper + packed-frame protocol bridge. Loaded after app.js. */
(function(){
  "use strict";
  if(window.__packedFrameBridge)return;
  window.__packedFrameBridge=true;
  var N=370,B=47,OLD_KEY='m'+'370';
  var originalUpload=window.apiPostWithUploadProgress;

  function boolFrame(){return new Array(N).fill(false);}
  function isByteArray(v){
    return Array.isArray(v)&&v.length===B&&v.every(function(x){x=Number(x);return Number.isInteger(x)&&x>=0&&x<=255;});
  }
  function bytesFromFrame(frame){
    if(frame instanceof Uint8Array&&frame.length===B)return new Uint8Array(frame);
    if(isByteArray(frame))return new Uint8Array(frame.map(function(v){return Number(v)&255;}));
    var out=new Uint8Array(B),src=Array.prototype.slice.call(frame||[]);
    for(var i=0;i<N;i++)if(src[i])out[i>>3]|=1<<(i&7);
    out[B-1]&=3;
    return out;
  }
  function frameFromBytes(bytes){
    var b=bytesFromFrame(bytes),f=boolFrame();
    for(var i=0;i<N;i++)f[i]=!!(b[i>>3]&(1<<(i&7)));
    return f;
  }
  function hexFromBytes(bytes){
    var b=bytesFromFrame(bytes),s='';
    for(var i=0;i<B;i++)s+=b[i].toString(16).padStart(2,'0');
    return s.toUpperCase();
  }
  function legacyHexToFrame(text){
    var s=String(text||'').trim();
    if(s.toUpperCase().indexOf('M'+'370:')===0)s=s.slice(5);
    s=s.replace(/\s+/g,'');
    var f=boolFrame();
    if(!/^[0-9a-fA-F]{93}$/.test(s))return f;
    for(var i=0;i<N;i++){
      var nib=parseInt(s[Math.floor(i/4)],16);
      f[i]=!!(nib&(1<<(3-(i&3))));
    }
    return f;
  }
  function legacyBytePairsToFrame(bytes){
    var b=bytesFromFrame(bytes),hex='';
    for(var i=0;i<B;i++)hex+=b[i].toString(16).padStart(2,'0');
    return legacyHexToFrame(hex.slice(0,93));
  }
  function parsePackedFrameText(text){
    var s=String(text||'').trim();
    if(!s)throw new Error('packed frame 不能为空');
    if(/^\s*\[/.test(s)){
      var arr=JSON.parse(s);
      if(!isByteArray(arr))throw new Error('packed frame JSON 数组必须是 47 个 0..255 byte');
      return frameFromBytes(arr);
    }
    var compact=s.replace(/\s+/g,''),upper=compact.toUpperCase();
    if(upper.indexOf('PACKED:')===0)compact=compact.slice(7);
    else if(upper.indexOf('FRAME:')===0)compact=compact.slice(6);
    else if(upper.indexOf('HEX:')===0)compact=compact.slice(4);
    upper=compact.toUpperCase();
    if(/^[0-9a-fA-F]{94}$/.test(compact)){
      var out=[];
      for(var i=0;i<B;i++)out.push(parseInt(compact.slice(i*2,i*2+2),16));
      return frameFromBytes(out);
    }
    if(upper.indexOf('M'+'370:')===0||/^[0-9a-fA-F]{93}$/.test(compact))return legacyHexToFrame(compact);
    try{
      var bin=atob(compact.replace(/^BASE64:/i,''));
      if(bin.length===B){var bytes=[];for(var j=0;j<B;j++)bytes.push(bin.charCodeAt(j)&255);return frameFromBytes(bytes);}
    }catch(e){}
    throw new Error('packed frame 必须是 94 个 hex 字符、47-byte JSON 数组或 47-byte base64');
  }
  function validatePackedFrameText(text){
    try{
      var frame=parsePackedFrameText(text);
      return{valid:true,normalizedLen:hexFromBytes(bytesFromFrame(frame)).length,expectedLen:94,hadPrefix:/^\s*(PACKED|FRAME|HEX):/i.test(String(text||'')),error:''};
    }catch(err){
      var compact=String(text||'').replace(/\s+/g,'');
      return{valid:false,normalizedLen:compact.length,expectedLen:94,hadPrefix:/^\s*(PACKED|FRAME|HEX|M370):/i.test(String(text||'')),error:err.message||String(err)};
    }
  }
  function frameText(frame){return hexFromBytes(bytesFromFrame(frame));}
  function faceToFrame(face){
    if(!face)return boolFrame();
    if(isByteArray(face.frameBytes))return frameFromBytes(face.frameBytes);
    if(typeof face[OLD_KEY]==='string')return legacyHexToFrame(face[OLD_KEY]);
    return boolFrame();
  }
  function postFrame(frame,reason,playback){
    var payload=bytesFromFrame(frame).buffer;
    var path='/api/frame?reason='+encodeURIComponent(reason||'webui_frame')+'&playback='+encodeURIComponent(playback||'idle');
    return apiPost(path,payload,{silent:false,expectJson:true,timeoutMs:2500});
  }
  function addParam(params,key,value){if(value!==undefined&&value!==null&&value!=='')params.append(key,String(value));}
  function uploadPackedScroll(path,payload,onProgress){
    payload=payload||{};
    var frames=Array.isArray(payload.frames)?payload.frames:[];
    var bytes=new Uint8Array(frames.length*B);
    for(var i=0;i<frames.length;i++)bytes.set(bytesFromFrame(frames[i]),i*B);
    var params=new URLSearchParams();
    addParam(params,'append',payload.append?1:0);
    addParam(params,'start',payload.start?1:0);
    addParam(params,'intervalMs',payload.intervalMs);
    addParam(params,'fps',payload.fps);
    addParam(params,'chunkIndex',payload.chunkIndex);
    addParam(params,'totalFrames',payload.totalFrames);
    addParam(params,'source',payload.source);
    addParam(params,'timelineId',payload.timelineId);
    addParam(params,'sourceText',payload.sourceText);
    addParam(params,'fontId',payload.fontId);
    addParam(params,'generatorVersion',payload.generatorVersion);
    var base=(typeof apiUrl==='function'?apiUrl(path):path),url=base+'?'+params.toString();
    return new Promise(function(resolve,reject){
      var xhr=new XMLHttpRequest();
      xhr.open('POST',url,true);
      xhr.timeout=60000;
      xhr.setRequestHeader('Content-Type','application/octet-stream');
      xhr.setRequestHeader('Accept','application/json');
      xhr.upload.onprogress=function(ev){if(ev.lengthComputable&&ev.total>0&&onProgress)onProgress(ev.loaded/ev.total);};
      xhr.onload=function(){
        if(xhr.status<200||xhr.status>=300){reject(new Error(xhr.status+' '+(xhr.statusText||'')));return;}
        try{resolve(JSON.parse(xhr.responseText||'{"ok":true}'));}catch(e){resolve({ok:true});}
      };
      xhr.onerror=function(){reject(new Error('scroll upload failed'));};
      xhr.ontimeout=function(){reject(new Error('scroll upload timeout'));};
      xhr.send(bytes.buffer);
    });
  }
  if(typeof apiPostWithUploadProgress==='function'){
    window.apiPostWithUploadProgress=function(path,payload,onProgress){
      if(String(path||'').indexOf('/api/scroll')>=0)return uploadPackedScroll(path,payload,onProgress);
      return originalUpload(path,payload,onProgress);
    };
    try{apiPostWithUploadProgress=window.apiPostWithUploadProgress;}catch(e){}
  }

  window.frameToPackedBytes=bytesFromFrame;
  window.packedBytesToFrame=frameFromBytes;
  window.packedFrameToText=frameText;
  window.parsePackedFrameText=parsePackedFrameText;
  window.validatePackedFrameText=validatePackedFrameText;
  window.frameToM370=frameText;try{frameToM370=frameText;}catch(e){}
  window.m370ToFrame=parsePackedFrameText;try{m370ToFrame=parsePackedFrameText;}catch(e){}
  window.validateM370Input=validatePackedFrameText;try{validateM370Input=validatePackedFrameText;}catch(e){}
  window.parseM370ToFrameOrError=function(text){try{return{frame:parsePackedFrameText(text)};}catch(err){return{error:err.message||String(err)}}};
  try{parseM370ToFrameOrError=window.parseM370ToFrameOrError;}catch(e){}
  window.queueFirmwareFrame=function(frame,reason,playback){
    var packet={type:'packed_frame',reason:reason||'frame_update',playback:playback||'idle',at:Date.now()};
    packet.promise=postFrame(frame,packet.reason,packet.playback).then(function(data){
      try{if(data&&typeof applyFirmwareRuntimeState==='function')applyFirmwareRuntimeState(data,packet.reason);}catch(e){}
      return data;
    });
    return packet;
  };
  window.queueFirmwareLedDeltas=function(changes,reason,playback){
    var frame=[];
    try{frame=(liveSyncedFrame||currentFrame||[]).slice();}catch(e){}
    for(var i=0;i<N;i++)frame[i]=!!frame[i];
    for(var j=0;j<(changes||[]).length;j++){
      var idx=Number(changes[j]&&changes[j][0]);
      if(idx>=0&&idx<N)frame[idx]=!!changes[j][1];
    }
    return window.queueFirmwareFrame(frame,reason||'live_delta',playback||'idle');
  };
  function normalizeType(v){
    return typeof normalizeFaceType==='function'?normalizeFaceType(v):String(v||'custom').toLowerCase().includes('part')?'parts':String(v||'custom').toLowerCase().includes('default')?'default':'custom';
  }
  function nameFromId(id){return String(id||'face').replace(/^face_?/,'').replace(/_/g,' ').replace(/\b\w/g,function(c){return c.toUpperCase();});}
  function normFace(f,i,fallback,legacy){
    if(!f||typeof f!=='object')return null;
    var type=normalizeType(f.type||f.source||fallback||'custom'),id=String(f.id||type+'_'+(i+1));
    var frame=isByteArray(f.frameBytes)?(legacy?legacyBytePairsToFrame(f.frameBytes):frameFromBytes(f.frameBytes)):(typeof f[OLD_KEY]==='string'?legacyHexToFrame(f[OLD_KEY]):null);
    if(!frame)return null;
    return{id:id,name:String(f.name||nameFromId(id)).slice(0,64),type:type,frameBytes:Array.from(bytesFromFrame(frame)),order:Number.isFinite(Number(f.order))?Number(f.order):i+1,editable:f.editable!==false,deletable:type!=='default'&&f.deletable!==false,locked:type==='default'||!!f.locked,is_startup_default:!!f.is_startup_default||id==='face_08_triangle_eyes_frown',sourceFile:'saved_faces.json',savedAt:f.savedAt||f.createdAt||null,updatedAt:f.updatedAt||null,call:f.call||null};
  }
  function preferred(faces){return((faces||[]).find(function(f){return f.id==='face_08_triangle_eyes_frown';})||(faces||[]).find(function(f){return f.is_startup_default;})||(faces||[]).find(function(f){return f.type==='default';})||(faces||[])[0]||{}).id||null;}
  window.normalizeFace=function(f,i,fallback){return normFace(f,i,fallback,false);};try{normalizeFace=window.normalizeFace;}catch(e){}
  window.normalizeFaceDocument=function(doc,fallback){
    var src=(doc&&typeof doc==='object'&&!Array.isArray(doc))?doc:{faces:Array.isArray(doc)?doc:[]};
    var legacy=String(src.format||'')==='rina_packed_faces_370_v1'||String(src.matrix&&src.matrix.frameEncoding||'')==='legacy-byte-pair-frame';
    var faces=(Array.isArray(src.faces)?src.faces:[]).map(function(f,i){return normFace(f,i,fallback||'custom',legacy);}).filter(Boolean);
    return{format:'rina_packed_faces_370_v2',version:4,category:'unified_saved_faces',matrix:{leds:N,frameBytes:B,frameEncoding:'packed-lsb-first'},startupDefaultId:preferred(faces),updatedAt:src.updatedAt||null,faces:faces};
  };try{normalizeFaceDocument=window.normalizeFaceDocument;}catch(e){}
  window.buildUnifiedFaceDocument=function(){
    var lib=(typeof getAllFaces==='function'?getAllFaces():[]).map(function(f,i){return normFace(Object.assign({},f,{order:i+1}),i,f.type||'custom',false);}).filter(Boolean);
    return{format:'rina_packed_faces_370_v2',version:4,category:'unified_saved_faces',matrix:{leds:N,frameBytes:B,frameEncoding:'packed-lsb-first'},startupDefaultId:preferred(lib),updatedAt:new Date().toISOString(),faces:lib};
  };try{buildUnifiedFaceDocument=window.buildUnifiedFaceDocument;}catch(e){}
  window.getSavedFaceFrame=function(i){var f=(typeof getAllFaces==='function'?getAllFaces()[i]:null);return faceToFrame(f);};try{getSavedFaceFrame=window.getSavedFaceFrame;}catch(e){}
  window.applySavedFace=function(i,reason){
    var lib=typeof getAllFaces==='function'?getAllFaces():[],f=lib[i];
    if(!f)return;
    if(typeof state==='object')state.faceIndex=i;
    if(typeof setCurrentFrame==='function')setCurrentFrame(faceToFrame(f),reason||'saved_face_apply','idle');
    if(typeof renderSavedFaces==='function')renderSavedFaces();
  };try{applySavedFace=window.applySavedFace;}catch(e){}
  window.saveFace=function(name,frame,type){
    var t=normalizeType(type),clean=(String(name||'face').trim().slice(0,64)||'face'),all=typeof getAllFaces==='function'?getAllFaces():[];
    var next=Math.max(0,...all.map(function(f){return Number(f.order)||0;}))+1;
    var face={id:t+'_'+Date.now(),name:clean,type:t,frameBytes:Array.from(bytesFromFrame(frame)),order:next,editable:true,deletable:true,locked:false,is_startup_default:false,sourceFile:'saved_faces.json',savedAt:new Date().toISOString(),updatedAt:new Date().toISOString(),call:t==='parts'&&typeof selectedCall==='object'?Object.assign({},selectedCall):null};
    if(typeof userFaces!=='undefined')userFaces.push(face);
    if(typeof state==='object')state.faceIndex=typeof getAllFaces==='function'?getAllFaces().findIndex(function(f){return f.id===face.id;}):0;
    if(typeof renderSavedFaces==='function')renderSavedFaces();
    if(typeof renderState==='function')renderState();
    if(typeof persistFaceDocumentsAndRefresh==='function')persistFaceDocumentsAndRefresh('save_packed_face');
  };try{saveFace=window.saveFace;}catch(e){}
  window.buildFirmwareScrollFrames=async function(onProgress){
    var src=(typeof scroll==='object'&&Array.isArray(scroll.frames))?scroll.frames:[],out=[];
    for(var i=0;i<src.length;i++){
      out.push(Array.from(bytesFromFrame(src[i])));
      if(onProgress&&(i===0||i===src.length-1||i%32===0)){onProgress((i+1)/src.length);await new Promise(function(r){requestAnimationFrame(r);});}
    }
    return out;
  };try{buildFirmwareScrollFrames=window.buildFirmwareScrollFrames;}catch(e){}
  window.applyKnownFaceIndexLocal=function(reason){
    var lib=typeof getAllFaces==='function'?getAllFaces():[];
    if(!lib.length)return false;
    var idx=Math.max(0,Math.min(Number(state&&state.faceIndex)||0,lib.length-1));
    var f=lib[idx];
    if(!f)return false;
    try{currentFrame=faceToFrame(f);scrollFrame=currentFrame.slice();}catch(e){}
    if(typeof renderMatrices==='function')renderMatrices();
    if(typeof renderSavedFaces==='function')renderSavedFaces();
    return true;
  };try{applyKnownFaceIndexLocal=window.applyKnownFaceIndexLocal;}catch(e){}
  window.applyStartupDefaultFaceLocal=function(reason){
    var idx=typeof startupDefaultFaceIndex==='function'?startupDefaultFaceIndex():0;
    var f=(typeof getAllFaces==='function'?getAllFaces()[idx]:null);
    if(!f)return false;
    if(typeof state==='object')state.faceIndex=idx;
    try{currentFrame=faceToFrame(f);scrollFrame=currentFrame.slice();}catch(e){}
    if(typeof renderMatrices==='function')renderMatrices();
    if(typeof renderSavedFaces==='function')renderSavedFaces();
    return true;
  };try{applyStartupDefaultFaceLocal=window.applyStartupDefaultFaceLocal;}catch(e){}

  function relabelProtocolControls(){
    var labels={};
    labels['custom-copy']='复制 packed frame';
    labels['custom-import']='从 packed frame 导入到画板';
    labels['parts-copy-'+OLD_KEY]='复制 packed frame';
    labels['parts-import-'+OLD_KEY]='从 packed frame 导入到当前输出';
    labels['debug-'+OLD_KEY+'-preview']='解析为预览';
    labels['debug-'+OLD_KEY+'-send']='解析并发送固件';
    labels['debug-'+OLD_KEY+'-clear']='清空输入';
    labels['debug-'+OLD_KEY+'-copy']='复制调试预览 packed frame';
    labels['debug-preview-copy']='复制调试预览 packed frame';
    Object.keys(labels).forEach(function(id){var el=document.getElementById(id);if(el)el.textContent=labels[id];});
    ['custom-'+OLD_KEY,'parts-'+OLD_KEY+'-text','debug-'+OLD_KEY].forEach(function(id){var el=document.getElementById(id);if(el)el.setAttribute('placeholder','输入 94 hex packed frame、47-byte JSON 数组或 base64');});
    var lab=document.querySelector('#debug-protocol-lab h3');
    if(lab)lab.textContent='LED 测试 / Packed Frame 协议实验室';
    document.querySelectorAll('#debug-protocol-lab h4').forEach(function(h){if(/M\s*370|Packed Frame 输入/i.test(h.textContent))h.textContent='Packed Frame 输入 / 调试';});
    document.querySelectorAll('.hint').forEach(function(el){
      if(/M\s*370|M370/.test(el.textContent))el.innerHTML=el.innerHTML.replace(/M\s*370|M370/g,'packed frame');
    });
  }
  window.__relabelPackedProtocolControls=relabelProtocolControls;
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',function(){setTimeout(relabelProtocolControls,0);});
  else setTimeout(relabelProtocolControls,0);
})();

/* Full WebUI test instrumentation restored from the pre-packed-refactor harness. */
(function(){
  "use strict";
  if(window.__ui)return;
  var SELECTOR=["button","a[href]","input:not([type=hidden])","select","textarea","summary",'[role="button"]','[role="menuitem"]',"[data-gpio]","[onclick]"].join(',');
  var registry=new Map(),usedCodes=new Set(),idSeq=0,badgesOn=false,badgeLayer=null,debounceT=null;
  function slug(s){return(s||'').toString().trim().toLowerCase().replace(/\s+/g,'-').replace(/[^a-z0-9\-_]/g,'').replace(/-+/g,'-').replace(/^-|-$/g,'').slice(0,40);}
  function pageOf(el){var sec=el.closest&&el.closest('section.page, section[id]');return sec&&sec.id?sec.id:'';}
  function labelOf(el){
    var t=el.getAttribute('aria-label')||(el.tagName==='INPUT'||el.tagName==='TEXTAREA'?el.getAttribute('placeholder')||el.getAttribute('name')||el.getAttribute('title'):'')||(el.textContent||'').replace(/\s+/g,' ').trim()||el.getAttribute('title')||el.value||'';
    return String(t).slice(0,60);
  }
  function codeFor(testid){var h=5381;for(var i=0;i<testid.length;i++)h=((h<<5)+h+testid.charCodeAt(i))>>>0;var code=1000+(h%9000);while(usedCodes.has(code))code=1000+((code+1-1000)%9000);usedCodes.add(code);return code;}
  function deriveTestid(el){
    if(el.id)return el.id;
    if(el.getAttribute('data-gpio'))return 'gpio-'+el.getAttribute('data-gpio');
    var parts=[el.tagName.toLowerCase()],page=pageOf(el);if(page)parts.push(page.replace(/^page-/,''));
    var s=slug(labelOf(el));if(s)parts.push(s);
    var base=parts.join('-')||'ctl',testid=base,n=2;
    while(registry.has(testid)&&registry.get(testid).el!==el)testid=base+'-'+n++;
    return testid;
  }
  function tag(el){
    if(el.__uiTestid&&registry.has(el.__uiTestid)&&registry.get(el.__uiTestid).el===el)return;
    var testid=el.getAttribute('data-testid')||deriveTestid(el),code;
    if(registry.has(testid)&&registry.get(testid).el===el)code=registry.get(testid).code;
    else code=el.getAttribute('data-test-code')?parseInt(el.getAttribute('data-test-code'),10):codeFor(testid);
    el.setAttribute('data-testid',testid);el.setAttribute('data-test-code',String(code));el.__uiTestid=testid;registry.set(testid,{code:code,el:el});idSeq++;
  }
  function scan(){
    try{if(typeof window.__relabelPackedProtocolControls==='function')window.__relabelPackedProtocolControls();}catch(e){}
    var nodes=document.querySelectorAll(SELECTOR);
    for(var i=0;i<nodes.length;i++){try{tag(nodes[i]);}catch(e){}}
    if(badgesOn)renderBadges();
  }
  function resolve(ref){
    if(ref==null)return null;
    var asNum=typeof ref==='number'?ref:/^\d+$/.test(String(ref))?parseInt(ref,10):null;
    if(asNum!=null){for(var en of registry.values())if(en.code===asNum)return en.el;var byAttr=document.querySelector('[data-test-code="'+asNum+'"]');if(byAttr)return byAttr;}
    if(registry.has(ref))return registry.get(ref).el;
    return document.querySelector('[data-testid="'+String(ref).replace(/"/g,'')+'"]')||document.getElementById(String(ref));
  }
  function visible(el){return !!(el.offsetParent||el.getClientRects().length)&&!el.hasAttribute('hidden');}
  function entry(el){
    var r=el.getBoundingClientRect();
    return{code:parseInt(el.getAttribute('data-test-code'),10),testid:el.getAttribute('data-testid'),label:labelOf(el),tag:el.tagName.toLowerCase(),type:el.getAttribute('type')||el.getAttribute('role')||el.getAttribute('data-gpio')||'',page:pageOf(el),visible:visible(el),disabled:!!el.disabled||el.getAttribute('aria-disabled')==='true',value:el.tagName==='INPUT'&&el.type==='checkbox'?!!el.checked:'value' in el?el.value:undefined,rect:{x:Math.round(r.x),y:Math.round(r.y),w:Math.round(r.width),h:Math.round(r.height)}};
  }
  function ensureBadgeLayer(){
    if(badgeLayer)return badgeLayer;
    var s=document.createElement('style');
    s.textContent='.__ui_badge{position:fixed;z-index:2147483647;background:#ff1f8f;color:#fff;font:700 10px/1.2 monospace;padding:1px 3px;border-radius:4px;pointer-events:none;box-shadow:0 0 0 1px #fff}';
    document.head.appendChild(s);
    badgeLayer=document.createElement('div');badgeLayer.id='__ui_badge_layer';document.body.appendChild(badgeLayer);return badgeLayer;
  }
  function renderBadges(){
    var layer=ensureBadgeLayer();layer.innerHTML='';
    for(var e of registry.values()){
      if(!visible(e.el))continue;
      var r=e.el.getBoundingClientRect();if(r.width===0&&r.height===0)continue;
      var b=document.createElement('div');b.className='__ui_badge';b.textContent=e.code;b.style.left=Math.max(0,r.left)+'px';b.style.top=Math.max(0,r.top)+'px';layer.appendChild(b);
    }
  }
  function rescanSoon(){clearTimeout(debounceT);debounceT=setTimeout(scan,120);}

  window.__ui={
    version:'1.1-packed-frame-bridge',
    list:function(opts){opts=opts||{};var out=[];for(var e of registry.values()){if(!e.el.isConnected)continue;if(opts.visibleOnly&&!visible(e.el))continue;if(opts.page&&pageOf(e.el)!==opts.page)continue;var info=entry(e.el);if(opts.type&&info.type!==opts.type)continue;out.push(info);}out.sort(function(a,b){return a.rect.y-b.rect.y||a.rect.x-b.rect.x;});return out;},
    find:function(substr){substr=String(substr||'').toLowerCase();return this.list().filter(function(e){return(e.testid+' '+e.label).toLowerCase().indexOf(substr)>=0;});},
    click:function(ref){var el=resolve(ref);if(!el)return{ok:false,error:'not found: '+ref};if(el.scrollIntoView)el.scrollIntoView({block:'center',inline:'center'});var label=labelOf(el);try{el.focus&&el.focus();el.click();return{ok:true,testid:el.getAttribute('data-testid'),label:label};}catch(e){return{ok:false,error:String(e)}}},
    setValue:function(ref,val){var el=resolve(ref);if(!el)return{ok:false,error:'not found: '+ref};try{if(el.type==='checkbox')el.checked=!!val;else el.value=val;el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));return{ok:true,testid:el.getAttribute('data-testid'),value:el.value};}catch(e){return{ok:false,error:String(e)}}},
    get:function(ref){var el=resolve(ref);if(!el)return{ok:false,error:'not found: '+ref};return{ok:true,testid:el.getAttribute('data-testid'),value:entry(el).value,text:(el.textContent||'').trim(),ariaPressed:el.getAttribute('aria-pressed'),disabled:entry(el).disabled};},
    gpio:function(code){var el=document.querySelector('[data-gpio="'+code+'"]');if(!el)return{ok:false,error:'no gpio button: '+code};el.click();return{ok:true,gpio:code};},
    pages:function(){return Array.prototype.map.call(document.querySelectorAll('section.page, section[id]'),function(s){return{id:s.id,active:s.classList.contains('active')};});},
    nav:function(){return this.list().filter(function(e){return e.type==='menuitem'||e.testid.indexOf('nav')>=0;});},
    badges:function(on){badgesOn=on!==false;if(badgesOn)renderBadges();else if(badgeLayer)badgeLayer.innerHTML='';return{badges:badgesOn};},
    rescan:function(){scan();return{count:registry.size};},
    count:function(){return registry.size;}
  };
  function bridgePayloadFromEvent(ev){
    if(ev&&ev.detail){if(typeof ev.detail==='string'){try{return JSON.parse(ev.detail);}catch(e){return{id:'',method:'',args:[],parseError:String(e)}}}return ev.detail;}
    var raw=document.documentElement.getAttribute('data-ui-bridge-request')||'';if(!raw)return{};try{return JSON.parse(raw);}catch(e){return{id:'',method:'',args:[],parseError:String(e)}}
  }
  function installDomBridge(){
    document.addEventListener('__ui:call',function(ev){
      var req=bridgePayloadFromEvent(ev),id=req&&req.id!=null?String(req.id):'',result;
      try{
        if(req.parseError)throw new Error(req.parseError);
        if(!req||!req.method||!Object.prototype.hasOwnProperty.call(window.__ui,req.method)||typeof window.__ui[req.method]!=='function')throw new Error('unknown method: '+(req&&req.method));
        result={id:id,ok:true,result:window.__ui[req.method].apply(window.__ui,Array.isArray(req.args)?req.args:[])};
      }catch(e){result={id:id,ok:false,error:String(e&&e.message?e.message:e)};}
      var json=JSON.stringify(result);document.documentElement.setAttribute('data-ui-bridge-result',json);document.dispatchEvent(new CustomEvent('__ui:response',{detail:json}));
    });
    document.documentElement.setAttribute('data-ui-bridge','ready');
  }
  installDomBridge();
  function init(){
    scan();setTimeout(scan,400);setTimeout(scan,1500);
    try{new MutationObserver(rescanSoon).observe(document.body,{childList:true,subtree:true});}catch(e){}
    window.addEventListener('resize',function(){if(badgesOn)renderBadges();});
    window.addEventListener('scroll',function(){if(badgesOn)renderBadges();},true);
    if(/[?&]ui_badges=1/.test(location.search))window.__ui.badges(true);
    console.info('[__ui] WebUI test harness ready; controls='+registry.size+'. Try __ui.list()');
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
})();

/* Runtime safety patch for 6.2/6.3 live LED output. */
(function(){
  "use strict";
  if(window.__rinaLiveOutputPatchInstalled)return;
  window.__rinaLiveOutputPatchInstalled=true;
  function safeLog(message,level){try{if(typeof log==='function')log(message,level||'debug');}catch(e){}}
  function currentPlaybackIsScroll(){try{return typeof isScrollPlaybackValue==='function'&&isScrollPlaybackValue(state.playback);}catch(e){return false;}}
  function forceManualUiForLiveOutput(reason){
    try{
      if(typeof state==='undefined')return;
      var wasAuto=typeof isAutoModeValue==='function'&&isAutoModeValue(state.mode);
      var wasScroll=!!state.textScrollActive||currentPlaybackIsScroll();
      if(!wasAuto&&!wasScroll&&state.mode==='manual')return;
      if(typeof guardBeforeOutput==='function'&&(wasAuto||wasScroll))guardBeforeOutput(reason||'custom_live_send','idle');
      state.mode='manual';
      if(wasScroll||currentPlaybackIsScroll())state.playback='idle';
      state.textScrollActive=false;
      if(typeof renderState==='function')renderState();
    }catch(err){console.warn('[rina-live-patch] force manual failed',err);}
  }
  function liveEnabledNow(){try{return typeof liveSendEnabled!=='undefined'&&!!liveSendEnabled;}catch(e){return false;}}
  if(typeof prepareForTextScrollUpload==='function'){
    var originalPrepareForTextScrollUpload=prepareForTextScrollUpload;
    prepareForTextScrollUpload=async function patchedPrepareForTextScrollUpload(){
      var restoreLiveAfterPrepare=liveEnabledNow();
      try{return await originalPrepareForTextScrollUpload.apply(this,arguments);}finally{
        try{if(restoreLiveAfterPrepare&&!liveEnabledNow()&&typeof setLiveSendEnabled==='function')setLiveSendEnabled(true,'文字滚动准备结束');}catch(err){console.warn('[rina-live-patch] live restore after scroll prepare failed',err);}
      }
    };
  }
  if(typeof sendCustomFrameIfLive==='function'){
    var originalSendCustomFrameIfLive=sendCustomFrameIfLive;
    sendCustomFrameIfLive=function patchedSendCustomFrameIfLive(reason){
      var liveReason=reason||'custom_live_send';
      if(!liveEnabledNow()){safeLog('自定义实时发送已关闭：本次 LED 点击只更新本地画板，未发送到固件','debug');return null;}
      forceManualUiForLiveOutput(liveReason);
      return originalSendCustomFrameIfLive.apply(this,arguments.length?arguments:[liveReason]);
    };
  }
  if(typeof sendPartsFrameIfLive==='function'){
    var originalSendPartsFrameIfLive=sendPartsFrameIfLive;
    sendPartsFrameIfLive=function patchedSendPartsFrameIfLive(reason){
      var liveReason=reason||'parts_live_send';
      if(!liveEnabledNow()){safeLog('部件实时发送已关闭：本次选择只更新本地预览，未发送到固件','debug');return null;}
      forceManualUiForLiveOutput(liveReason);
      return originalSendPartsFrameIfLive.apply(this,arguments.length?arguments:[liveReason]);
    };
  }
})();