// 霧予報（camera/fog_forecast.csv）× カメラ画像の目視判定（camera/visual-review-*.json）の突き合わせ。
// 使い方: node camera/analyze-fog-visual.js [visual-review-20260923.json]
//   既定では visual-review-20260923.json（v1 基準固定後の盲検目視）を使う。
// 対応: カメラ HH:50 の画像 → 予報の HH+1:00。霧 = D（濃霧）+ B（奥が見えない）、霧なし = H + C、U は除外。
// 発表: 前夜 = 前日 18:25、当日朝 = 当日 06:25（06:25 より後の対象時刻だけ）。
// 結果の読み方と注意は camera/fog-verification-20260923.md を参照。
const fs = require('fs'), path = require('path');
const DIR = __dirname;
const reviewFile = path.join(DIR, process.argv[2] || 'visual-review-20260923.json');
const vis = JSON.parse(fs.readFileSync(reviewFile, 'utf8').replace(/^﻿/, '')).observations
  .map(o => ({ time: o.time, visual: o.visual })).sort((a, b) => a.time < b.time ? -1 : 1);

const lines = fs.readFileSync(path.join(DIR, 'fog_forecast.csv'), 'utf8').replace(/^﻿/, '').trim().split(/\r?\n/);
const hdr = lines[0].split(',');
const fc = lines.slice(1).map(l => { const c = l.split(','); const o = {}; hdr.forEach((k, i) => o[k] = c[i] === undefined || c[i] === '' ? null : c[i]); return o; });

const addH = (s, h) => { const d = new Date(s.replace(' ', 'T') + ':00Z'); d.setUTCHours(d.getUTCHours() + h); return d.toISOString().slice(0, 16).replace('T', ' '); };
const prevDay = s => { const d = new Date(s + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() - 1); return d.toISOString().slice(0, 10); };

// [列名, 値が大きいほど霧か]
const VARS = [['cl_avg', true], ['cl_ec', true], ['cl_bm', true], ['v_ec', false], ['v_bm', false],
  ['rh2m_ec', true], ['rh2m_bm', true], ['rh_above_ec', true], ['rh_above_bm', true], ['vis_bm', false], ['wind_bm', false]];
const COHORTS = { evening: '前夜18:25発表', morning: '当日06:25発表' };

function pairs(cohort) {
  const out = [];
  for (const o of vis) {
    if (!['D', 'B', 'H', 'C'].includes(o.visual)) continue;
    const target = addH(o.time.slice(0, 13) + ':00', 1);
    const day = target.slice(0, 10);
    const issued = cohort === 'evening' ? prevDay(day) + ' 18:25' : day + ' 06:25';
    if (cohort === 'morning' && target <= issued) continue;
    const f = fc.find(r => r.issued_at && r.issued_at.startsWith(issued) && r.target_time === target);
    if (f) out.push({ day, visual: o.visual, fog: o.visual === 'D' || o.visual === 'B' ? 1 : 0, f });
  }
  return out;
}
function aucOf(pairsList) { let s = 0, n = 0; for (const [a, b] of pairsList) { s += a > b ? 1 : a === b ? 0.5 : 0; n++; } return n ? s / n : null; }
function auc(rows, k, hi, sameDayOnly = false) {
  const r = rows.filter(x => x.f[k] !== null).map(x => ({ s: (hi ? 1 : -1) * +x.f[k], y: x.fog, d: x.day }));
  const pl = []; for (const p of r) if (p.y) for (const q of r) if (!q.y && (!sameDayOnly || p.d === q.d)) pl.push([p.s, q.s]);
  return aucOf(pl);
}
function bootCI(rows, k, hi, B = 2000) {
  const days = [...new Set(rows.map(r => r.day))], byDay = {}; rows.forEach(r => (byDay[r.day] = byDay[r.day] || []).push(r));
  let seed = 12345; const rnd = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648;
  const v = []; for (let b = 0; b < B; b++) { const s = []; for (let i = 0; i < days.length; i++) s.push(...byDay[days[Math.floor(rnd() * days.length)]]); const a = auc(s, k, hi); if (a !== null) v.push(a); }
  v.sort((a, b) => a - b); return [v[Math.floor(v.length * 0.05)], v[Math.floor(v.length * 0.95)]];
}
const f2 = x => x === null ? '-' : x.toFixed(2);

for (const [cohort, label] of Object.entries(COHORTS)) {
  const rows = pairs(cohort);
  console.log(`\n## ${label}  ${rows.length}時刻（霧${rows.filter(r => r.fog).length}）・${new Set(rows.map(r => r.day)).size}日`);
  console.log('変数        AUC  [90%区間・日単位ブートストラップ]  同じ日の中だけのAUC');
  for (const [k, hi] of VARS) { const [lo, up] = bootCI(rows, k, hi); console.log(`${k.padEnd(12)}${f2(auc(rows, k, hi))} [${f2(lo)}-${f2(up)}]  ${f2(auc(rows, k, hi, true))}`); }
  console.log('\n低層雲の10%刻みごとの霧の割合');
  for (const k of ['cl_avg', 'cl_ec', 'cl_bm']) {
    const cells = [];
    for (const [a, b] of [[0, 10], [10, 20], [20, 30], [30, 40], [40, 50], [50, 60], [60, 101]]) {
      const s = rows.filter(r => r.f[k] !== null && +r.f[k] >= a && +r.f[k] < b), n = s.filter(r => r.fog).length;
      cells.push(`${a}-${b === 101 ? '' : b}%: ${s.length ? Math.round(100 * n / s.length) + '%' : '-'}(${n}/${s.length})`);
    }
    console.log(`${k.padEnd(7)} ${cells.join('  ')}`);
  }
}
