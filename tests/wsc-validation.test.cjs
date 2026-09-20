const { test, after } = require('node:test');
const assert = require('node:assert/strict');
const handler = require('../api/wsc-validate.js');
const originalFetch = global.fetch;
after(() => { global.fetch = originalFetch; });
const quote = { body: 'Test quote', required_sol: '0.100000001', updated_at: '2026-09-20T00:00:00+00:00' };
const request = { method: 'POST', headers: { authorization: 'Bearer dummy-test-token' }, body: {
  project_id: '11111111-1111-4111-8111-111111111111', quote_updated_at: quote.updated_at
} };
async function invoke({ balance = 100000001, first = quote, latest = quote, rpcError = false, denied = false, cooldown = { allowed:true, retry_after:60 }, failFirst = false, req = request } = {}) {
  let calls = [];
  let reads = 0, rpcCalls = 0;
  global.fetch = async (url, options) => {
    const payload = JSON.parse(options.body);
    calls.push({ url, payload });
    if (String(url).endsWith('/claim_wsc_check')) {
      return {ok:true, status:200, json:async()=>cooldown};
    }
    if (String(url).includes('/rest/v1/')) {
      if (denied) return { ok: false, status: 403 };
      return { ok: true, status: 200, json: async () => ++reads === 1 ? first : latest };
    }
    if (++rpcCalls === 1 && failFirst) return {ok:false,status:429};
    if (rpcError) throw new Error('RPC timed out');
    assert.equal(payload.method, 'getBalance');
    assert.equal(payload.params[1].commitment, 'confirmed');
    return { ok: true, json: async () => ({ id: 'wsc-balance', result: { value: balance, context: { slot: 1000 } } }) };
  };
  const response = { headers: {}, setHeader(k,v) { this.headers[k]=v; }, status(v) { this.code=v; return this; }, json(v) { this.body=v; return this; } };
  await handler(req, response);
  assert.equal(response.headers['Cache-Control'], 'no-store, private');
  assert.ok(!JSON.stringify(response.body).includes('HBeSz4v5'));
  return { ...response, calls };
}
test('exact equality and one lamport boundaries', async () => {
  const equal = await invoke();
  assert.equal(equal.body.status, 'passed');
  assert.equal(equal.body.current_sol, '0.100000001');
  assert.equal(equal.body.required_sol, quote.required_sol);
  assert.equal((await invoke({balance:0})).body.current_sol, '0');
  assert.equal((await invoke({balance:1000000000})).body.current_sol, '1');
  assert.equal((await invoke({balance:1})).body.current_sol, '0.000000001');
  assert.equal((await invoke({ balance:100000002 })).body.status, 'passed');
  assert.equal((await invoke({ balance:100000000 })).body.status, 'insufficient');
  assert.equal((await invoke({ balance:0 })).body.status, 'insufficient');
});
test('missing quote, stale quote, and denied caller do not query Solana', async () => {
  for (const opts of [{ first:null }, { first:{...quote,required_sol:null} }, { first:{...quote,updated_at:'changed'} }, { denied:true }]) {
    const r=await invoke(opts); assert.notEqual(r.code,200); assert.equal(r.calls.length,1);
  }
});
test('quote changes and key removal during balance lookup cannot pass', async () => {
  assert.equal((await invoke({latest:{...quote,required_sol:'1'}})).body.status,'quote_changed');
  assert.equal((await invoke({latest:null})).body.status,'quote_changed');
});
test('network errors and invalid RPC balances fail closed', async () => {
  for(const options of [{rpcError:true},{balance:-1},{balance:1.5},{balance:Number.MAX_SAFE_INTEGER+1}]) {
    const r=await invoke(options); assert.equal(r.code,503); assert.equal(r.body.status,'unavailable');
  }
});
test('browser-supplied balance and amount cannot alter comparison', async () => {
  const r=await invoke({balance:0,req:{...request,body:{...request.body,required_sol:'0',balance:999999999999}}});
  assert.equal(r.body.status,'insufficient');
});
test('requires POST, a bearer token, and a valid project identifier', async () => {
  for(const req of [{...request,method:'GET'},{...request,headers:{}},{...request,body:{...request.body,project_id:'bad'}}]) {
    const r=await invoke({req});assert.ok(r.code>=400);assert.equal(r.calls.length,0);
  }
});

test('server cooldown blocks upstream calls and provides retry time', async () => {
 const r=await invoke({cooldown:{allowed:false,retry_after:42}});
 assert.equal(r.code,429); assert.equal(r.body.retry_after,42);
 assert.equal(r.headers['Retry-After'],'42'); assert.equal(r.calls.length,2);
});
test('invalid reservation fails without requesting a balance', async () => {
 const r=await invoke({cooldown:{allowed:true,retry_after:0}});
 assert.equal(r.code,503); assert.equal(r.calls.length,2);
});
test('rate-limited primary falls back; valid insufficient result does not retry', async () => {
 const r=await invoke({failFirst:true}); assert.equal(r.body.status,'passed');
 assert.equal(r.calls.filter(c=>c.payload.method==='getBalance').length,2);
 const low=await invoke({balance:0}); assert.equal(low.body.status,'insufficient');
 assert.equal(low.calls.filter(c=>c.payload.method==='getBalance').length,1);
 const fail=await invoke({rpcError:true}); assert.equal(fail.code,503);
 const urls=fail.calls.filter(c=>c.payload.method==='getBalance').map(c=>c.url);
 assert.equal(urls.length,2); assert.equal(new Set(urls).size,2);
});
