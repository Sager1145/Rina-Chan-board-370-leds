/* WebUI test helper + packed-frame protocol bridge. Loaded after app.js. */
(function(){
  if(window.__packedFrameBridge)return;
  window.__packedFrameBridge=true;
  var N=370,B=47,OLD_KEY='m'+'370';
  var originalUpload=window.apiPostWithUploadProgress;
  function boolFrame(){return new Array(N).fill(false);}
  function isByteArray(v){return Array.isArray(v)&&v.length===B&&v.every(function(x){x=Number(x);return Number.isInteger(x)&&x>=0&&x<=255;});}
  function bytesFromFrame(frame){
    if(frame instanceof Uint8Array&&frame.length===B)return new Uint8Array(frame);
    if(isByteArray(frame))return new Uint8Array(frame.map(function(v){return Number(v)&255;}));
    var out=new Uint8Array(B),src=Array.prototype.slice.call(frame||[]);
    for(var i=0;i<N;i++)if(src[i])out[i>>3]|=1<<(i&7);
    out[B-1]&=3;
    return out;
  }
  function frameFromBytes(bytes){var b=bytesFromFrame(bytes),f=boolFrame();for(var i=0;i<N;i++)f[i]=!!(b[i>>3]&(1<<(i&7)));return f;}
  function hexFromBytes(bytes){var b=bytesFromFrame(bytes),s='';for(var i=0;i<B;i++)s+=b[i].toString(16).padStart(2,'0');return s.toUpperCase();}
  function legacyHexToFrame(text){
    var s=String(text||'').trim();
    if(s.toUpperCase().indexOf('M'+'370:')===0)s=s.slice(5);
    s=s.replace(/\s+/g,'');
    var f=boolFrame();
    if(!/^[0-9a-fA-F]{93}$/.test(s))return f;
    for(var i=0;i<N;i++){var nib=parseInt(s[Math.floor(i/4)],16);f[i]=!!(nib&(1<<(3-(i&3))));}
    return f;
  }
  function legacyBytePairsToFrame(bytes){var b=bytesFromFrame(bytes),hex='';for(var i=0;i<B;i++)hex+=b[i].toString(16).padStart(2,'0');return legacyHexToFrame(hex.slice(0,93));}
  function parsePackedFrameText(text){
    var s=String(text||'').trim();
    if(!s)throw new Error('packed frame 不能为空');
    if(/^\s*\[/.test(s)){
      var arr=JSON.parse(s);
      if(!isByteArray(arr))throw new Error('packed frame JSON 数组必须是 47 个 0..255 byte');
      return frameFromBytes(arr);
    }
    var compact=s.replace(/\s+/g,'');
    var upper=compact.toUpperCase();
    if(upper.indexOf('PACKED:')===0)compact=compact.slice(7);
    else if(upper.indexOf('FRAME:')===0)compact=compact.slice(6);
    else if(upper.indexOf('HEX:')===0)compact=compact.slice(4);
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
  function validatePackedFrameText(text){try{var frame=parsePackedFrameText(text);return{valid:true,normalizedLen:hexFromBytes(bytesFromFrame(frame)).length,expectedLen:94,hadPrefix:/^\s*(PACKED|FRAME|HEX):/i.test(String(text||'')),error:''};}catch(err){var compact=String(text||'').replace(/\s+/g,'');return{valid:false,normalizedLen:compact.length,expectedLen:94,hadPrefix:/^\s*(PACKED|FRAME|HEX|M370):/i.test(String(text||'')),error:err.message||String(err)};}}
  function frameText(frame){return hexFromBytes(bytesFromFrame(frame));}
  function faceToFrame(face){if(!face)return boolFrame();if(isByteArray(face.frameBytes))return frameFromBytes(face.frameBytes);if(typeof face[OLD_KEY]==='string')return legacyHexToFrame(face[OLD_KEY]);return boolFrame();}
  function postFrame(frame,reason,playback){var payload=bytesFromFrame(frame).buffer;var path='/api/frame?reason='+encodeURIComponent(reason||'webui_frame')+'&playback='+encodeURIComponent(playback||'idle');return apiPost(path,payload,{silent:false,expectJson:true,timeoutMs:2500});}
  function addParam(params,key,value){if(value!==undefined&&value!==null&&value!=='')params.append(key,String(value));}
  function uploadPackedScroll(path,payload,onProgress){
    payload=payload||{};
    var frames=Array.isArray(payload.frames)?payload.frames:[];
    var bytes=new Uint8Array(frames.length*B);
    for(var i=0;i<frames.length;i++)bytes.set(bytesFromFrame(frames[i]),i*B);
    var params=new URLSearchParams();
    addParam(params,'append',payload.append?1:0);addParam(params,'start',payload.start?1:0);addParam(params,'intervalMs',payload.intervalMs);addParam(params,'fps',payload.fps);addParam(params,'chunkIndex',payload.chunkIndex);addParam(params,'totalFrames',payload.totalFrames);addParam(params,'source',payload.source);addParam(params,'timelineId',payload.timelineId);addParam(params,'sourceText',payload.sourceText);addParam(params,'fontId',payload.fontId);addParam(params,'generatorVersion',payload.generatorVersion);
    var base=(typeof apiUrl==='function'?apiUrl(path):path),url=base+'?'+params.toString();
    return new Promise(function(resolve,reject){var xhr=new XMLHttpRequest();xhr.open('POST',url,true);xhr.timeout=60000;xhr.setRequestHeader('Content-Type','application/octet-stream');xhr.setRequestHeader('Accept','application/json');xhr.upload.onprogress=function(ev){if(ev.lengthComputable&&ev.total>0&&onProgress)onProgress(ev.loaded/ev.total);};xhr.onload=function(){if(xhr.status<200||xhr.status>=300){reject(new Error(xhr.status+' '+(xhr.statusText||'')));return;}try{resolve(JSON.parse(xhr.responseText||'{"ok":true}'));}catch(e){resolve({ok:true});}};xhr.onerror=function(){reject(new Error('scroll upload failed'));};xhr.ontimeout=function(){reject(new Error('scroll upload timeout'));};xhr.send(bytes.buffer);});
  }
  if(typeof apiPostWithUploadProgress==='function'){
    window.apiPostWithUploadProgress=function(path,payload,onProgress){if(String(path||'').indexOf('/api/scroll')>=0)return uploadPackedScroll(path,payload,onProgress);return originalUpload(path,payload,onProgress);};
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
  window.parseM370ToFrameOrError=function(text){try{return{frame:parsePackedFrameText(text)};}catch(err){return{error:err.message||String(err)}}};try{parseM370ToFrameOrError=window.parseM370ToFrameOrError;}catch(e){}
  window.queueFirmwareFrame=function(frame,reason,playback){var packet={type:'packed_frame',reason:reason||'frame_update',playback:playback||'idle',at:Date.now()};packet.promise=postFrame(frame,packet.reason,packet.playback).then(function(data){try{if(data&&typeof applyFirmwareRuntimeState==='function')applyFirmwareRuntimeState(data,packet.reason);}catch(e){}return data;});return packet;};
  window.queueFirmwareLedDeltas=function(changes,reason,playback){var frame=[];try{frame=(liveSyncedFrame||currentFrame||[]).slice();}catch(e){}for(var i=0;i<N;i++)frame[i]=!!frame[i];for(var j=0;j<(changes||[]).length;j++){var idx=Number(changes[j]&&changes[j][0]);if(idx>=0&&idx<N)frame[idx]=!!changes[j][1];}return window.queueFirmwareFrame(frame,reason||'live_delta',playback||'idle');};
  function normalizeType(v){return typeof normalizeFaceType==='function'?normalizeFaceType(v):String(v||'custom').toLowerCase().includes('part')?'parts':String(v||'custom').toLowerCase().includes('default')?'default':'custom';}
  function nameFromId(id){return String(id||'face').replace(/^face_?/,'').replace(/_/g,' ').replace(/\b\w/g,function(c){return c.toUpperCase();});}
  function normFace(f,i,fallback,legacy){if(!f||typeof f!=='object')return null;var type=normalizeType(f.type||f.source||fallback||'custom'),id=String(f.id||type+'_'+(i+1));var frame=isByteArray(f.frameBytes)?(legacy?legacyBytePairsToFrame(f.frameBytes):frameFromBytes(f.frameBytes)):(typeof f[OLD_KEY]==='string'?legacyHexToFrame(f[OLD_KEY]):null);if(!frame)return null;return{id:id,name:String(f.name||nameFromId(id)).slice(0,64),type:type,frameBytes:Array.from(bytesFromFrame(frame)),order:Number.isFinite(Number(f.order))?Number(f.order):i+1,editable:f.editable!==false,deletable:type!=='default'&&f.deletable!==false,locked:type==='default'||!!f.locked,is_startup_default:!!f.is_startup_default||id==='face_08_triangle_eyes_frown',sourceFile:'saved_faces.json',savedAt:f.savedAt||f.createdAt||null,updatedAt:f.updatedAt||null,call:f.call||null};}
  function preferred(faces){return((faces||[]).find(function(f){return f.id==='face_08_triangle_eyes_frown';})||(faces||[]).find(function(f){return f.is_startup_default;})||(faces||[]).find(function(f){return f.type==='default';})||(faces||[])[0]||{}).id||null;}
  window.normalizeFace=function(f,i,fallback){return normFace(f,i,fallback,false);};try{normalizeFace=window.normalizeFace;}catch(e){}
  window.normalizeFaceDocument=function(doc,fallback){var src=(doc&&typeof doc==='object'&&!Array.isArray(doc))?doc:{faces:Array.isArray(doc)?doc:[]};var legacy=String(src.format||'')==='rina_packed_faces_370_v1'||String(src.matrix&&src.matrix.frameEncoding||'')==='legacy-byte-pair-frame';var faces=(Array.isArray(src.faces)?src.faces:[]).map(function(f,i){return normFace(f,i,fallback||'custom',legacy);}).filter(Boolean);return{format:'rina_packed_faces_370_v2',version:4,category:'unified_saved_faces',matrix:{leds:N,frameBytes:B,frameEncoding:'packed-lsb-first'},startupDefaultId:preferred(faces),updatedAt:src.updatedAt||null,faces:faces};};try{normalizeFaceDocument=window.normalizeFaceDocument;}catch(e){}
  window.buildUnifiedFaceDocument=function(){var lib=(typeof getAllFaces==='function'?getAllFaces():[]).map(function(f,i){return normFace(Object.assign({},f,{order:i+1}),i,f.type||'custom',false);}).filter(Boolean);return{format:'rina_packed_faces_370_v2',version:4,category:'unified_saved_faces',matrix:{leds:N,frameBytes:B,frameEncoding:'packed-lsb-first'},startupDefaultId:preferred(lib),updatedAt:new Date().toISOString(),faces:lib};};try{buildUnifiedFaceDocument=window.buildUnifiedFaceDocument;}catch(e){}
  window.getSavedFaceFrame=function(i){var f=(typeof getAllFaces==='function'?getAllFaces()[i]:null);return faceToFrame(f);};try{getSavedFaceFrame=window.getSavedFaceFrame;}catch(e){}
  window.applySavedFace=function(i,reason){var lib=typeof getAllFaces==='function'?getAllFaces():[],f=lib[i];if(!f)return;if(typeof state==='object')state.faceIndex=i;if(typeof setCurrentFrame==='function')setCurrentFrame(faceToFrame(f),reason||'saved_face_apply','idle');if(typeof renderSavedFaces==='function')renderSavedFaces();};try{applySavedFace=window.applySavedFace;}catch(e){}
  window.saveFace=function(name,frame,type){var t=normalizeType(type),clean=(String(name||'face').trim().slice(0,64)||'face'),all=typeof getAllFaces==='function'?getAllFaces():[],next=Math.max(0,...all.map(function(f){return Number(f.order)||0;}))+1,face={id:t+'_'+Date.now(),name:clean,type:t,frameBytes:Array.from(bytesFromFrame(frame)),order:next,editable:true,deletable:true,locked:false,is_startup_default:false,sourceFile:'saved_faces.json',savedAt:new Date().toISOString(),updatedAt:new Date().toISOString(),call:t==='parts'&&typeof selectedCall==='object'?Object.assign({},selectedCall):null};if(typeof userFaces!=='undefined')userFaces.push(face);if(typeof state==='object')state.faceIndex=typeof getAllFaces==='function'?getAllFaces().findIndex(function(f){return f.id===face.id;}):0;if(typeof renderSavedFaces==='function')renderSavedFaces();if(typeof renderState==='function')renderState();if(typeof persistFaceDocumentsAndRefresh==='function')persistFaceDocumentsAndRefresh('save_packed_face');};try{saveFace=window.saveFace;}catch(e){}
  window.buildFirmwareScrollFrames=async function(onProgress){var src=(typeof scroll==='object'&&Array.isArray(scroll.frames))?scroll.frames:[],out=[];for(var i=0;i<src.length;i++){out.push(Array.from(bytesFromFrame(src[i])));if(onProgress&&(i===0||i===src.length-1||i%32===0)){onProgress((i+1)/src.length);await new Promise(function(r){requestAnimationFrame(r);});}}return out;};try{buildFirmwareScrollFrames=window.buildFirmwareScrollFrames;}catch(e){}
  window.applyKnownFaceIndexLocal=function(reason){var lib=typeof getAllFaces==='function'?getAllFaces():[];if(!lib.length)return false;var idx=Math.max(0,Math.min(Number(state&&state.faceIndex)||0,lib.length-1));var f=lib[idx];if(!f)return false;try{currentFrame=faceToFrame(f);scrollFrame=currentFrame.slice();}catch(e){}if(typeof renderMatrices==='function')renderMatrices();if(typeof renderSavedFaces==='function')renderSavedFaces();return true;};try{applyKnownFaceIndexLocal=window.applyKnownFaceIndexLocal;}catch(e){}
  window.applyStartupDefaultFaceLocal=function(reason){var idx=typeof startupDefaultFaceIndex==='function'?startupDefaultFaceIndex():0;var f=(typeof getAllFaces==='function'?getAllFaces()[idx]:null);if(!f)return false;if(typeof state==='object')state.faceIndex=idx;try{currentFrame=faceToFrame(f);scrollFrame=currentFrame.slice();}catch(e){}if(typeof renderMatrices==='function')renderMatrices();if(typeof renderSavedFaces==='function')renderSavedFaces();return true;};try{applyStartupDefaultFaceLocal=window.applyStartupDefaultFaceLocal;}catch(e){}
  function relabelProtocolControls(){var labels={};labels['custom-copy']='复制 packed frame';labels['custom-import']='从 packed frame 导入到画板';labels['parts-copy-'+OLD_KEY]='复制 packed frame';labels['parts-import-'+OLD_KEY]='从 packed frame 导入到当前输出';labels['debug-'+OLD_KEY+'-preview']='解析为预览';labels['debug-'+OLD_KEY+'-send']='解析并发送固件';labels['debug-'+OLD_KEY+'-clear']='清空输入';labels['debug-'+OLD_KEY+'-copy']='复制调试预览 packed frame';labels['debug-preview-copy']='复制调试预览 packed frame';Object.keys(labels).forEach(function(id){var el=document.getElementById(id);if(el)el.textContent=labels[id];});['custom-'+OLD_KEY,'parts-'+OLD_KEY+'-text','debug-'+OLD_KEY].forEach(function(id){var el=document.getElementById(id);if(el)el.setAttribute('placeholder','输入 94 hex packed frame、47-byte JSON 数组或 base64');});var lab=document.querySelector('#debug-protocol-lab h3');if(lab)lab.textContent='LED 测试 / Packed Frame 协议实验室';document.querySelectorAll('#debug-protocol-lab h4').forEach(function(h){if(/M\s*370|Packed Frame 输入/i.test(h.textContent))h.textContent='Packed Frame 输入 / 调试';});}
  function scanControls(){relabelProtocolControls();var selector='button,a[href],input:not([type=hidden]),select,textarea,summary,[role="button"],[role="menuitem"],[data-gpio]',out=[];document.querySelectorAll(selector).forEach(function(el){out.push({testid:el.id||el.getAttribute('data-testid')||'',label:(el.textContent||el.value||el.getAttribute('aria-label')||'').trim(),tag:el.tagName.toLowerCase(),visible:!!(el.offsetParent||el.getClientRects().length),disabled:!!el.disabled});});return out;}
  window.__ui={version:'packed-frame-bridge-restore-all',list:function(){return scanControls();},find:function(q){q=String(q||'').toLowerCase();return scanControls().filter(function(e){return(e.testid+' '+e.label).toLowerCase().indexOf(q)>=0;});},click:function(ref){var el=document.getElementById(ref)||document.querySelector('[data-testid="'+String(ref).replace(/"/g,'')+'"]');if(!el)return{ok:false,error:'not found: '+ref};el.scrollIntoView&&el.scrollIntoView({block:'center',inline:'center'});el.click();return{ok:true,testid:el.id||el.getAttribute('data-testid')||'',label:(el.textContent||'').trim()};},setValue:function(ref,value){var el=document.getElementById(ref)||document.querySelector('[data-testid="'+String(ref).replace(/"/g,'')+'"]');if(!el)return{ok:false,error:'not found: '+ref};el.value=value;el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));return{ok:true,value:el.value};},rescan:function(){return{count:scanControls().length};}};
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',function(){setTimeout(relabelProtocolControls,0);});else setTimeout(relabelProtocolControls,0);
})();
