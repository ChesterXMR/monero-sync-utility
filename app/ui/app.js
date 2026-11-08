'use strict';

const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

const $ = (id) => document.getElementById(id);

let status = null;
let logPos = null;
let historyKey = null;
let settingsAutoOpened = false;
let busy = false;

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

function fmtMinutes(m) {
  if (m === 60) return '1 hour';
  if (m >= 60 && m % 60 === 0) return `${m / 60} hours`;
  return `${m} minutes`;
}

function fmtWhen(iso, withWeekday = true) {
  const d = new Date(iso);
  if (isNaN(d)) return '?';
  const date = d.toLocaleDateString(undefined, withWeekday
    ? { weekday: 'short', day: 'numeric', month: 'short' }
    : { day: 'numeric', month: 'short' });
  const time = d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit', hour12: false });
  return `${date}, ${time}`;
}

function fmtElapsed(fromIso) {
  const s = Math.max(0, Math.floor((Date.now() - new Date(fromIso)) / 1000));
  const m = Math.floor(s / 60);
  return m > 0 ? `${m} min ${s % 60}s` : `${s}s`;
}

const RESULT = {
  'OK': 'Synced',
  'PARTIAL': 'Partial sync',
  'INTERRUPTED': 'Interrupted',
  'SKIP-NOTMOUNTED': 'Skipped - drive locked',
  'SKIP-VBOX': 'Skipped - VM running',
  'SKIP-RUNNING': 'Skipped - already running',
  'SKIP-OVERLAP': 'Skipped - run in progress',
  'STOPPED-VBOX': 'Stopped - VM started',
  'STOPPED-USER': 'Stopped by you',
  'TERMINATED': 'TERMINATED - not flushed',
};

function resultLabel(s) {
  if (RESULT[s]) return RESULT[s];
  if (s.startsWith('ERROR-STUCK')) return 'Daemon would not stop';
  if (s.startsWith('ERROR')) return 'Error';
  return s;
}

// ---------------------------------------------------------------------------
// Toasts and calls
// ---------------------------------------------------------------------------

function toast(msg, isErr = false) {
  if (!msg) return;
  const el = document.createElement('div');
  el.className = 'toast' + (isErr ? ' err' : '');
  el.textContent = msg;
  $('toasts').appendChild(el);
  setTimeout(() => el.remove(), isErr ? 7000 : 4500);
}

async function call(cmd, args) {
  try {
    return await invoke(cmd, args);
  } catch (e) {
    toast(String(e), true);
    throw e;
  }
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

function fillSelect(sel, choices, value) {
  if (sel.options.length !== choices.length) {
    sel.innerHTML = '';
    for (const m of choices) sel.add(new Option(fmtMinutes(m), String(m)));
  }
  if (!choices.includes(value) && ![...sel.options].some(o => o.value === String(value))) {
    sel.add(new Option(fmtMinutes(value), String(value)));
  }
  if (document.activeElement !== sel) sel.value = String(value);
}

function renderStatus(s) {
  const dot = $('stateDot');
  dot.className = 'dot ' + (s.syncing ? 'syncing' : s.automatic ? 'on' : 'paused');
  $('stateText').textContent = s.automatic ? 'Automatic syncing is ON' : 'Automatic syncing is PAUSED';
  $('syncBadge').classList.toggle('hidden', !s.syncing);

  const parts = [];
  if (s.automatic && s.nextRun) parts.push(`Next run: ${fmtWhen(s.nextRun)}`);
  else if (!s.automatic) parts.push('No runs scheduled while paused');
  if (s.lastRun) parts.push(`Last: ${resultLabel(s.lastRun.Status)} at ${fmtWhen(s.lastRun.FinishedAt, false)}`);
  $('nextText').textContent = parts.join('   ·   ');

  const prog = $('progressText');
  let ptext = '';
  if (s.stopRequested) ptext = 'Stopping gracefully — waiting for monerod to flush and exit…';
  else if (s.engineRunning && s.runStartedAt) ptext = `Sync running for ${fmtElapsed(s.runStartedAt)} — follow it in the live output below.`;
  else if (s.legacyRunning) ptext = 'A sync started outside this app (e.g. the old scheduled task) is running.';
  else if (s.monerodRunning) ptext = `monerod is running outside this app (${s.monerodDetail}).`;
  prog.textContent = ptext;
  prog.classList.toggle('hidden', !ptext);

  fillSelect($('freq'), s.intervalChoices, s.intervalMinutes);
  fillSelect($('cap'), s.capChoices, s.maxSyncMinutes);
  $('freq').disabled = !s.automatic;
  $('btnPause').textContent = s.automatic ? 'Pause automatic syncing' : 'Resume automatic syncing';

  const sync = $('btnSync');
  sync.disabled = s.syncing || busy;
  sync.textContent = s.syncing ? 'Syncing…' : 'Sync now';

  const stop = $('btnStop');
  stop.textContent = s.stopRequested ? 'Stopping…' : 'Stop sync';
  $('btnTerminate').disabled = !s.monerodRunning;
  stop.disabled = !(s.syncing) || s.stopRequested;

  const label = $('logLabel');
  label.textContent = s.syncing ? 'Live output · SYNCING' : 'Live output · idle';
  label.classList.toggle('live', s.syncing);

  renderBanner(s);
  if ($('settingsDlg').open) renderSettings(s, false);
}

function renderBanner(s) {
  const b = $('banner');
  let text = '', btn = '', cls = '', action = null;
  if (!s.dataDir) {
    cls = 'err';
    text = 'Choose where your Monero blockchain is stored. Syncing stays off until you do.';
    btn = 'Choose folder…';
    action = pickDataDir;
  } else if (!s.monerodFound) {
    cls = 'err';
    text = s.monerodConfigured
      ? `monerod.exe not found at ${s.monerodConfigured}.`
      : 'monerod.exe could not be found automatically. Install the Monero CLI or GUI wallet, or point to it.';
    btn = 'Locate monerod.exe…';
    action = pickMonerod;
  } else if (!s.blockchainOk && !s.syncing) {
    text = `Blockchain not found at ${s.dataDir} — ${s.blockchainDetail}. Syncs are skipped until it's available (e.g. the drive is mounted).`;
    btn = 'Change folder…';
    action = openSettings;
  }
  b.className = 'banner' + (cls ? ' ' + cls : '') + (text ? '' : ' hidden');
  $('bannerText').textContent = text;
  const bb = $('bannerBtn');
  bb.textContent = btn;
  bb.onclick = action;
}

// ---------------------------------------------------------------------------
// History
// ---------------------------------------------------------------------------

function td(text, cls) {
  const c = document.createElement('td');
  c.textContent = text;
  if (cls) c.className = cls;
  return c;
}

async function loadHistory() {
  const entries = await invoke('get_history');
  const body = $('rows');
  body.textContent = '';
  let ok = 0, blocks = 0;

  for (const e of entries) {
    const tr = document.createElement('tr');
    const s = e.Status || '';
    const resCls = s === 'OK' ? 'r-ok' : (s.startsWith('SKIP') || s.startsWith('STOPPED-')) ? 'r-skip' : 'r-bad';
    if (resCls === 'r-bad') tr.className = 'bad';
    if (s === 'OK') ok++;
    if (e.Blocks > 0) blocks += e.Blocks;

    let clean = '', cleanCls = '';
    if (e.MarkersTotal > 0) {
      if (e.MarkersSeen >= e.MarkersTotal) { clean = 'clean'; cleanCls = 'c-clean'; }
      else if (e.MarkersSeen > 0) clean = `${e.MarkersSeen}/${e.MarkersTotal}`;
      else { clean = 'NOT CLEAN'; cleanCls = 'c-bad'; }
    }

    tr.append(
      td(fmtWhen(e.StartedAt)),
      td(resultLabel(s), resCls),
      td(e.Blocks > 0 ? `+${e.Blocks.toLocaleString()}` : (s === 'OK' ? '0' : ''), 'num'),
      td(e.EndHeight > 0 ? e.EndHeight.toLocaleString() : '', 'num'),
      td(e.Minutes > 0 ? `${e.Minutes.toFixed(1)} min` : '', 'num'),
      td(clean, 'center ' + cleanCls),
    );
    tr.title = e.Detail || '';
    body.appendChild(tr);
  }

  $('empty').classList.toggle('hidden', entries.length > 0);
  $('footer').textContent =
    `${entries.length} runs shown   |   ${ok} synced   |   ${blocks.toLocaleString()} blocks total`;
}

// ---------------------------------------------------------------------------
// Live log
// ---------------------------------------------------------------------------

const MAX_LOG_LINES = 1500;

function lineClass(line) {
  if (/^\s+\|/.test(line)) {
    if (/^\s+\|\s+\S+ \S+ E /.test(line)) return 'l-mono-err';
    if (/^\s+\|\s+\S+ \S+ W /.test(line)) return 'l-mono-warn';
    return 'l-mono';
  }
  if (/\sERROR\s/.test(line)) return 'l-err';
  if (/\sWARN\s/.test(line)) return 'l-warn';
  if (/\sOK\s/.test(line)) return 'l-ok';
  if (/\sSTEP\s/.test(line)) return 'l-step';
  return '';
}

async function loadLog() {
  const chunk = await invoke('read_log', { pos: logPos });
  const pre = $('log');
  if (chunk.reset) pre.textContent = '';
  logPos = chunk.pos;

  let text = chunk.text;
  if (chunk.reset && logPos > text.length) {
    // Started mid-file: drop the first, probably partial, line.
    const nl = text.indexOf('\n');
    text = nl >= 0 ? text.slice(nl + 1) : text;
  }
  if (!text.trim()) {
    if (!pre.textContent) pre.textContent = '  (no sync has run yet)';
    return;
  }
  if (pre.textContent === '  (no sync has run yet)') pre.textContent = '';

  const atBottom = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 8;
  const frag = document.createDocumentFragment();
  for (const raw of text.split(/\r?\n/)) {
    if (!raw.trim()) continue;
    const span = document.createElement('span');
    const cls = lineClass(raw);
    if (cls) span.className = cls;
    span.textContent = raw + '\n';
    frag.appendChild(span);
  }
  pre.appendChild(frag);
  while (pre.childElementCount > MAX_LOG_LINES) pre.firstElementChild.remove();
  if (atBottom) pre.scrollTop = pre.scrollHeight;
}

// ---------------------------------------------------------------------------
// Polling
// ---------------------------------------------------------------------------

async function refresh() {
  if (document.hidden) return;
  try {
    status = await invoke('get_status');
    renderStatus(status);

    const lr = status.lastRun;
    const key = lr ? `${lr.FinishedAt}|${lr.Status}` : 'none';
    if (key !== historyKey) {
      historyKey = key;
      await loadHistory();
    }
    await loadLog();

    if (!status.dataDir && !settingsAutoOpened) {
      settingsAutoOpened = true;
      openSettings();
    }
  } catch (e) {
    console.error(e);
  }
}

setInterval(refresh, 2000);
document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh(); });

// ---------------------------------------------------------------------------
// Settings dialog
// ---------------------------------------------------------------------------

function setStatusLine(el, text, kind) {
  el.textContent = text || '';
  el.className = 'status' + (kind ? ' ' + kind : '');
}

function renderSettings(s, full = true) {
  const dataIn = $('dataDir');
  if (full || document.activeElement !== dataIn) dataIn.value = s.dataDir;
  const monIn = $('monerodPath');
  if (full || document.activeElement !== monIn) monIn.value = s.monerodConfigured;

  if (!s.dataDir) setStatusLine($('dataStatus'), 'Not set yet.', 'err');
  else if (s.blockchainOk) setStatusLine($('dataStatus'), `✓ Found: ${s.blockchainDetail}`, 'ok');
  else setStatusLine($('dataStatus'), `Not available right now: ${s.blockchainDetail}`, 'warn');

  if (s.monerodFound) {
    setStatusLine($('monerodStatus'), s.monerodConfigured ? '✓ Found' : `✓ Found automatically: ${s.monerodPath}`, 'ok');
  } else {
    setStatusLine($('monerodStatus'), 'Not found. Browse to monerod.exe.', 'err');
  }

  $('optLogin').checked = s.startAtLogin;
  $('optBattery').checked = s.skipOnBattery;
  $('manualCmd').textContent = s.manualCommand;
  $('lnkData').textContent = s.appDataDir;
}

function openSettings() {
  if (status) renderSettings(status, true);
  if (!$('settingsDlg').open) $('settingsDlg').showModal();
}

async function afterDataDir(res) {
  if (!res) return;
  toast(res.warning ? res.warning : `Blockchain folder set to ${res.dataDir}`, !!res.warning);
  await refresh();
  if ($('settingsDlg').open && status) renderSettings(status, true);
}

async function pickDataDir() {
  try { await afterDataDir(await call('pick_data_dir')); } catch { }
}

async function pickMonerod() {
  try {
    const p = await call('pick_monerod');
    if (p != null) toast('monerod.exe location saved.');
    await refresh();
    if ($('settingsDlg').open && status) renderSettings(status, true);
  } catch { }
}

$('btnSettings').onclick = openSettings;
$('btnPickData').onclick = pickDataDir;
$('btnPickMonerod').onclick = pickMonerod;

$('dataDir').addEventListener('change', async (ev) => {
  const v = ev.target.value.trim();
  if (status && v === status.dataDir) return;
  try { await afterDataDir(await call('set_data_dir', { path: v })); }
  catch { if (status) ev.target.value = status.dataDir; }
});

$('monerodPath').addEventListener('change', async (ev) => {
  try {
    await call('set_monerod_path', { path: ev.target.value });
    toast(ev.target.value.trim() ? 'monerod.exe location saved.' : 'monerod.exe will be found automatically.');
    await refresh();
  } catch { if (status) ev.target.value = status.monerodConfigured; }
});

for (const [id, key] of [['optLogin', 'startAtLogin'], ['optBattery', 'skipOnBattery']]) {
  $(id).addEventListener('change', async (ev) => {
    try { await call('set_option', { key, value: ev.target.checked }); await refresh(); }
    catch { ev.target.checked = !ev.target.checked; }
  });
}

$('btnCopy').onclick = async () => {
  const btn = $('btnCopy');
  try {
    await navigator.clipboard.writeText($('manualCmd').textContent);
    btn.textContent = 'Copied';
  } catch {
    btn.textContent = 'Failed';
  }
  setTimeout(() => { btn.textContent = 'Copy'; }, 2000);
};

$('lnkData').onclick = (ev) => { ev.preventDefault(); invoke('open_folder', { which: 'data' }); };

// ---------------------------------------------------------------------------
// Checks dialog
// ---------------------------------------------------------------------------

async function showChecks() {
  const dlg = $('checksDlg');
  const list = $('checkList');
  list.innerHTML = '<li><span></span><span class="detail">Checking…</span></li>';
  if (!dlg.open) dlg.showModal();

  let c;
  try { c = await call('run_checks'); }
  catch (e) { list.innerHTML = ''; const li = document.createElement('li'); li.textContent = String(e); list.appendChild(li); return; }
  const rows = [
    [c.blockchainOk, 'Blockchain', c.blockchainOk ? 'found' : 'NOT FOUND', c.blockchainDetail],
    [!c.vmRunning, 'VirtualBox', c.vmRunning ? 'VM RUNNING' : 'no VM', c.vmDetail],
    [!c.monerodRunning, 'monerod', c.monerodRunning ? 'RUNNING' : 'not running', c.monerodDetail],
    [c.binaryOk, 'monerod.exe', c.binaryOk ? 'found' : 'NOT FOUND', c.binaryDetail],
    [null, 'Power', c.onBattery ? 'on battery' : 'plugged in', c.onBattery && c.skipOnBattery ? 'scheduled runs are skipped on battery' : ''],
    [null, 'Schedule', c.schedule, ''],
    [null, 'Last run', c.lastRun, ''],
  ];
  list.textContent = '';
  for (const [ok, what, state, detail] of rows) {
    const li = document.createElement('li');
    const mark = document.createElement('span');
    mark.className = 'mark ' + (ok === null ? 'na' : ok ? 'ok' : 'bad');
    mark.textContent = ok === null ? '·' : ok ? '✓' : '✗';
    const w = document.createElement('span');
    w.className = 'what';
    w.textContent = what;
    const d = document.createElement('span');
    d.className = 'detail';
    d.textContent = detail ? `${state} — ${detail}` : state;
    li.append(mark, w, d);
    list.appendChild(li);
  }
  const v = $('checkVerdict');
  v.textContent = c.clear ? 'Clear to sync.' : 'A sync started now would be skipped.';
  v.className = 'verdict ' + (c.clear ? 'ok' : 'bad');
}

$('btnRecheck').onclick = showChecks;
listen('show-checks', () => showChecks());

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

$('btnSync').onclick = async () => {
  busy = true;
  $('btnSync').disabled = true;
  try {
    await call('sync_now');
    toast('Sync started.');
  } catch { }
  busy = false;
  refresh();
};

$('btnPause').onclick = async () => {
  if (!status) return;
  const on = !status.automatic;
  try {
    await call('set_automatic', { on });
    toast(on ? `Automatic syncing resumed (every ${fmtMinutes(status.intervalMinutes)}).`
             : 'Automatic syncing paused. A sync already running is not affected.');
  } catch { }
  refresh();
};

$('freq').onchange = async (ev) => {
  const minutes = Number(ev.target.value);
  try { await call('set_interval', { minutes }); toast(`Now syncing every ${fmtMinutes(minutes)}.`); } catch { }
  refresh();
};

$('cap').onchange = async (ev) => {
  const minutes = Number(ev.target.value);
  try { await call('set_sync_cap', { minutes }); toast(`A sync now gives up after ${fmtMinutes(minutes)}.`); } catch { }
  refresh();
};

$('btnStop').onclick = async () => {
  try { toast(await call('stop_sync')); } catch { }
  refresh();
};

$('btnTerminate').onclick = async () => {
  try { const m = await call('terminate_sync'); if (m) toast(m, true); } catch { }
  refresh();
};

$('btnClearOut').onclick = async () => {
  try { await call('clear_output'); $('log').textContent = ''; logPos = 0; } catch { }
};

$('btnClearHist').onclick = async () => {
  try { if (await call('clear_history')) { historyKey = null; refresh(); } } catch { }
};

$('btnOpenLog').onclick = () => invoke('open_folder', { which: 'logfile' });

// ---------------------------------------------------------------------------
// Resizable log pane
// ---------------------------------------------------------------------------

(function divider() {
  const split = $('split');
  const bar = $('divider');
  try {
    const saved = Number(localStorage.getItem('logHeight'));
    if (saved > 0) split.style.setProperty('--log-h', `${saved}px`);
  } catch { }

  bar.addEventListener('pointerdown', (ev) => {
    bar.setPointerCapture(ev.pointerId);
    bar.classList.add('dragging');
    const rect = split.getBoundingClientRect();
    const move = (e) => {
      const h = Math.min(Math.max(rect.bottom - e.clientY - 4, 80), rect.height - 120);
      split.style.setProperty('--log-h', `${Math.round(h)}px`);
    };
    const up = () => {
      bar.classList.remove('dragging');
      bar.removeEventListener('pointermove', move);
      bar.removeEventListener('pointerup', up);
      try { localStorage.setItem('logHeight', parseInt(split.style.getPropertyValue('--log-h'), 10)); } catch { }
    };
    bar.addEventListener('pointermove', move);
    bar.addEventListener('pointerup', up);
  });
})();

refresh();
