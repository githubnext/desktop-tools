#!/usr/bin/env node
import { spawn } from "node:child_process";
function server(cmd){const [f,...a]=cmd.split(" ");const c=spawn(f,a,{stdio:["pipe","pipe","inherit"]});let buf="",n=1;const w=new Map();
c.stdout.on("data",d=>{buf+=d;let i;while((i=buf.indexOf("\n"))>=0){const l=buf.slice(0,i);buf=buf.slice(i+1);const m=JSON.parse(l);w.get(m.id)?.(m.result??m.error);}});
const req=(method,params={})=>new Promise(r=>{const id=n++;w.set(id,r);c.stdin.write(JSON.stringify({jsonrpc:"2.0",id,method,params})+"\n")});
return {req,call:(name,args)=>req("tools/call",{name,arguments:args}),stop:()=>c.kill()}}
const j=r=>{const t=r.content.find(c=>c.text?.startsWith("{"));return t?JSON.parse(t.text):{}};
// Times the core tools on the fixture window through the Swift spike and the Node server: node native2/scripts/bench.mjs [runs]
const runs=Number(process.argv[2]??10);
const S={swift:"native2/.build/release/desktop-tools-mcp",node:"node dist/mcp.js"};
const p=(xs,q)=>{const s=[...xs].sort((a,b)=>a-b);return Math.round(s[Math.min(s.length-1,Math.floor(q*s.length))])};
const res={};
for(const [name,cmd] of Object.entries(S)){
 const s=server(cmd);await s.req("initialize",{protocolVersion:"2025-06-18",capabilities:{},clientInfo:{name:"b"}});
 const app=j(await s.call("desktop_apps",{query:"fixture"})).apps.find(a=>a.name==="fixture");
 const win=j(await s.call("desktop_windows",{pid:app.pid})).windows.find(w=>w.window_title==="Click Fixture");
 const ins=async()=>{const t0=performance.now();const d=j(await s.call("desktop_inspect",{pid:app.pid,window:win.window_id}));const ms=performance.now()-t0;
  const id=f=>d.ui_elements.find(f)?.id;return {ms,snap:d.snapshot_id,field:id(e=>e.attributes.role==="AXTextField"),button:id(e=>e.label==="Press me"),scroll:id(e=>e.attributes.role==="AXScrollArea")}};
 const scen={
  apps:async()=>[ "desktop_apps",{}],
  windows:async()=>["desktop_windows",{pid:app.pid}],
  inspect:async()=>["desktop_inspect",{pid:app.pid,window:win.window_id}],
  wait:async()=>["desktop_wait",{until:"element_appears",pid:app.pid,window:win.window_id,element:{role:"AXButton",title:"Press me"},timeout_ms:2000}],
  click:async(i,o)=>["desktop_click",{snapshot:o.snap,element:o.button}],
  double:async(i,o)=>["desktop_click",{snapshot:o.snap,point:{x:0.2,y:0.5},kind:"double"}],
  type:async(i,o)=>["desktop_type",{snapshot:o.snap,element:o.field,text:"t"+i}],
  key:async(i,o)=>["desktop_key",{snapshot:o.snap,key:"right"}],
  scroll:async(i,o)=>["desktop_scroll",{snapshot:o.snap,element:o.scroll,direction:i%2?"up":"down",amount:1}],
  drag:async(i,o)=>["desktop_drag",{snapshot:o.snap,from:{x:0.1,y:0.4},to:{x:0.5,y:0.6},duration_ms:100}],
  hover:async(i,o)=>["desktop_hover",{snapshot:o.snap,point:{x:0.1+0.05*(i%4),y:0.5}}],
 };
 for(const [k,f] of Object.entries(scen)){
  const t=[];let bad=0;
  if(k==="key"){const o=await ins();await s.call("desktop_click",{snapshot:o.snap,element:o.field});}
  for(let i=0;i<runs;i++){const o=["apps","windows","inspect","wait"].includes(k)?{}:await ins();const [tool,args]=await f(i,o);
   const t0=performance.now();const r=await s.call(tool,args);t.push(performance.now()-t0);
   const first=r.content?.[0]?.text??"";if(first.startsWith("Outcome:")&&!first.startsWith("Outcome: completed"))bad++;}
  (res[k]??={})[name]={p50:p(t,0.5),p90:p(t,0.9),bad};
 }
 s.stop();
}
console.log("scenario   node p50/p90   swift p50/p90   speedup  (non-completed)");
for(const [k,v] of Object.entries(res)) console.log(k.padEnd(10),`${v.node.p50}/${v.node.p90}`.padStart(12),`${v.swift.p50}/${v.swift.p90}`.padStart(14),(v.node.p50/v.swift.p50).toFixed(1).padStart(8)+"x",`  node ${v.node.bad} swift ${v.swift.bad}`);
