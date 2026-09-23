const {test}=require('node:test');const assert=require('node:assert/strict');const vm=require('node:vm');const fs=require('node:fs');
test('renders live values, throttles refresh, pauses hidden tabs, and marks failed updates',async()=>{
 const nodes={};for(const id of ['solanaStats','solanaState','solanaTps','solanaRate','solanaWindow','solanaSample','solanaUpdated'])nodes[id]={textContent:'',dataset:{},setAttribute(){}};
 let now=Date.now(),tick,visibility,calls=0,fail=false;
 const document={hidden:false,getElementById:id=>nodes[id],addEventListener:(event,fn)=>{visibility=fn;}};
 const context=vm.createContext({document,Intl,AbortSignal,Date:class extends Date{static now(){return now;}},setInterval:fn=>{tick=fn;},fetch:async()=>{calls++;if(fail)throw Error('Offline');return {ok:true,json:async()=>({status:'live',tps:2500,period_seconds:60,success_rate:80,transaction_count:100,block_slot:200,checked_at:new Date(now).toISOString()})};}});
 vm.runInContext(fs.readFileSync(__dirname+'/../solana-stats.js','utf8'),context);
 await new Promise(resolve=>setImmediate(resolve));assert.equal(nodes.solanaRate.textContent,'80.0%');assert.equal(nodes.solanaStats.dataset.state,'live');
 await tick();assert.equal(calls,1);now+=61000;document.hidden=true;await tick();assert.equal(calls,1);
 document.hidden=false;fail=true;await visibility();assert.equal(calls,2);assert.equal(nodes.solanaStats.dataset.state,'unavailable');assert.match(nodes.solanaUpdated.textContent,/Last reading/);assert.equal(nodes.solanaRate.textContent,'80.0%');
});
