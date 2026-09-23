// Public network telemetry only. No wallet, project, or client data is used.
const ENDPOINTS = [...new Set([process.env.SOLANA_RPC_URL,
  'https://solana-rpc.publicnode.com', 'https://api.mainnet-beta.solana.com'].filter(Boolean))];
let cached = null, pending = null;
const integer = value => Number.isSafeInteger(value) && value >= 0;
async function rpc(url, method, params) {
  const response = await fetch(url, { method:'POST', cache:'no-store',
    headers:{'Content-Type':'application/json'}, signal:AbortSignal.timeout(4000),
    body:JSON.stringify({jsonrpc:'2.0',id:method,method,params}) });
  if (!response.ok) throw new Error('Provider unavailable');
  const data = await response.json();
  if (data.error || data.id !== method) throw new Error('RPC unavailable');
  return data.result;
}
async function collect() {
  let partial = null;
  for (const endpoint of ENDPOINTS) {
    try {
      const [samples, slot] = await Promise.all([
        rpc(endpoint,'getRecentPerformanceSamples',[1]),
        rpc(endpoint,'getSlot',[{commitment:'finalized'}])
      ]);
      const sample = samples?.[0];
      if (!sample || !integer(sample.numTransactions) || !integer(sample.slot) || !integer(slot)
          || !integer(sample.samplePeriodSecs) || sample.samplePeriodSecs < 1 || sample.samplePeriodSecs > 120
          || Math.abs(slot-sample.slot)>600) throw new Error('Invalid performance sample');
      const snapshot = {status:'partial', tps:sample.numTransactions/sample.samplePeriodSecs,
        period_seconds:sample.samplePeriodSecs, performance_slot:sample.slot, success_rate:null,
        transaction_count:null, block_slot:null, block_at:null, checked_at:new Date().toISOString()};
      partial = snapshot;
      const block = await rpc(endpoint,'getBlock',[slot,{commitment:'finalized',encoding:'json',
        transactionDetails:'full',maxSupportedTransactionVersion:0,rewards:false}]);
      const age = Date.now()/1000 - block?.blockTime;
      if (Number.isFinite(block?.blockTime) && (age > 300 || age < -60)) partial = null;
      if (!Number.isFinite(block?.blockTime) || age > 300 || age < -60 || !Array.isArray(block.transactions)
          || !block.transactions.length || block.transactions.some(tx=>!tx.meta || !Object.hasOwn(tx.meta,'err')
            || (tx.meta.err !== null && typeof tx.meta.err !== 'object' && typeof tx.meta.err !== 'string'))) {
        throw new Error('Incomplete or stale block');
      }
      const successful = block.transactions.filter(tx=>tx.meta.err === null).length;
      return {...snapshot,status:'live',success_rate:successful/block.transactions.length*100,
        transaction_count:block.transactions.length,block_slot:slot,
        block_at:new Date(block.blockTime*1000).toISOString(),checked_at:new Date().toISOString()};
    } catch { /* Try each documented provider once; never invent missing metrics. */ }
  }
  if (partial) return partial;
  throw new Error('Network stats unavailable');
}
module.exports = async function handler(req,res) {
  if (req.method !== 'GET') { res.setHeader('Allow','GET'); return res.status(405).json({status:'error'}); }
  try {
    if (!cached || Date.now()-cached.at>=60000) {
      if (!pending) pending=collect().then(data=>{cached={at:Date.now(),data};return data;}).finally(()=>{pending=null;});
      await pending;
    }
    res.setHeader('Cache-Control','public, max-age=0, s-maxage=60');
    return res.status(200).json(cached.data);
  } catch {
    res.setHeader('Cache-Control','no-store');
    return res.status(503).json({status:'unavailable',message:'Solana network stats are temporarily unavailable.'});
  }
};
