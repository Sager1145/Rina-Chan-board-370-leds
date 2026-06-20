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
  window.__ui={version:'packed-frame-shim',list:function(){return[];},find:function(){return[];},rescan:function(){return{count:0};}};
})();
