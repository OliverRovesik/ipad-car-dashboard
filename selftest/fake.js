/* 假 GATT 设备：验证 probe.html 的服务申请、方向判定、通知分帧。仅测试用。 */
(function(){
  const KEY = location.hash.slice(1) || 'ffe0';
  const B = '-0000-1000-8000-00805f9b34fb';
  const N = '-b5a3-f393-e0a9-e50e24dcca9e';

  const SPECS = {
    // B 型：单特征既能写又能 notify
    ffe0: [{ u:'0000ffe0'+B, c:[{ u:'0000ffe1'+B, w:1, x:1, n:1 }] },
           { u:'0000180a'+B, c:[{ u:'00002a24'+B, r:1, v:'FAKE-ELM-BLE' }] }],
    // E 型：Nordic UART，读写分离
    nus:  [{ u:'6e400001'+N, c:[{ u:'6e400002'+N, w:1, x:1 }, { u:'6e400003'+N, n:1 }] }],
    // A 型：18F0 服务
    p18f0:[{ u:'000018f0'+B, c:[{ u:'00002af1'+B, w:1 }, { u:'00002af0'+B, n:1 }] }],
    // 未编目服务：应走 fallback 分支
    odd:  [{ u:'0000abcd'+B, c:[{ u:'0000ab01'+B, w:1 }, { u:'0000ab02'+B, n:1 }] }],
    // 服务不在 optionalServices 里 → 应当枚举为空
    hidden:[{ u:'0000beef'+B, c:[{ u:'0000bee1'+B, w:1, n:1 }] }],
  };

  const REPLIES = {
    'ATZ':'ELM327 v2.2\r\r>', AT:'ELM327\r\r>', ATE0:'OK\r\r>',
    ATL1:'OK\r\r>', ATL0:'OK\r\r>', ATRV:'12.4\r\r>', ATRP:'0\r\r>',
    '010D':'41 0D 3E\r\r>', '010C':'41 0C 0A FA\r\r>', '0105':'41 05 59\r\r>',
    '0111':'41 11 1F\r\r>', '0104':'41 04 23\r\r>', '010F':'41 0F 37\r\r>',
    '0100':'6E 00\r\r>',
  };
  const NO_DELIM = { '010D':'410D3E', ATRV:'12.4' };   // ATL0 后无定界符，靠静默分帧

  let rxChar = null, useDelim = true;

  function emit(str){
    const bytes = Array.from(str, ch => ch.charCodeAt(0));
    const half = Math.ceil(bytes.length / 2);
    [bytes.slice(0,half), bytes.slice(half)].forEach(part=>{
      if(!part.length) return;
      const dv = new DataView(new ArrayBuffer(part.length));
      part.forEach((b,i)=>dv.setUint8(i,b));
      rxChar._ls.forEach(cb=>cb({ target:{ value:dv } }));
    });
  }

  function mkChar(c){
    const o = {
      uuid:c.u, _ls:[],
      properties:{ read:!!c.r, write:!!c.w, writeWithoutResponse:!!c.x, notify:!!c.n, indicate:false },
      addEventListener:(e,cb)=>{ if(o._ls.indexOf(cb)<0) o._ls.push(cb); },
      removeEventListener:(e,cb)=>{ const i=o._ls.indexOf(cb); if(i>-1) o._ls.splice(i,1); },
      startNotifications:async()=>{}, stopNotifications:async()=>{},
      readValue:async()=>{
        const s = c.v || '';
        const dv = new DataView(new ArrayBuffer(s.length || 1));
        Array.from(s, (ch,i)=>dv.setUint8(i, ch.charCodeAt(0)));
        return dv;
      },
      writeValue:async dv=>wr(dv),
      writeValueWithoutResponse:dv=>wr(dv),
    };
    function wr(dv){
      const cmd = String.fromCharCode(...new Uint8Array(dv.buffer, dv.byteOffset, dv.byteLength)).replace(/\r/g,'').trim();
      const table = useDelim ? REPLIES : Object.assign({}, REPLIES, NO_DELIM);
      setTimeout(()=>emit(table[cmd] !== undefined ? table[cmd] : '?'), 8);
    }
    return o;
  }

  const services = (SPECS[KEY] || SPECS.ffe0).map(s=>({
    uuid:s.u, chars:s.c.map(c=>{ const o=mkChar(c); if(c.n) rxChar=o; return o; }),
  }));

  let allowed = [];
  const svcObj = s => ({ uuid:s.uuid, getCharacteristics:async()=>s.chars });
  const server = {
    getPrimaryServices: async()=> services.filter(s=>allowed.includes(s.uuid)).map(svcObj),
    getPrimaryService: async(u)=>{
      const s = services.find(x=>x.uuid===u);
      if(!s || !allowed.includes(u)) throw new Error('NotFoundError: '+u);
      return svcObj(s);
    },
    disconnect:()=>{}, addEventListener:()=>{},
  };

  const device = {
    name:'FAKE-'+KEY, gatt:{ connect:async()=>server }, addEventListener:()=>{},
  };

  Object.defineProperty(navigator, 'bluetooth', {
    configurable:true,
    value:{ requestDevice:async(opts)=>{
      allowed = (opts.optionalServices||[]).map(x=>x.toLowerCase());
      window.__probe = { opts, server, device, services,
                         toggleDelim:v=>{ useDelim=v; } };
      return device;
    }},
  });
})();
