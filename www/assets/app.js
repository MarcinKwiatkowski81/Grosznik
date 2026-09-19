// Grosznik SPA
'use strict';

const App = (() => {

// ── API ───────────────────────────────────────────────────────────────────────
const api = async (url, opts = {}) => {
  opts.credentials = 'same-origin';
  if (opts.body && typeof opts.body === 'object') {
    opts.body    = JSON.stringify(opts.body);
    opts.headers = {...(opts.headers||{}), 'Content-Type':'application/json'};
  }
  const r    = await fetch(url, opts);
  const text = await r.text();
  try { return {ok: r.ok, status: r.status, data: JSON.parse(text)}; }
  catch { return {ok: r.ok, status: r.status, data: text}; }
};

// ── State ─────────────────────────────────────────────────────────────────────
let currentUser = null;
let accounts    = [];
let categories  = [];

// ── Formatters ────────────────────────────────────────────────────────────────
const fmt = (v, cur = 'PLN') =>
  Number(v||0).toLocaleString('pl-PL', {minimumFractionDigits:2, maximumFractionDigits:2}) + ' ' + cur;
const fmtDate = ts =>
  new Date((ts||0)*1000).toLocaleDateString('pl-PL');

// ── DOM ───────────────────────────────────────────────────────────────────────
const el = id => document.getElementById(id);

// ── Init ──────────────────────────────────────────────────────────────────────
const init = async () => {
  const setup = await api('/api/auth.lua?action=setup_status');
  if (setup.ok && setup.data.needs_setup) {
    el('login-form').style.display   = 'none';
    el('setup-form').style.display   = 'block';
    el('login-screen').style.display = 'block';
    return;
  }
  const me = await api('/api/auth.lua?action=me');
  if (me.ok) { currentUser = me.data; await showApp(); }
  else showLogin();
};

// ── Auth ──────────────────────────────────────────────────────────────────────
const login = async () => {
  const r = await api('/api/auth.lua?action=login', {
    method:'POST', body:{username: el('l-user').value, password: el('l-pass').value}
  });
  if (r.ok) { currentUser = r.data; await showApp(); }
  else { el('login-err').textContent = r.data.error || 'Błąd logowania'; }
};

const register = async () => {
  const r = await api('/api/auth.lua?action=register', {
    method:'POST',
    body:{username:el('s-user').value, email:el('s-email').value, password:el('s-pass').value}
  });
  if (r.ok) { currentUser = r.data; await showApp(); }
  else { el('setup-err').textContent = r.data.error || 'Błąd rejestracji'; }
};

const logout = async () => {
  await api('/api/auth.lua?action=logout', {method:'POST'});
  currentUser = null; showLogin();
};

const showLogin = () => {
  el('login-form').style.display   = '';
  el('setup-form').style.display   = 'none';
  el('login-screen').style.display = 'block';
  el('app-screen').style.display   = 'none';
  el('app-screen').classList.remove('visible');
};

const showApp = async () => {
  el('login-screen').style.display = 'none';
  el('app-screen').style.display   = 'flex';
  el('app-screen').classList.add('visible');
  const [aR, cR] = await Promise.all([api('/api/accounts.lua'), api('/api/categories.lua')]);
  accounts   = aR.ok ? aR.data : [];
  categories = cR.ok ? cR.data : [];
  document.querySelectorAll('.nav-item[data-view]').forEach(a => {
    a.onclick = e => { e.preventDefault(); navigate(a.dataset.view); };
  });
  navigate('dashboard');
};

// ── Navigation ────────────────────────────────────────────────────────────────
const navigate = async view => {
  document.querySelectorAll('.nav-item').forEach(a =>
    a.classList.toggle('active', a.dataset.view === view));
  const main = el('main-content');
  main.innerHTML = '<div style="padding:40px;text-align:center;color:var(--text2)">Ładowanie…</div>';
  const views = {
    dashboard,
    accounts:     accountsView,
    transactions: transactionsView,
    obligations:  obligationsView,
    reports:      reportsView,
    settings:     settingsView
  };
  await (views[view] || views.dashboard)(main);
};

// ── Dashboard ─────────────────────────────────────────────────────────────────
const dashboard = async (c) => {
  const now = new Date();
  const [txR, oblR, fcR] = await Promise.all([
    api('/api/transactions.lua?limit=8'),
    api(`/api/obligations.lua?sub=instances&year=${now.getFullYear()}&month=${now.getMonth()+1}`),
    api('/api/reports.lua?report=forecast')
  ]);
  const txns = txR.ok ? txR.data : [];
  const obls = oblR.ok ? oblR.data : [];
  const fc   = fcR.ok  ? fcR.data  : {};

  const assets = accounts.filter(a=>a.type!=='credit_card').reduce((s,a)=>s+Number(a.balance),0);
  const debt   = accounts.filter(a=>a.type==='credit_card').reduce((s,a)=>s+Number(a.balance),0);
  const pendingObls = obls.filter(o=>o.status==='pending');
  const pendingCost = pendingObls.reduce((s,o)=>s+Number(o.amount),0);

  c.innerHTML = `
  <div class="section-header"><h2>Dashboard</h2></div>
  <div class="grid-4">
    <div class="card"><div class="card-title">Łączne aktywa</div>
      <div class="card-value accent">${fmt(assets)}</div></div>
    <div class="card"><div class="card-title">Zadłużenie kart</div>
      <div class="card-value ${debt>0?'red':'green'}">${fmt(debt)}</div></div>
    <div class="card"><div class="card-title">Oczekujące zobowiązania</div>
      <div class="card-value red">${fmt(pendingCost)}</div></div>
    <div class="card"><div class="card-title">Prognoza EOM</div>
      <div class="card-value ${(fc.projected_eom||0)>=0?'green':'red'}">${fmt(fc.projected_eom||0)}</div></div>
  </div>
  <div class="grid-2">
    <div class="card">
      <div class="card-title">Konta</div>
      ${accounts.slice(0,6).map(a=>`
        <div style="display:flex;justify-content:space-between;padding:8px 0;border-bottom:1px solid var(--border)">
          <span>${a.name} <small style="color:var(--text2)">${a.type}</small></span>
          <span class="${Number(a.balance)<0?'amount-neg':'amount-pos'}">${fmt(a.balance,a.currency)}</span>
        </div>`).join('')}
    </div>
    <div class="card">
      <div class="card-title">Najbliższe zobowiązania</div>
      ${pendingObls.slice(0,5).map(o=>`
        <div style="display:flex;justify-content:space-between;padding:8px 0;border-bottom:1px solid var(--border)">
          <div><div>${o.name}</div><small style="color:var(--text2)">${fmtDate(o.due_date)}</small></div>
          <div style="text-align:right">
            <div class="amount-neg">${fmt(o.amount,o.currency)}</div>
            <span class="badge badge-${o.status}">${o.status}</span>
          </div>
        </div>`).join('')}
      ${pendingObls.length===0?'<p style="color:var(--text2);margin-top:8px">Brak oczekujących zobowiązań ✅</p>':''}
    </div>
  </div>
  <div class="card">
    <div class="card-title">Ostatnie transakcje</div>
    <div class="table-wrap"><table>
      <thead><tr><th>Data</th><th>Opis</th><th>Kategoria</th><th>Konto</th><th style="text-align:right">Kwota</th></tr></thead>
      <tbody>${txns.map(t=>`<tr>
        <td>${fmtDate(t.date)}</td>
        <td>${t.description||'—'}</td>
        <td>${t.cat_icon||''} ${t.cat_name||'—'}</td>
        <td>${t.account_name||'—'}</td>
        <td style="text-align:right" class="${t.type==='income'?'amount-pos':'amount-neg'}">
          ${t.type==='income'?'+':'−'}${fmt(t.amount,t.currency)}</td>
      </tr>`).join('')}</tbody>
    </table></div>
  </div>`;
};

// ── Accounts ──────────────────────────────────────────────────────────────────
const accountsView = async (c) => {
  const r = await api('/api/accounts.lua');
  accounts = r.ok ? r.data : [];
  const icons  = {checking:'🏦',savings:'🏧',deposit:'📈',credit_card:'💳',cash:'💵',investment:'📊'};
  const labels = {checking:'Bieżące',savings:'Oszczędnościowe',deposit:'Lokata',
                  credit_card:'Karta kredytowa',cash:'Gotówka',investment:'Inwestycje'};
  c.innerHTML = `
  <div class="section-header">
    <h2>Konta</h2>
    <button class="btn btn-primary" onclick="App.modalNewAccount()">+ Dodaj konto</button>
  </div>
  <div class="grid-3">
  ${accounts.map(a=>`
    <div class="card" style="cursor:pointer" onclick="App.modalEditAccount(${a.id})">
      <div style="display:flex;justify-content:space-between;align-items:flex-start">
        <div>
          <div style="font-size:1.5rem">${icons[a.type]||'🏦'}</div>
          <div style="font-weight:700;margin-top:4px">${a.name}</div>
          <div style="color:var(--text2);font-size:12px">${labels[a.type]||a.type}</div>
        </div>
        <div style="text-align:right">
          <div style="font-size:1.2rem;font-weight:700;color:${Number(a.balance)<0?'var(--red)':'var(--text)'}">${fmt(a.balance,a.currency)}</div>
          ${a.type==='credit_card'&&a.available_credit!=null?`<div style="color:var(--green);font-size:12px">Dostępne: ${fmt(a.available_credit,a.currency)}</div>`:''}
        </div>
      </div>
      ${a.savings_goal&&Number(a.savings_goal)>0?`
        <div style="margin-top:12px">
          <div style="display:flex;justify-content:space-between;font-size:12px;color:var(--text2)">
            <span>${a.savings_goal_name||'Cel oszczędnościowy'}</span><span>${a.goal_pct||0}%</span>
          </div>
          <div class="progress-bar"><div class="progress-fill" style="width:${Math.min(Number(a.goal_pct||0),100)}%"></div></div>
        </div>`:''}
    </div>`).join('')}
  </div>`;
};

// ── Transactions ──────────────────────────────────────────────────────────────
const transactionsView = async (c) => {
  let filterType = 'all', filterAcct = '', renderFn;
  const typeColors = {income:'var(--green)',expense:'var(--red)',transfer:'var(--accent)',
                      card_payment:'var(--purple)',atm:'var(--yellow)'};
  const typeLabels = {income:'Przychód',expense:'Wydatek',transfer:'Przelew',
                      card_payment:'Spłata karty',atm:'Bankomat',all:'Wszystkie'};

  c.innerHTML = `
  <div class="section-header">
    <h2>Transakcje</h2>
    <button class="btn btn-primary" onclick="App.modalNewTransaction()">+ Dodaj</button>
  </div>
  <div class="type-tabs" id="tx-tabs">
    ${['all','income','expense','transfer'].map(t=>`
      <button class="type-tab ${t==='all'?'active':''}" data-txtype="${t}"
        onclick="App._setTxFilter('${t}')">${typeLabels[t]||t}</button>`).join('')}
    <select id="tx-acct-sel" onchange="App._setTxAcct(this.value)"
      style="margin-left:auto;background:var(--bg3);border:1px solid var(--border);border-radius:6px;padding:6px 10px;color:var(--text)">
      <option value="">Wszystkie konta</option>
      ${accounts.map(a=>`<option value="${a.id}">${a.name}</option>`).join('')}
    </select>
  </div>
  <div class="card">
    <div class="table-wrap"><table>
      <thead><tr><th>Data</th><th>Opis</th><th>Kategoria</th><th>Konto</th><th>Typ</th><th style="text-align:right">Kwota</th><th></th></tr></thead>
      <tbody id="tx-body"><tr><td colspan="7" style="text-align:center;padding:20px;color:var(--text2)">Ładowanie…</td></tr></tbody>
    </table></div>
  </div>`;

  renderFn = async () => {
    const params = new URLSearchParams({limit:40});
    if (filterType !== 'all') params.set('type', filterType);
    if (filterAcct) params.set('account_id', filterAcct);
    const r = await api('/api/transactions.lua?' + params);
    const txns = r.ok ? r.data : [];
    el('tx-body').innerHTML = txns.map(t=>`<tr>
      <td>${fmtDate(t.date)}</td>
      <td>${t.description||'—'}</td>
      <td>${t.cat_icon||''} ${t.cat_name||'—'}</td>
      <td>${t.account_name||'—'}</td>
      <td><span style="color:${typeColors[t.type]||'var(--text)'};font-size:11px">${typeLabels[t.type]||t.type}</span></td>
      <td style="text-align:right" class="${t.type==='income'?'amount-pos':'amount-neg'}">
        ${t.type==='income'?'+':'−'}${fmt(t.amount,t.currency)}</td>
      <td><button class="btn btn-danger" style="padding:3px 8px;font-size:11px"
          onclick="App.deleteTransaction(${t.id})">✕</button></td>
    </tr>`).join('') || '<tr><td colspan="7" style="text-align:center;color:var(--text2);padding:16px">Brak transakcji</td></tr>';
  };

  App._txRender = renderFn;
  App._setTxFilter = type => {
    filterType = type;
    document.querySelectorAll('[data-txtype]').forEach(b => b.classList.toggle('active', b.dataset.txtype===type));
    renderFn();
  };
  App._setTxAcct = v => { filterAcct = v; renderFn(); };
  await renderFn();
};

const deleteTransaction = async id => {
  if (!confirm('Usunąć tę transakcję? Saldo konta zostanie przywrócone.')) return;
  const r = await api(`/api/transactions.lua?id=${id}`, {method:'DELETE'});
  if (r.ok) { accounts = (await api('/api/accounts.lua')).data||accounts; if(App._txRender) await App._txRender(); }
};

// ── Obligations ───────────────────────────────────────────────────────────────
const obligationsView = async (c) => {
  const now = new Date();
  const y = now.getFullYear(), m = now.getMonth()+1;
  const [oblR, instR] = await Promise.all([
    api('/api/obligations.lua'),
    api(`/api/obligations.lua?sub=instances&year=${y}&month=${m}`)
  ]);
  const obls  = oblR.ok  ? oblR.data  : [];
  const insts = instR.ok ? instR.data : [];
  const statusLabel = {pending:'Oczekuje',paid:'Opłacone',overdue:'Przeterminowane'};
  c.innerHTML = `
  <div class="section-header">
    <h2>Zobowiązania</h2>
    <button class="btn btn-primary" onclick="App.modalNewObligation()">+ Dodaj</button>
  </div>
  <div class="card">
    <div class="card-title">Instancje — ${m.toString().padStart(2,'0')}.${y}</div>
    <div class="table-wrap"><table>
      <thead><tr><th>Nazwa</th><th>Termin</th><th style="text-align:right">Kwota</th><th>Status</th><th></th></tr></thead>
      <tbody>
      ${insts.map(i=>`<tr>
        <td>${i.name}</td>
        <td>${fmtDate(i.due_date)}</td>
        <td style="text-align:right" class="amount-neg">${fmt(i.amount,i.currency)}</td>
        <td><span class="badge badge-${i.status}">${statusLabel[i.status]||i.status}</span></td>
        <td>${i.status==='pending'?`<button class="btn btn-success" style="padding:4px 10px;font-size:11px"
            onclick="App.payObligation(${i.id})">Opłać</button>`:''}
        </td>
      </tr>`).join('')}
      ${insts.length===0?'<tr><td colspan="5" style="text-align:center;color:var(--text2);padding:20px">Brak instancji na ten miesiąc</td></tr>':''}
      </tbody>
    </table></div>
  </div>
  <div class="section-header"><h2>Szablony</h2></div>
  <div class="grid-3">
  ${obls.map(o=>`
    <div class="card">
      <div style="display:flex;justify-content:space-between;align-items:center">
        <div>
          <div style="font-weight:700">${o.name}</div>
          <div style="color:var(--text2);font-size:12px">${o.account_name||'?'} · dzień ${o.payment_day} · ${o.frequency}</div>
        </div>
        <div class="amount-neg" style="font-weight:700">${fmt(o.amount,o.currency)}</div>
      </div>
    </div>`).join('')}
  </div>`;
};

const payObligation = async id => {
  const acct = accounts.find(a=>a.type==='checking'||a.type==='savings');
  const r = await api(`/api/obligations.lua?sub=instances&id=${id}&action=pay`, {
    method:'POST',
    body: acct ? {create_transaction:true, account_id:acct.id} : {}
  });
  if (r.ok) { accounts=(await api('/api/accounts.lua')).data||accounts; await obligationsView(el('main-content')); }
};

// ── Reports ───────────────────────────────────────────────────────────────────
const reportsView = async (c) => {
  const [cfR, catR, fcR] = await Promise.all([
    api('/api/reports.lua?report=cashflow&months=6'),
    api('/api/reports.lua?report=categories'),
    api('/api/reports.lua?report=forecast')
  ]);
  const cf  = cfR.ok  ? cfR.data  : [];
  const cat = catR.ok ? catR.data : [];
  const fc  = fcR.ok  ? fcR.data  : {};

  c.innerHTML = `
  <div class="section-header"><h2>Raporty i Analityka</h2></div>
  <div class="grid-2">
    <div class="card">
      <div class="card-title">Cashflow — ostatnie 6 miesięcy</div>
      <div class="chart-wrap"><canvas id="ch-cf"></canvas></div>
    </div>
    <div class="card">
      <div class="card-title">Struktura wydatków (bieżący miesiąc)</div>
      <div class="chart-wrap"><canvas id="ch-cat"></canvas></div>
    </div>
  </div>
  <div class="card">
    <div class="card-title">Prognoza salda do końca miesiąca</div>
    <div class="grid-4" style="margin-bottom:16px">
      <div><div style="color:var(--text2);font-size:12px">Aktualne saldo</div>
           <div style="font-weight:700">${fmt(fc.current_balance)}</div></div>
      <div><div style="color:var(--text2);font-size:12px">Oczekujące koszty</div>
           <div style="font-weight:700;color:var(--red)">${fmt(fc.pending_costs)}</div></div>
      <div><div style="color:var(--text2);font-size:12px">Oczekiwane przychody</div>
           <div style="font-weight:700;color:var(--green)">${fmt(fc.expected_income)}</div></div>
      <div><div style="color:var(--text2);font-size:12px">Prognoza EOM</div>
           <div style="font-weight:700;color:${(fc.projected_eom||0)>=0?'var(--green)':'var(--red)'}">${fmt(fc.projected_eom)}</div></div>
    </div>
    <div class="chart-wrap"><canvas id="ch-fc"></canvas></div>
  </div>`;

  const chartDefaults = { responsive:true, maintainAspectRatio:false,
    plugins:{legend:{labels:{color:'#e6edf3'}}},
    scales:{x:{ticks:{color:'#8b949e'}}, y:{ticks:{color:'#8b949e'}}} };

  if (cf.length) new Chart(document.getElementById('ch-cf'), {
    type:'bar',
    data:{
      labels: cf.map(m=>m.label),
      datasets:[
        {label:'Przychody', data:cf.map(m=>m.income),  backgroundColor:'rgba(46,160,67,0.7)'},
        {label:'Wydatki',   data:cf.map(m=>m.expense), backgroundColor:'rgba(248,81,73,0.7)'}
      ]
    },
    options: chartDefaults
  });

  if (cat.length) new Chart(document.getElementById('ch-cat'), {
    type:'doughnut',
    data:{
      labels: cat.map(c=>c.name),
      datasets:[{data:cat.map(c=>c.total), backgroundColor:cat.map(c=>c.color||'#8b949e')}]
    },
    options:{responsive:true, maintainAspectRatio:false,
      plugins:{legend:{position:'right', labels:{color:'#e6edf3',font:{size:11}}}}}
  });

  const pts = fc.forecast_points||[];
  if (pts.length) new Chart(document.getElementById('ch-fc'), {
    type:'line',
    data:{
      labels: pts.map(p=>p.date),
      datasets:[{label:'Prognoza salda', data:pts.map(p=>p.balance),
        borderColor:'#388bfd', backgroundColor:'rgba(56,139,253,0.1)',
        fill:true, tension:0.3, pointRadius:2}]
    },
    options: chartDefaults
  });
};

// ── Settings ──────────────────────────────────────────────────────────────────
const settingsView = async (c) => {
  const meR = await api('/api/auth.lua?action=me');
  const me  = meR.ok ? meR.data : {};
  c.innerHTML = `
  <div class="section-header"><h2>Ustawienia</h2></div>
  <div class="card" style="max-width:480px">
    <div class="card-title">Profil użytkownika</div>
    <div class="form-group"><label>Nazwa użytkownika</label>
      <input value="${me.username||''}" disabled style="opacity:.6"></div>
    <div class="form-group"><label>E-mail</label>
      <input value="${me.email||''}" disabled style="opacity:.6"></div>
    <div class="form-group"><label>Telegram Chat ID</label>
      <input id="cfg-tg" value="${me.telegram_chat_id||''}" placeholder="np. 123456789">
      <small style="color:var(--text2)">Wpisz swoje Chat ID (znajdź je pisząc do @userinfobot)</small></div>
    <div class="form-group"><label>Domyślna waluta</label>
      <select id="cfg-cur">
        ${['PLN','EUR','USD','GBP'].map(c=>`<option ${me.default_currency===c?'selected':''}>${c}</option>`).join('')}
      </select></div>
    <div class="form-group"><label>Alert salda — próg (PLN)</label>
      <input id="cfg-alert" type="number" value="${me.balance_alert_threshold||500}"></div>
    <div class="form-group"><label>Nowe hasło (pozostaw puste aby nie zmieniać)</label>
      <input id="cfg-pwd" type="password" placeholder="Minimum 8 znaków"></div>
    <button class="btn btn-primary" onclick="App.saveSettings()">Zapisz ustawienia</button>
    <div id="cfg-msg" style="margin-top:10px;font-size:13px"></div>
  </div>`;
};

const saveSettings = async () => {
  const r = await api('/api/auth.lua?action=profile', {
    method:'PUT',
    body:{
      telegram_chat_id:        el('cfg-tg').value,
      default_currency:        el('cfg-cur').value,
      balance_alert_threshold: parseFloat(el('cfg-alert').value)||500,
      new_password:            el('cfg-pwd').value
    }
  });
  const msg = el('cfg-msg');
  msg.textContent = r.ok ? '✅ Zapisano' : (r.data&&r.data.error||'Błąd zapisu');
  msg.style.color = r.ok ? 'var(--green)' : 'var(--red)';
};

// ── Modal ─────────────────────────────────────────────────────────────────────
const showModal = (title, body) => {
  el('modal-title').textContent = title;
  el('modal-body').innerHTML    = body;
  el('modal-overlay').style.display = 'flex';
};
const closeModal = () => { el('modal-overlay').style.display = 'none'; };

document.addEventListener('DOMContentLoaded', () => {
  el('modal-overlay').addEventListener('click', e => {
    if (e.target === el('modal-overlay')) closeModal();
  });
});

// ── Modal: New Account ────────────────────────────────────────────────────────
const modalNewAccount = () => {
  showModal('Nowe konto', `
    <div class="form-group"><label>Nazwa konta</label>
      <input id="ma-name" placeholder="np. PKO BP Główne"></div>
    <div class="form-row">
      <div class="form-group"><label>Typ</label>
        <select id="ma-type" onchange="App._acctType(this.value)">
          <option value="checking">Bieżące (ROR)</option>
          <option value="savings">Oszczędnościowe</option>
          <option value="deposit">Lokata</option>
          <option value="credit_card">Karta kredytowa</option>
          <option value="cash">Gotówka</option>
          <option value="investment">Inwestycje</option>
        </select></div>
      <div class="form-group"><label>Waluta</label>
        <select id="ma-cur"><option>PLN</option><option>EUR</option><option>USD</option><option>GBP</option></select></div>
    </div>
    <div class="form-group"><label>Saldo początkowe</label>
      <input id="ma-bal" type="number" value="0" step="0.01"></div>
    <div id="ma-extra"></div>
    <div class="modal-footer">
      <button class="btn btn-ghost" onclick="App.closeModal()">Anuluj</button>
      <button class="btn btn-primary" onclick="App.saveNewAccount()">Utwórz</button>
    </div>`);
  _acctType('checking');
};

const _acctType = type => {
  const extra = el('ma-extra');
  if (type==='savings'||type==='deposit') {
    extra.innerHTML = `
      <div class="form-row">
        <div class="form-group"><label>Oprocentowanie (%)</label>
          <input id="ma-rate" type="number" step="0.01" placeholder="np. 5.5"></div>
        <div class="form-group"><label>Cel kwota</label>
          <input id="ma-goal" type="number" step="0.01" placeholder="opcjonalnie"></div>
      </div>
      <div class="form-group"><label>Nazwa celu</label>
        <input id="ma-goalname" placeholder="np. Na wakacje"></div>`;
  } else if (type==='credit_card') {
    extra.innerHTML = `
      <div class="form-row">
        <div class="form-group"><label>Limit kredytowy</label>
          <input id="ma-limit" type="number" step="0.01"></div>
        <div class="form-group"><label>Dzień zamknięcia cyklu</label>
          <input id="ma-bday" type="number" min="1" max="31" placeholder="np. 25"></div>
      </div>
      <div class="form-group"><label>Dni na bezpłatną spłatę</label>
        <input id="ma-pdays" type="number" placeholder="np. 21"></div>`;
  } else {
    extra.innerHTML = '';
  }
};

const saveNewAccount = async () => {
  const type = el('ma-type').value;
  const body = {name:el('ma-name').value, type, currency:el('ma-cur').value,
                balance:parseFloat(el('ma-bal').value)||0};
  if (type==='savings'||type==='deposit') {
    if (el('ma-rate'))     body.interest_rate     = parseFloat(el('ma-rate').value)||null;
    if (el('ma-goal'))     body.savings_goal      = parseFloat(el('ma-goal').value)||null;
    if (el('ma-goalname')) body.savings_goal_name = el('ma-goalname').value;
  } else if (type==='credit_card') {
    if (el('ma-limit')) body.credit_limit     = parseFloat(el('ma-limit').value)||null;
    if (el('ma-bday'))  body.billing_day      = parseInt(el('ma-bday').value)||null;
    if (el('ma-pdays')) body.payment_due_days = parseInt(el('ma-pdays').value)||null;
  }
  const r = await api('/api/accounts.lua', {method:'POST', body});
  if (r.ok) { closeModal(); accounts=(await api('/api/accounts.lua')).data||accounts; await accountsView(el('main-content')); }
  else alert(r.data&&r.data.error||'Błąd');
};

// ── Modal: Edit Account ───────────────────────────────────────────────────────
const modalEditAccount = async id => {
  const r = await api(`/api/accounts.lua?id=${id}`);
  if (!r.ok) return;
  const a = r.data;
  showModal('Edytuj: '+a.name, `
    <div class="form-group"><label>Saldo (ręczna korekta)</label>
      <input id="ea-bal" type="number" step="0.01" value="${a.balance}"></div>
    <div class="modal-footer">
      <button class="btn btn-danger" onclick="App.deleteAccount(${id})">Dezaktywuj konto</button>
      <div style="flex:1"></div>
      <button class="btn btn-ghost" onclick="App.closeModal()">Anuluj</button>
      <button class="btn btn-primary" onclick="App.updateAccountBalance(${id})">Zapisz</button>
    </div>`);
};

const updateAccountBalance = async id => {
  const r = await api(`/api/accounts.lua?id=${id}`, {method:'PUT', body:{balance:parseFloat(el('ea-bal').value)}});
  if (r.ok) { closeModal(); accounts=(await api('/api/accounts.lua')).data||accounts; await accountsView(el('main-content')); }
};
const deleteAccount = async id => {
  if (!confirm('Dezaktywować konto?')) return;
  await api(`/api/accounts.lua?id=${id}`, {method:'DELETE'});
  closeModal(); accounts=(await api('/api/accounts.lua')).data||accounts; await accountsView(el('main-content'));
};

// ── Modal: New Transaction ────────────────────────────────────────────────────
const modalNewTransaction = () => {
  const catOpts = categories.filter(c=>c.type!=='transfer')
    .map(c=>`<option value="${c.id}">${c.parent_id?'  ':''} ${c.icon||''} ${c.name}</option>`).join('');
  const acctOpts = accounts.map(a=>`<option value="${a.id}">${a.name}</option>`).join('');
  showModal('Nowa transakcja', `
    <div class="type-tabs">
      ${[['expense','Wydatek'],['income','Przychód'],['transfer','Przelew'],['atm','Bankomat']].map(([v,l])=>`
        <button class="type-tab ${v==='expense'?'active':''}" data-txtype="${v}"
          onclick="document.querySelectorAll('[data-txtype]').forEach(b=>b.classList.remove('active'));this.classList.add('active');App._txTypeToggle('${v}')">${l}</button>`).join('')}
    </div>
    <div class="form-row">
      <div class="form-group"><label>Kwota</label>
        <input id="nt-amt" type="number" step="0.01" min="0.01"></div>
      <div class="form-group"><label>Waluta</label>
        <select id="nt-cur"><option>PLN</option><option>EUR</option><option>USD</option></select></div>
    </div>
    <div class="form-group"><label>Konto</label><select id="nt-acct">${acctOpts}</select></div>
    <div class="form-group" id="nt-to-wrap" style="display:none">
      <label>Konto docelowe</label><select id="nt-to">${acctOpts}</select></div>
    <div class="form-group"><label>Kategoria</label><select id="nt-cat">${catOpts}</select></div>
    <div class="form-group"><label>Data</label>
      <input id="nt-date" type="date" value="${new Date().toISOString().slice(0,10)}"></div>
    <div class="form-group"><label>Opis</label><input id="nt-desc" placeholder="opcjonalnie"></div>
    <div class="modal-footer">
      <button class="btn btn-ghost" onclick="App.closeModal()">Anuluj</button>
      <button class="btn btn-primary" onclick="App.saveNewTransaction()">Dodaj</button>
    </div>`);
  App._txTypeToggle = v => {
    el('nt-to-wrap').style.display = (v==='transfer'||v==='atm') ? '' : 'none';
  };
};

const saveNewTransaction = async () => {
  const active = document.querySelector('[data-txtype].active');
  const type   = active ? active.dataset.txtype : 'expense';
  const date   = Math.floor(new Date(el('nt-date').value).getTime()/1000);
  const body   = {type, amount:parseFloat(el('nt-amt').value),
                  currency:el('nt-cur').value, account_id:parseInt(el('nt-acct').value),
                  category_id:parseInt(el('nt-cat').value), date, description:el('nt-desc').value};
  const toEl = el('nt-to');
  if ((type==='transfer'||type==='atm') && toEl) body.to_account_id = parseInt(toEl.value);
  const r = await api('/api/transactions.lua', {method:'POST', body});
  if (r.ok) { closeModal(); accounts=(await api('/api/accounts.lua')).data||accounts; await transactionsView(el('main-content')); }
  else alert(r.data&&r.data.error||'Błąd');
};

// ── Modal: New Obligation ─────────────────────────────────────────────────────
const modalNewObligation = () => {
  const acctOpts = accounts.map(a=>`<option value="${a.id}">${a.name}</option>`).join('');
  const catOpts  = categories.filter(c=>c.type==='expense')
    .map(c=>`<option value="${c.id}">${c.icon||''} ${c.name}</option>`).join('');
  showModal('Nowe zobowiązanie stałe', `
    <div class="form-group"><label>Nazwa</label>
      <input id="no-name" placeholder="np. Czynsz, Netflix, Ubezpieczenie"></div>
    <div class="form-row">
      <div class="form-group"><label>Kwota</label>
        <input id="no-amt" type="number" step="0.01"></div>
      <div class="form-group"><label>Waluta</label>
        <select id="no-cur"><option>PLN</option><option>EUR</option><option>USD</option></select></div>
    </div>
    <div class="form-row">
      <div class="form-group"><label>Częstotliwość</label>
        <select id="no-freq"><option value="monthly">Miesięczna</option><option value="yearly">Roczna</option></select></div>
      <div class="form-group"><label>Dzień płatności</label>
        <input id="no-day" type="number" min="1" max="31" value="1"></div>
    </div>
    <div class="form-group"><label>Konto</label><select id="no-acct">${acctOpts}</select></div>
    <div class="form-group"><label>Kategoria</label><select id="no-cat">${catOpts}</select></div>
    <div class="modal-footer">
      <button class="btn btn-ghost" onclick="App.closeModal()">Anuluj</button>
      <button class="btn btn-primary" onclick="App.saveNewObligation()">Utwórz</button>
    </div>`);
};

const saveNewObligation = async () => {
  const r = await api('/api/obligations.lua', {method:'POST', body:{
    name:        el('no-name').value,
    amount:      parseFloat(el('no-amt').value),
    currency:    el('no-cur').value,
    frequency:   el('no-freq').value,
    payment_day: parseInt(el('no-day').value),
    account_id:  parseInt(el('no-acct').value),
    category_id: parseInt(el('no-cat').value)
  }});
  if (r.ok) { closeModal(); await obligationsView(el('main-content')); }
  else alert(r.data&&r.data.error||'Błąd');
};

// ── Public API ────────────────────────────────────────────────────────────────
return {
  init, login, register, logout, navigate, closeModal,
  modalNewAccount, modalEditAccount, saveNewAccount, updateAccountBalance, deleteAccount,
  modalNewTransaction, saveNewTransaction, deleteTransaction,
  modalNewObligation, saveNewObligation, payObligation,
  saveSettings,
  _acctType, _txRender: null, _txTypeToggle: ()=>{},
  _setTxFilter: ()=>{}, _setTxAcct: ()=>{}
};

})();

document.addEventListener('DOMContentLoaded', App.init);
