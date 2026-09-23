const {test,after}=require('node:test');
const assert=require('node:assert/strict');
const original=global.fetch;after(()=>global.fetch=original);
function setup({primaryFails=false,blocksFail=false,allFail=false,missingMeta=false,stale=false}={}){
 delete require.cache[require.resolve('../api/solana-stats')];let calls=[];
 global.fetch=async(url,options)=>{
  const p=JSON.parse(options.body);calls.push({url,...p});
  if(allFail || (primaryFails && url.includes('publicnode')) || (blocksFail && p.method==='getBlock'))throw Error('Network');
  let result=p.method==='getRecentPerformanceSamples'?[{numTransactions:120000,samplePeriodSecs:60,slot:1000}]:1005;
  if(p.method==='getBlock')result={blockTime:Date.now()/1000-(stale?600:3),transactions:[{meta:{err:null}},{meta:{err:{InstructionError:[0,'test']}}},{meta:missingMeta?null:{err:null}}]};
  return {ok:true,json:async()=>({id:p.id,result})};
 };
 const handler=require('../api/solana-stats');
 async function invoke(method='GET') {const r={headers:{},setHeader(k,v){this.headers[k]=v;},status(v){this.code=v;return this;},json(v){this.body=v;return this;}};await handler({method},r);return r;}
 return {invoke,calls};
}
test('calculates real TPS and block execution success; caches concurrent reads',async()=>{
 const s=setup();const [r,r2]=await Promise.all([s.invoke(),s.invoke()]);
 assert.equal(r.body.tps,2000);assert.ok(Math.abs(r.body.success_rate-66.6666666667)<1e-8);assert.equal(r.body.transaction_count,3);assert.equal(r2.body.status,'live');assert.equal(s.calls.length,3);
 await s.invoke();assert.equal(s.calls.length,3);assert.match(r.headers['Cache-Control'],/s-maxage=60/);
});
test('provider failover and partial metrics never invent a success percentage',async()=>{
 let s=setup({primaryFails:true});assert.equal((await s.invoke()).body.status,'live');assert.ok(s.calls.some(c=>c.url.includes('solana.com')));
 s=setup({blocksFail:true});let r=await s.invoke();assert.equal(r.body.tps,2000);assert.equal(r.body.success_rate,null);assert.equal(r.body.status,'partial');
 s=setup({missingMeta:true});assert.equal((await s.invoke()).body.success_rate,null);
});
test('unavailable and stale sources do not report live data',async()=>{
 for(const opts of [{allFail:true},{stale:true}]){const s=setup(opts);const r=await s.invoke();assert.equal(r.code,503);assert.equal(r.body.tps,undefined);assert.equal(r.headers['Cache-Control'],'no-store');}
});
test('only GET may invoke the public telemetry endpoint',async()=>{const s=setup();assert.equal((await s.invoke('POST')).code,405);assert.equal(s.calls.length,0);});
