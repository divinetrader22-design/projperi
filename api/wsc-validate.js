const { SUPABASE_URL, SUPABASE_ANON_KEY } = require('../supabase-config.js');

// Configured wallet is only used on the server, never returned to the dashboard.
const WALLET = 'HBeSz4v5guAjoWqMQ8mbfEAsWDmKRXKMhkFEpg3BoHN4';
const RPC_URL = process.env.SOLANA_RPC_URL || 'https://api.mainnet-beta.solana.com';
const MESSAGES = {
  passed: 'WS-CON validation passed — required SOL balance verified.',
  insufficient: 'Insufficient SOL to start WS-CON.',
  unavailable: 'Unable to verify the SOL balance right now. Please try again.',
  denied: 'Unable to validate. Refresh your key status and quote, then try again.',
  quote: 'A SOL quote is not available yet.',
  changed: 'Your quote changed. Get the latest quote and try again.'
};

function lamports(value) {
  if (typeof value !== 'string' || !/^(0|[1-9]\d{0,8})(\.\d{1,9})?$/.test(value)) throw new Error('Invalid quote');
  const [whole, fraction = ''] = value.split('.');
  const amount = BigInt(whole) * 1000000000n + BigInt(fraction.padEnd(9, '0'));
  if (amount <= 0n) throw new Error('Invalid quote');
  return amount;
}

async function readQuote(authorization, projectId) {
  // Supabase verifies the JWT; the RPC enforces client ownership and a saved FWP-Key.
  const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/get_client_quote`, {
    method: 'POST', cache: 'no-store', signal: AbortSignal.timeout(6000),
    headers: { apikey: SUPABASE_ANON_KEY, Authorization: authorization, 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_project_id: projectId })
  });
  if ([401, 403].includes(response.status)) return { denied: true };
  if (!response.ok) throw new Error('Quote unavailable');
  return { quote: await response.json() };
}

async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store, private');
  const reply = (status, code, message, extra = {}) => res.status(status).json({ status: code, message, ...extra });
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return reply(405, 'error', 'Method not allowed.');
  }
  const authorization = req.headers.authorization;
  if (typeof authorization !== 'string' || !/^Bearer [A-Za-z0-9._-]+$/.test(authorization)) return reply(401, 'denied', MESSAGES.denied);
  let body;
  try { body = typeof req.body === 'string' ? JSON.parse(req.body) : req.body; } catch { return reply(400, 'error', 'Invalid request.'); }
  if (!body || typeof body.project_id !== 'string' || !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(body.project_id)
      || typeof body.quote_updated_at !== 'string' || body.quote_updated_at.length > 50) return reply(400, 'error', 'Invalid request.');
  try {
    const first = await readQuote(authorization, body.project_id);
    if (first.denied) return reply(403, 'denied', MESSAGES.denied);
    const quote = first.quote;
    if (!quote?.required_sol) return reply(409, 'quote_missing', MESSAGES.quote);
    if (quote.updated_at !== body.quote_updated_at) return reply(409, 'quote_changed', MESSAGES.changed);
    const required = lamports(quote.required_sol);
    const response = await fetch(RPC_URL, {
      method: 'POST', cache: 'no-store', signal: AbortSignal.timeout(8000),
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 'wsc-balance', method: 'getBalance', params: [WALLET, { commitment: 'confirmed' }] })
    });
    if (!response.ok) throw new Error('RPC unavailable');
    const packet = await response.json();
    // Fail closed if the RPC value cannot be represented exactly by this runtime.
    const balance = packet.result?.value;
    if (packet.error || packet.id !== 'wsc-balance' || !Number.isSafeInteger(balance) || balance < 0
        || !Number.isSafeInteger(packet.result?.context?.slot) || packet.result.context.slot < 0) throw new Error('Invalid RPC response');
    // Do not use stale quotes or grant success after the key was deleted during the RPC request.
    const latest = await readQuote(authorization, body.project_id);
    if (latest.denied) return reply(403, 'denied', MESSAGES.denied);
    if (!latest.quote || latest.quote.updated_at !== quote.updated_at || latest.quote.required_sol !== quote.required_sol
        || latest.quote.body !== quote.body) return reply(409, 'quote_changed', MESSAGES.changed);
    const enough = BigInt(balance) >= required;
    return reply(200, enough ? 'passed' : 'insufficient', enough ? MESSAGES.passed : MESSAGES.insufficient,
      { checked_at: new Date().toISOString(), slot: packet.result.context.slot });
  } catch {
    // Network/provider errors are not evidence of an insufficient balance.
    return reply(503, 'unavailable', MESSAGES.unavailable);
  }
}

module.exports = handler;
