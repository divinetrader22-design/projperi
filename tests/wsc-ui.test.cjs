const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const html=fs.readFileSync(require('node:path').join(__dirname,'../dashboard.html'),'utf8');
const code=html.slice(html.indexOf('  let quoteBusy'),html.indexOf('  async function loadWithdrawals'));
const sample={required_sol:'0.100000001',body:'legacy body',updated_at:'now'};
function setup({quote=sample, saved={}, result={status:'passed',current_sol:'0.100000001',required_sol:'0.100000001',checked_at:new Date().toISOString()}}={}) {
 const elements=Object.fromEntries([...html.matchAll(/id="([^"]+)"/g)].map(m=>[m[1],{style:{},value:'',textContent:'',disabled:false}]));
 const stats={checks:0,quotes:0,saved:null};let now=1000;const intervals=new Map();let id=0;
 const ctx=vm.createContext({document:{addEventListener(){},hidden:false,getElementById:id=>{assert.ok(elements[id],id);return elements[id];}},
 currentRole:'client',project:{id:'project',client_id:'client'},sessionUser:{id:'client'},fwpKeyIsSet:true,fwpBusy:false,
 Date:class extends Date{static now(){return now;}},setInterval:fn=>{intervals.set(++id,fn);return id;},clearInterval:id=>intervals.delete(id),
 localStorage:{getItem:k=>saved[k],setItem:(k,v)=>saved[k]=v},AbortSignal,
 supabaseClient:{rpc:(name,args)=>name==='admin_client_quote'?(stats.saved=args,Promise.resolve({data:{current:{required_sol:args.p_required_sol},scheduled:args.p_action==='schedule'?{required_sol:args.p_required_sol,effective_at:args.p_effective_at}:null}})):({abortSignal:async()=>{stats.quotes++;return {data:quote};}}),auth:{getSession:async()=>({data:{session:{access_token:'test'}}})},
 from:()=>({upsert:data=>{stats.saved=data;return {select:()=>({single:async()=>({data:{project_id:'project'}})})};}})},
 fetch:async()=>{stats.checks++;return {ok:result.status==='passed',json:async()=>result};}});
 vm.runInContext(code,ctx);return {ctx,elements,stats,saved,tick(ms){now+=ms;for(const fn of [...intervals.values()])fn();}};
}
test('start fetches quote automatically; blocks repeat checks for 60 seconds and restores across reload',async()=>{
 const s=setup();s.ctx.updateQuoteControls();assert.equal(s.elements.wscValidateBtn.disabled,false);
 await s.ctx.validateWsc();assert.equal(s.stats.quotes,1);assert.equal(s.stats.checks,1);
 assert.match(s.elements.wscStatus.textContent,/validation passed/);assert.equal(s.elements.wscBalance.textContent,'Current balance: 0.100000001 SOL / Required balance: 0.100000001 SOL');assert.equal(s.elements.quoteResult.textContent,'0.100000001 SOL');
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
 assert.match(unavailable.elements.wscStatus.textContent,/Unable to verify/);assert.match(unavailable.elements.wscBalance.textContent,/Current balance: unavailable/);
});
test('single quote input saves one exact amount for display and validation',async()=>{
 assert.ok(!html.includes('id="quoteInput"'));
 const s=setup();s.ctx.currentRole='admin';vm.runInContext('quoteAdminLoaded=true',s.ctx);
 s.elements.quoteSolInput.value='0.100000001';await s.ctx.saveClientQuote({preventDefault(){}});
 assert.equal(s.stats.saved.p_required_sol,'0.100000001');assert.equal(s.stats.saved.p_action,'save');
});
test('all inline dashboard scripts parse',()=>{
 for(const script of html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)) new vm.Script(script[1]);
});


test('admin scheduling validates a future time and sends an explicit UTC instant',async()=>{
 const s=setup();s.ctx.currentRole='admin';vm.runInContext('quoteAdminLoaded=true',s.ctx);
 s.elements.quoteSolInput.value='0.2';s.elements.quoteTiming.value='later';s.elements.quoteScheduledAt.value='2030-12-01T14:30';
 await s.ctx.saveClientQuote({preventDefault(){}});
 assert.equal(s.stats.saved.p_action,'schedule');assert.equal(s.stats.saved.p_effective_at,new Date('2030-12-01T14:30').toISOString());
 assert.match(s.elements.quoteScheduleStatus.textContent,/Scheduled: 0.2 SOL/);
 const invalid=setup();invalid.ctx.currentRole='admin';vm.runInContext('quoteAdminLoaded=true',invalid.ctx);
 invalid.elements.quoteSolInput.value='0.2';invalid.elements.quoteTiming.value='later';invalid.elements.quoteScheduledAt.value='';
 await invalid.ctx.saveClientQuote({preventDefault(){}});assert.equal(invalid.stats.saved,null);assert.match(invalid.elements.quoteStatus.textContent,/future date and time/);
});
test('client displays update time without schedule metadata and clears outdated WSC result on a changed quote',async()=>{
 const s=setup();s.ctx.displayClientQuote({required_sol:'1',updated_at:'2026-09-23T14:30:00Z'});
 assert.match(s.elements.quoteStatus.textContent,/Quote updated \d{2}:\d{2} (AM|PM)/);
 s.elements.wscStatus.textContent='Previous result';s.ctx.displayClientQuote({required_sol:'2',updated_at:'2026-09-23T14:31:00Z'});
 assert.equal(s.elements.wscStatus.textContent,'');assert.equal(s.elements.quoteResult.textContent,'2 SOL');
});
