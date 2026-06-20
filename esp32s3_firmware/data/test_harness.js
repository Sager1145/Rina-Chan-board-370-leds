/* Packed-frame shim loaded after app.js. */
(function(){
  if(window.__packedFrameShim)return;
  window.__packedFrameShim=true;
  var N=370,B=47;
  function toBytes(frame){
    var out=new Uint8Array(B);
    var src=Array.prototype.slice.call(frame||[]);
    for(var i=0;i<N;i++) if(src[i]) out[i>>3]|=1<<(i&7);
    out[B-1]&=3;
    return out;
  }
  function send(frame,reason,playback){
    var payload=toBytes(frame).buffer;
    var path='/api/frame?reason='+encodeURIComponent(reason||'webui_frame')+'&playback='+encodeURIComponent(playback||'idle');
    return apiPost(path,payload,{silent:false,expectJson:true,timeoutMs:2500});
  }
  function setText(id,text){var el=document.getElementById(id); if(el) el.textContent=text;}
  function cleanLabels(){
    setText('custom-copy','复制 packed frame');
    setText('custom-import','从 packed 文本导入到画板');
    setText('parts-copy-m370','复制 packed frame');
    setText('parts-import-m370','从 packed 文本导入到当前输出');
    setText('debug-m370-preview','解析为预览');
    setText('debug-m370-send','解析并发送固件');
    setText('debug-m370-clear','清空输入');
    setText('debug-m370-copy','复制调试预览 packed frame');
    setText('debug-preview-copy','复制调试预览 packed frame');
    var lab=document.querySelector('#debug-protocol-lab h3'); if(lab) lab.textContent='LED 测试 / Packed Frame 协议实验室';
    var headers=document.querySelectorAll('#debug-protocol-lab h4');
    for(var i=0;i<headers.length;i++) if(headers[i].textContent.indexOf('M370')>=0) headers[i].textContent='Packed Frame 输入';
    var input=document.getElementById('debug-m370'); if(input) input.setAttribute('placeholder','输入 94 hex packed bytes');
    var hint=document.querySelector('#debug-resource-panel .hint'); if(hint) hint.textContent='表情部件资源由 WebUI 合成为 packed frame；默认与用户表情均来自同一个 /resources/saved_faces.json，经 /api/saved_faces 写回固件。';
  }
  window.frameToPackedBytes=toBytes;
  window.queueFirmwareFrame=function(frame,reason,playback){
    var packet={type:'packed_frame',reason:reason||'frame_update',playback:playback||'idle',at:Date.now()};
    packet.promise=send(frame,packet.reason,packet.playback).then(function(data){
      try{ if(data&&typeof applyFirmwareRuntimeState==='function') applyFirmwareRuntimeState(data,packet.reason); }catch(e){}
      return data;
    });
    return packet;
  };
  window.queueFirmwareLedDeltas=function(changes,reason,playback){
    var frame=[];
    try{ frame=(liveSyncedFrame||currentFrame||[]).slice(); }catch(e){}
    for(var i=0;i<N;i++) frame[i]=!!frame[i];
    for(var j=0;j<(changes||[]).length;j++){
      var idx=Number(changes[j]&&changes[j][0]);
      if(idx>=0&&idx<N) frame[idx]=!!changes[j][1];
    }
    return window.queueFirmwareFrame(frame,reason||'live_delta',playback||'idle');
  };
  window.__ui={version:'packed-frame-shim',list:function(){return[];},find:function(){return[];},rescan:function(){cleanLabels();return{count:0};}};
  cleanLabels();
  try{new MutationObserver(cleanLabels).observe(document.body,{childList:true,subtree:true});}catch(e){}
})();
