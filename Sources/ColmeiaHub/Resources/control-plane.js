(() => {
  const css = `
    .colmeia-control-hud{position:absolute;top:12px;right:12px;z-index:120;width:248px;padding:12px;border:1px solid rgba(148,163,184,.22);border-radius:12px;background:rgba(20,22,28,.88);backdrop-filter:blur(14px);box-shadow:0 10px 30px rgba(0,0,0,.25);font:12px system-ui;color:#e5e7eb;pointer-events:auto}
    .colmeia-control-hud h3{margin:0 0 8px;font-size:12px;letter-spacing:.04em;text-transform:uppercase;color:#93c5fd}
    .colmeia-control-hud .metrics{display:grid;grid-template-columns:1fr 1fr;gap:7px;margin-bottom:9px}
    .colmeia-control-hud .metric{padding:7px;border-radius:8px;background:rgba(255,255,255,.055)}
    .colmeia-control-hud .metric b{display:block;font-size:14px;color:#f8fafc}.colmeia-control-hud .metric span{font-size:10px;color:#94a3b8}
    .colmeia-control-hud .agent{display:flex;justify-content:space-between;gap:8px;padding:4px 0;border-top:1px solid rgba(255,255,255,.06);font-size:11px}
    .colmeia-control-hud .agent small{color:#94a3b8}.colmeia-control-hud .unknown{color:#f59e0b}
  `;
  const tag = document.createElement('style'); tag.textContent = css; document.head.appendChild(tag);

  const formatCost = (value, currency) => value == null ? 'indisponível' : `${currency || 'USD'} ${Number(value).toFixed(4)}`;
  const formatTokens = value => value == null ? 'indisponível' : Number(value).toLocaleString('pt-BR');

  window.colmeiaControlPlane = {
    start(api) {
      if (this.started) return;
      this.started = true;
      const host = document.getElementById('canvasWrap');
      if (!host) return;
      const hud = document.createElement('section');
      hud.className = 'colmeia-control-hud';
      hud.innerHTML = '<h3>Execução · telemetria</h3><div class="metrics"></div><div class="agents"></div>';
      host.appendChild(hud);
      const metrics = hud.querySelector('.metrics');
      const agents = hud.querySelector('.agents');
      const render = snapshot => {
        if (!snapshot) return;
        const currency = snapshot.currency || 'USD';
        const cost = snapshot.total_cost == null ? '<span class="unknown">indisponível</span>' : formatCost(snapshot.total_cost, currency);
        const burn = snapshot.burn_per_minute == null ? '<span class="unknown">indisponível</span>' : formatCost(snapshot.burn_per_minute, currency) + '/min';
        metrics.innerHTML = `<div class="metric"><b>${formatTokens(snapshot.total_tokens)}</b><span>tokens</span></div><div class="metric"><b>${cost}</b><span>custo total</span></div><div class="metric"><b>${burn}</b><span>consumo</span></div><div class="metric"><b>${snapshot.sample_count || 0}</b><span>amostras</span></div>`;
        agents.innerHTML = (snapshot.agents || []).slice(0,5).map(agent => `<div class="agent"><span>${String(agent.agent_name || agent.adapter || 'agente')}</span><small>${formatCost(agent.estimated_cost, agent.currency)}</small></div>`).join('');
      };
      const refresh = async () => {
        const workspaceID = api.workspaceID();
        if (!workspaceID) return;
        try { render(await api.rpc('telemetry.snapshot', {workspace_id: workspaceID})); } catch (_) {}
      };
      this.onEvent = event => {
        if (event && ['telemetry.sample','telemetry.activity','telemetry.aggregate.changed','telemetry.budget.alert'].includes(event.topic)) refresh();
      };
      refresh();
      this.timer = setInterval(refresh, 5000);
    }
  };
})();
