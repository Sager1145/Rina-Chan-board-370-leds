(function(){
  if(window.__pf)return; window.__pf=1;
  var N=370,B=47;
  function bytes(frame){var out=new Uint8Array(B); frame=Array.prototype.slice.call(frame||[]); for(var i=0;i<N;i++){if(frame[i])out[i>>3]|=1<<(i&7);} out[B-1]&=3; return out;}
  function post(frame,reason,playback){var data=bytes(frame); var path='/api/frame?reason='+encodeURIComponent(reason||'webui_frame')+'&playback='+encodeURIComponent(playback||'idle'); if(typeof apiPost==='function')return apiPost(path,data.buffer,{silent:false,expectJson:true,timeoutMs:2500}); return fetch(path,{method:'POST',headers:{'Content-Type':'application/octet-stream','Accept':'application/json'},body:data.buffer}).then(function(r){return r.json();});}
  window.frameToPackedBytes=bytes;
  window.queueFirmwareFrame=function(frame,reason,playback){var packet={type:'packed_frame',reason:reason||'frame_update',playback:playback||'idle',at:Date.now()}; packet.promise=post(frame,packet.reason,packet.playback).then(function(d){try{if(d&&typeof applyFirmwareRuntimeState==='function')applyFirmwareRuntimeState(d,packet.reason);}catch(e){} return d;}); return packet;};
  window.queueFirmwareLedDeltas=function(changes,reason,playback){var base=[]; try{base=(liveSyncedFrame||currentFrame||[]).slice();}catch(e){} for(var i=0;i<N;i++)base[i]=!!base[i]; for(var j=0;j<(changes||[]).length;j++){var idx=Number(changes[j]&&changes[j][0]); if(idx>=0&&idx<N)base[idx]=!!changes[j][1];} return window.queueFirmwareFrame(base,reason||'live_delta',playback||'idle');};
})();
