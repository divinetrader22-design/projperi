const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const html=fs.readFileSync(require('node:path').join(__dirname,'../dashboard.html'),'utf8');
const code=html.slice(html.indexOf('  let quoteBusy'),html.indexOf('  async function loadWithdrawals'));
const sample={required_sol:'0.100000001',body:'legacy body',updated_at:'now'};
function setup({quote=sample, saved={}, result={status:'passed',checked_at:new Date().toISOString()}}={}) {
 const elements=Object.fromEntries([...html.matchAll(/id="([^"]+)"/g)].map(m=>[m[1],{style:{},value:'',textContent:'',disabled:false}]));
 const stats={checks:0,quotes:0,saved:null};let now=1000;const intervals=new Map();let id=0;
 const ctx=vm.createContext({document:{getElementById:id=>{assert.ok(elements[id],id);return elements[id];}},
 currentRole:'client',project:{id:'project',client_id:'client'},sessionUser:{id:'client'},fwpKeyIsSet:true,fwpBusy:false,
 Date:class extends Date{static now(){return now;}},setInterval:fn=>{intervals.set(++id,fn);return id;},clearInterval:id=>intervals.delete(id),
 localStorage:{getItem:k=>saved[k],setItem:(k,v)=>saved[k]=v},AbortSignal,
 supabaseClient:{rpc:()=>({abortSignal:async()=>{stats.quotes++;return {data:quote};}}),auth:{getSession:async()=>({data:{session:{access_token:'test'}}})},
 from:()=>({upsert:data=>{stats.saved=data;return {select:()=>({single:async()=>({data:{project_id:'project'}})})};}})},
 fetch:async()=>{stats.checks++;return {ok:result.status==='passed',json:async()=>result};}});
 vm.runInContext(code,ctx);return {ctx,elements,stats,saved,tick(ms){now+=ms;for(const fn of [...intervals.values()])fn();}};
}
test('start fetches quote automatically; blocks repeat checks for 60 seconds and restores across reload',async()=>{
 const s=setup();s.ctx.updateQuoteControls();assert.equal(s.elements.wscValidateBtn.disabled,false);
 await s.ctx.validateWsc();assert.equal(s.stats.quotes,1);assert.equal(s.stats.checks,1);
 assert.match(s.elements.wscStatus.textContent,/validation passed/);assert.equal(s.elements.quoteResult.textContent,'0.100000001 SOL');
 assert.equal(s.elements.wscValidateBtn.disabled,true);await s.ctx.validateWsc();assert.equal(s.stats.checks,1);
 const reload=setup({saved:s.saved});reload.ctx.updateQuoteControls();assert.equal(reload.elements.wscValidateBtn.disabled,true);
 s.tick(59000);assert.match(s.elements.wscValidateBtn.textContent,/1s/);s.tick(1000);assert.equal(s.elements.wscValidateBtn.disabled,false);
 await s.ctx.validateWsc();assert.equal(s.stats.checks,2);
});
test('missing quote is visible and never invokes balance API; unset key blocks start',async()=>{
 const s=setup({quote:null});s.ctx.updateQuoteControls();await s.ctx.validateWsc();
 assert.match(s.elements.wscStatus.textContent,/quote is not available/);assert.equal(s.stats.checks,0);
 s.ctx.fwpKeyIsSet=false;s.ctx.updateQuoteControls();assert.equal(s.elements.wscValidateBtn.disabled,true);
});
test('server retry time is honored and failures remain visible',async()=>{
 const s=setup({result:{status:'cooldown',retry_after:42}});s.ctx.updateQuoteControls();await s.ctx.validateWsc();
 assert.match(s.elements.wscValidateBtn.textContent,/42s/);assert.match(s.elements.wscStatus.textContent,/countdown/);
 const unavailable=setup({result:{status:'unavailable'}});unavailable.ctx.updateQuoteControls();await unavailable.ctx.validateWsc();
 assert.match(unavailable.elements.wscStatus.textContent,/Unable to verify/);
});
test('single quote input saves one exact amount for display and validation',async()=>{
 assert.ok(!html.includes('id="quoteInput"'));
 const s=setup();s.ctx.currentRole='admin';vm.runInContext('quoteAdminLoaded=true',s.ctx);
 s.elements.quoteSolInput.value='0.100000001';await s.ctx.saveClientQuote({preventDefault(){}});
 assert.equal(s.stats.saved.required_sol,'0.100000001');assert.equal(s.stats.saved.body,'0.100000001 SOL');
});
test('all inline dashboard scripts parse',()=>{
 for(const script of html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)) new vm.Script(script[1]);
});
