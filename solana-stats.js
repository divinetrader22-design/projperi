(() => {
  const card = document.getElementById('solanaStats');
  if (!card) return;
  const el = id => document.getElementById(id);
  let busy = false, lastAttempt = 0, lastReading = null;
  const number = new Intl.NumberFormat(undefined,{maximumFractionDigits:0});
  async function refresh() {
    if (document.hidden || busy || (lastAttempt && Date.now()-lastAttempt<60000)) return;
    busy=true; lastAttempt=Date.now(); card.setAttribute('aria-busy','true');
    el('solanaState').textContent='Updating';
    try {
      const response=await fetch('/api/solana-stats',{cache:'no-store',signal:AbortSignal.timeout(28000)});
      if (!response.ok) throw new Error('Unavailable');
      const data=await response.json();
      const age=Date.now()-Date.parse(data.checked_at);
      if (!['live','partial'].includes(data.status) || !Number.isFinite(data.tps) || data.tps<0
          || !Number.isFinite(age) || age>180000 || age< -60000
          || !Number.isInteger(data.period_seconds) || data.period_seconds<1 || data.period_seconds>120
          || (data.success_rate!==null && (!Number.isFinite(data.success_rate) || data.success_rate<0 || data.success_rate>100))) throw new Error('Invalid stats');
      lastReading=data;
      el('solanaTps').textContent=number.format(data.tps);
      el('solanaRate').textContent=data.success_rate===null?'—':data.success_rate.toFixed(1)+'%';
      el('solanaWindow').textContent=data.period_seconds+'-second average · includes votes';
      el('solanaSample').textContent=data.success_rate===null?'Block sample unavailable':number.format(data.transaction_count)+' transactions · block '+number.format(data.block_slot);
      el('solanaState').textContent=data.status==='live'?'Updated':'Partial data';
      card.dataset.state=data.status;
      el('solanaUpdated').textContent='Updated '+new Date(data.checked_at).toLocaleTimeString()+'. Refreshes every minute.';
    } catch {
      card.dataset.state='unavailable'; el('solanaState').textContent='Unavailable';
      el('solanaUpdated').textContent=lastReading
        ? 'Update unavailable. Last reading: '+new Date(lastReading.checked_at).toLocaleTimeString()+'. Retrying automatically.'
        : 'Unable to load network data. Retrying automatically.';
    } finally { busy=false; card.setAttribute('aria-busy','false'); }
  }
  refresh();
  setInterval(refresh,60000);
  document.addEventListener('visibilitychange',refresh);
})();
