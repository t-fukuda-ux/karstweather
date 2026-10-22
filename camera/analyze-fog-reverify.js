// 霧予報の再検証（2026-10-22）: 保存予報（camera/fog_forecast.csv）× カメラの v1 自動ラベル（camera/mezuru_contrast.csv）。
// 使い方: node camera/analyze-fog-reverify.js
// 正解: 局所コントラストに fog-criteria-v1.json を当てたラベル。霧 = D + B。v1 と盲検目視（visual-review-20260923.json）の一致も最初に出す。
// 対応: カメラ HH:50 → 予報 HH+1:00。発表: 前夜 = 前日 18:25、当日朝 = 当日 06:25、前日朝 = 前日 06:25（いずれも発表より後の対象時刻だけ）。
// 区間は日単位ブートストラップの90%区間。読み取り専用。結果の読み方と注意は camera/fog-verification-20261022.md を参照。
const fs = require('fs'), path = require('path');
const D = __dirname;
const strip = s => s.replace(/^﻿/, '');

function parseCsv(text) {
  const rows = []; let row = [], cur = '', q = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (q) { if (ch === '"') { if (text[i + 1] === '"') { cur += '"'; i++; } else q = false; } else cur += ch; }
    else if (ch === '"') q = true;
    else if (ch === ',') { row.push(cur); cur = ''; }
    else if (ch === '\n' || ch === '\r') { if (ch === '\r' && text[i + 1] === '\n') i++; row.push(cur); rows.push(row); row = []; cur = ''; }
    else cur += ch;
  }
  if (cur !== '' || row.length) { row.push(cur); rows.push(row); }
  const hdr = rows[0];
  return rows.slice(1).filter(r => r.length > 1).map(r => Object.fromEntries(hdr.map((k, i) => [k, r[i] === undefined || r[i] === '' ? null : r[i]])));
}
const num = v => v === null || v === undefined || v === '' ? null : +v;
const crit = JSON.parse(strip(fs.readFileSync(path.join(D, 'fog-criteria-v1.json'), 'utf8')));
const cam = parseCsv(strip(fs.readFileSync(path.join(D, 'mezuru_contrast.csv'), 'utf8')));
const fcRaw = parseCsv(strip(fs.readFileSync(path.join(D, 'fog_forecast.csv'), 'utf8')));
const visual = JSON.parse(strip(fs.readFileSync(path.join(D, 'visual-review-20260923.json'), 'utf8'))).observations;

const addH = (s, h) => { const d = new Date(s.replace(' ', 'T') + ':00Z'); d.setUTCHours(d.getUTCHours() + h); return d.toISOString().slice(0, 16).replace('T', ' '); };
const addD = (day, n) => { const d = new Date(day + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const pct = (a, b) => b ? Math.round(100 * a / b) + '%' : '-';
const f2 = x => x === null || x === undefined || Number.isNaN(x) ? '-' : x.toFixed(2);

// ---- 1. カメラ v1 ラベル ----
function v1(r) {
  if (r.dark !== '0') return null;
  const mean = num(r.mean_all), near = num(r.near_lc), far = num(r.far_lc);
  if (mean === null || near === null || far === null || mean < crit.dark_min) return null;
  if ((r.note || '').includes('size_changed')) return null;
  if (near < crit.near_dense_max && far < crit.far_hidden_max) return 'D';
  if (far < crit.far_hidden_max) return 'B';
  if (far < crit.far_clear_min) return 'H';
  return 'C';
}
const obs = cam.map(r => ({ time: r.captured_at_jst, code: v1(r), far: num(r.far_lc), near: num(r.near_lc) }))
  .filter(o => o.code && o.time >= '2026-09-12');
const isFog = c => c === 'D' || c === 'B' ? 1 : 0;

console.log('# 1. v1自動ラベルと盲検目視(9/12-9/23)の一致');
{
  const byTime = Object.fromEntries(obs.map(o => [o.time, o]));
  let n = 0, agreeBin = 0, agree4 = 0; const conf = {};
  const miss = [];
  for (const v of visual) {
    if (!['D', 'B', 'H', 'C'].includes(v.visual)) continue;
    const o = byTime[v.time]; if (!o) { miss.push(v.time); continue; }
    n++; if (isFog(o.code) === isFog(v.visual)) agreeBin++; if (o.code === v.visual) agree4++;
    const k = `目視${v.visual}→v1${o.code}`; conf[k] = (conf[k] || 0) + 1;
  }
  console.log(`照合 ${n}枚（v1判定対象外 ${miss.length}枚: ${miss.join(', ')}）  霧/霧なし一致 ${agreeBin}/${n}=${pct(agreeBin, n)}  4区分一致 ${pct(agree4, n)}`);
  console.log(Object.entries(conf).sort().map(([k, v]) => `${k}:${v}`).join('  '));
  const fogV = visual.filter(v => isFog(v.visual) && byTime[v.time]);
  const clearV = visual.filter(v => ['H', 'C'].includes(v.visual) && byTime[v.time]);
  console.log(`目視霧→v1霧 ${fogV.filter(v => isFog(byTime[v.time].code)).length}/${fogV.length}  目視霧なし→v1霧なし ${clearV.filter(v => !isFog(byTime[v.time].code)).length}/${clearV.length}`);
}

// ---- 2. 予報との突き合わせ ----
const fc = fcRaw.map(r => ({ issued: r.issued_at, target: r.target_time, lead: num(r.lead_h),
  cl_bm: num(r.cl_bm), cl_ec: num(r.cl_ec), cl_avg: num(r.cl_avg), rh2m_bm: num(r.rh2m_bm), rh2m_ec: num(r.rh2m_ec),
  rh_above_bm: num(r.rh_above_bm), rh_above_ec: num(r.rh_above_ec), v_bm: num(r.v_bm), v_ec: num(r.v_ec),
  wind_bm: num(r.wind_bm), vis_bm: num(r.vis_bm), precip_bm: num(r.precip_bm), precip_ec: num(r.precip_ec) }));
const fcIdx = {}; for (const f of fc) fcIdx[f.issued.slice(0, 16) + '|' + f.target] = f;
const COHORTS = {
  evening: { label: '前夜18:25発表(リード約12-24h)', issue: day => addD(day, -1) + ' 18:25' },
  morning: { label: '当日06:25発表(リード約0-12h)', issue: day => day + ' 06:25' },
  prevmorning: { label: '前日06:25発表(リード約24-36h)', issue: day => addD(day, -1) + ' 06:25' },
};
function join(cohort, from = '0000', to = '9999') {
  const out = [];
  for (const o of obs) {
    const target = addH(o.time.slice(0, 13) + ':00', 1), day = target.slice(0, 10);
    if (day < from || day > to) continue;
    const issued = COHORTS[cohort].issue(day);
    if (target <= issued) continue;
    const f = fcIdx[issued + '|' + target];
    if (f) out.push({ ...o, target, day, hour: +target.slice(11, 13), fog: isFog(o.code), f });
  }
  return out;
}

function aucRows(rows, key, hi, sameDay = false) {
  const r = rows.filter(x => x.f[key] !== null).map(x => ({ s: (hi ? 1 : -1) * x.f[key], y: x.fog, d: x.day }));
  let s = 0, n = 0;
  for (const p of r) if (p.y) for (const q of r) if (!q.y && (!sameDay || p.d === q.d)) { s += p.s > q.s ? 1 : p.s === q.s ? 0.5 : 0; n++; }
  return n ? s / n : null;
}
function boot(rows, fn, B = 1000) {
  const days = [...new Set(rows.map(r => r.day))], by = {}; rows.forEach(r => (by[r.day] = by[r.day] || []).push(r));
  let seed = 12345; const rnd = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648;
  const v = []; for (let b = 0; b < B; b++) { const s = []; for (let i = 0; i < days.length; i++) s.push(...by[days[Math.floor(rnd() * days.length)]]); const a = fn(s); if (a !== null && !Number.isNaN(a)) v.push(a); }
  v.sort((a, b) => a - b); return [v[Math.floor(v.length * 0.05)], v[Math.floor(v.length * 0.95)]];
}
function conf(rows, pred) {
  let tp = 0, fp = 0, fn = 0, tn = 0;
  for (const r of rows) { const p = pred(r); if (p === null) continue; if (p && r.fog) tp++; else if (p) fp++; else if (r.fog) fn++; else tn++; }
  const n = tp + fp + fn + tn;
  return { n, tp, fp, fn, tn, acc: n ? (tp + tn) / n : null, sens: tp + fn ? tp / (tp + fn) : null, spec: tn + fp ? tn / (tn + fp) : null };
}
const VARS = [['cl_ec', true], ['cl_avg', true], ['cl_bm', true], ['v_ec', false], ['v_bm', false], ['rh2m_ec', true], ['rh2m_bm', true],
  ['rh_above_ec', true], ['rh_above_bm', true], ['vis_bm', false], ['wind_bm', false]];
const RULES = [
  ['EC低層雲≥30%', r => r.f.cl_ec === null ? null : r.f.cl_ec >= 30],
  ['EC低層雲≥40%', r => r.f.cl_ec === null ? null : r.f.cl_ec >= 40],
  ['EC低層雲≥50%', r => r.f.cl_ec === null ? null : r.f.cl_ec >= 50],
  ['平均版≥30%', r => r.f.cl_avg === null ? null : r.f.cl_avg >= 30],
  ['平均版≥45%', r => r.f.cl_avg === null ? null : r.f.cl_avg >= 45],
  ['平均版≥60%', r => r.f.cl_avg === null ? null : r.f.cl_avg >= 60],
  ['規定版≥30%', r => r.f.cl_bm === null ? null : r.f.cl_bm >= 30],
  ['V_summit(EC)≤0.5', r => r.f.v_ec === null ? null : r.f.v_ec <= 0.5],
  ['常に霧', r => true],
  ['常に霧なし', r => false],
];

const PERIODS = [['全期間 9/12-10/22', '2026-09-12', '2026-10-22'], ['前回検証期間 9/12-9/23', '2026-09-12', '2026-09-23'], ['新規期間 9/24-10/22', '2026-09-24', '2026-10-22']];

for (const [pl, from, to] of PERIODS) {
  console.log(`\n\n######## ${pl}`);
  for (const ck of Object.keys(COHORTS)) {
    const rows = join(ck, from, to);
    const nf = rows.filter(r => r.fog).length, days = new Set(rows.map(r => r.day)).size;
    console.log(`\n## ${COHORTS[ck].label}: ${rows.length}時刻（霧${nf}=${pct(nf, rows.length)}）・${days}日`);
    console.log('変数         AUC [90%日単位BS]  同日内AUC');
    for (const [k, hi] of VARS) {
      const [lo, up] = boot(rows, s => aucRows(s, k, hi), 600);
      console.log(`${k.padEnd(12)} ${f2(aucRows(rows, k, hi))} [${f2(lo)}-${f2(up)}]  ${f2(aucRows(rows, k, hi, true))}`);
    }
    const [dlo, dup] = boot(rows, s => { const a = aucRows(s, 'cl_ec', true), b = aucRows(s, 'cl_avg', true); return a === null || b === null ? null : a - b; }, 600);
    console.log(`AUC差 cl_ec − cl_avg = ${f2(aucRows(rows, 'cl_ec', true) - aucRows(rows, 'cl_avg', true))} [${f2(dlo)}-${f2(dup)}]`);
    console.log('規則              正解率 [90%BS]   捕捉        空振り(霧なし中)  ');
    for (const [name, pred] of RULES) {
      const c = conf(rows, pred); const [lo, up] = boot(rows, s => conf(s, pred).acc, 600);
      console.log(`${name.padEnd(16)} ${pct(c.tp + c.tn, c.n).padStart(4)} [${pct(lo * 100, 100)}-${pct(up * 100, 100)}]  ${c.tp}/${c.tp + c.fn}  ${c.fp}/${c.fp + c.tn}`);
    }
    // 持続（当日朝のみ）: 06:25時点で最新の昼間観測をその日の予報とする
    if (ck === 'morning') {
      const pers = r => { const o = obs.filter(x => x.time.slice(0, 10) === r.day && x.time <= r.day + ' 06:25').pop(); return o ? !!isFog(o.code) : null; };
      const c = conf(rows, pers);
      console.log(`持続(06:25時点の最新カメラ)  ${pct(c.tp + c.tn, c.n)}  対象${c.n}/${rows.length}時刻  捕捉${c.tp}/${c.tp + c.fn} 空振り${c.fp}/${c.fp + c.tn}`);
    }
    if (pl.startsWith('全期間')) {
      console.log('低層雲10%刻みの霧の割合');
      for (const k of ['cl_ec', 'cl_avg', 'cl_bm']) {
        const cells = [];
        for (const [a, b] of [[0, 10], [10, 20], [20, 30], [30, 40], [40, 50], [50, 60], [60, 80], [80, 101]]) {
          const s = rows.filter(r => r.f[k] !== null && r.f[k] >= a && r.f[k] < b), n = s.filter(r => r.fog).length;
          cells.push(`${a}-${b === 101 ? '' : b}:${pct(n, s.length)}(${n}/${s.length})`);
        }
        console.log(`${k.padEnd(7)} ${cells.join(' ')}`);
      }
    }
  }
}

// ---- 3. 時間帯別(表示の4区分)の時刻単位AUC ----
const WIN = [['早朝5-8', 5, 8], ['午前9-11', 9, 11], ['昼12-15', 12, 15], ['夕16-20', 16, 20]];
console.log('\n\n# 3. 表示区分ごとの時刻単位（前夜発表・全期間）');
{
  const rows = join('evening');
  for (const [w, a, b] of WIN) {
    const s = rows.filter(r => r.hour >= a && r.hour <= b), nf = s.filter(r => r.fog).length;
    const ec = conf(s, RULES[0][1]), av = conf(s, RULES[3][1]);
    console.log(`${w}: ${s.length}時刻 霧${pct(nf, s.length)}  AUC ec ${f2(aucRows(s, 'cl_ec', true))} avg ${f2(aucRows(s, 'cl_avg', true))} bm ${f2(aucRows(s, 'cl_bm', true))}  正解率 EC30 ${pct(ec.tp + ec.tn, ec.n)} avg30 ${pct(av.tp + av.tn, av.n)}`);
  }
}

// ---- 4. 時間帯（表示単位）での評価 ----
console.log('\n\n# 4. 時間帯単位: 予報の時間帯平均 → 実測の霧の割合');
function windows(cohort, from = '0000', to = '9999') {
  const rows = join(cohort, from, to), out = [];
  const days = [...new Set(rows.map(r => r.day))];
  for (const day of days) for (const [w, a, b] of WIN) {
    const o = rows.filter(r => r.day === day && r.hour >= a && r.hour <= b);
    if (o.length < 2) continue;
    const issued = COHORTS[cohort].issue(day);
    const fh = []; for (let h = a; h <= b; h++) { const t = `${day} ${String(h).padStart(2, '0')}:00`; if (t > issued && fcIdx[issued + '|' + t]) fh.push(fcIdx[issued + '|' + t]); }
    if (!fh.length) continue;
    const mean = k => { const v = fh.map(f => f[k]).filter(x => x !== null); return v.length ? v.reduce((p, c) => p + c, 0) / v.length : null; };
    const rainMax = Math.max(...fh.map(f => f.precip_ec === null ? (f.precip_bm ?? 0) : ((f.precip_bm ?? 0) + f.precip_ec) / 2));
    const vMin = Math.min(...fh.map(f => f.v_ec ?? 1));
    const ff = o.filter(r => r.fog).length / o.length;
    out.push({ day, w, n: o.length, ff, codes: o.map(r => r.code).join(''), avg: mean('cl_avg'), ec: mean('cl_ec'), bm: mean('cl_bm'), rainMax, vMin });
  }
  return out;
}
const tier = x => x === null ? null : x >= 60 ? '●60+' : x >= 30 ? '◐30-60' : '○<30';
function tierTable(ws, key, title) {
  console.log(`\n${title}`);
  for (const t of ['○<30', '◐30-60', '●60+']) {
    const s = ws.filter(x => tier(x[key]) === t); if (!s.length) { console.log(`${t}: 0`); continue; }
    const mf = s.reduce((p, c) => p + c.ff, 0) / s.length;
    console.log(`${t.padEnd(7)} ${String(s.length).padStart(3)}区間  霧の時刻割合平均 ${pct(mf * 100, 100).padStart(4)}  霧ゼロ ${pct(s.filter(x => x.ff === 0).length, s.length).padStart(4)}  半分以上霧 ${pct(s.filter(x => x.ff >= 0.5).length, s.length).padStart(4)}  全部霧 ${pct(s.filter(x => x.ff === 1).length, s.length)}`);
  }
  const auc = (() => { let s = 0, n = 0; for (const p of ws) if (p.ff >= 0.5) for (const q of ws) if (q.ff < 0.5) { s += p[key] > q[key] ? 1 : p[key] === q[key] ? 0.5 : 0; n++; } return n ? s / n : null; })();
  // 3段階の当たり: ○→霧ゼロ, ●→半分以上霧 を当たり、◐は保留扱い
  console.log(`  「半分以上霧」のAUC(時間帯平均) ${f2(auc)}`);
}
for (const [pl, from, to] of PERIODS) {
  for (const ck of ['evening', 'morning']) {
    const ws = windows(ck, from, to);
    console.log(`\n## ${pl} / ${COHORTS[ck].label}: ${ws.length}区間`);
    tierTable(ws, 'avg', '平均版（現行の表示）');
    tierTable(ws, 'ec', 'EC版で同じ区切り');
    tierTable(ws, 'bm', '規定版で同じ区切り');
    if (ck === 'evening' && pl.startsWith('全期間')) {
      const mid = ws.filter(x => tier(x.avg) === '◐30-60');
      const rain = mid.filter(x => x.rainMax >= 1), dry = mid.filter(x => x.rainMax < 1);
      const m = s => s.length ? pct(100 * s.reduce((p, c) => p + c.ff, 0) / s.length, 100) : '-';
      console.log(`\n◐の雨上げ: 雨1mm以上 ${rain.length}区間 霧割合 ${m(rain)} 半分以上霧 ${pct(rain.filter(x => x.ff >= .5).length, rain.length)} / 雨なし ${dry.length}区間 霧割合 ${m(dry)} 半分以上霧 ${pct(dry.filter(x => x.ff >= .5).length, dry.length)}`);
      const lo = ws.filter(x => tier(x.avg) === '○<30');
      for (const [w] of WIN) {
        const s = lo.filter(x => x.w === w), a = s.filter(x => x.vMin <= 0.5), b = s.filter(x => x.vMin > 0.5);
        console.log(`○の${w}: V≤0.5あり ${a.length}区間 霧あり ${a.filter(x => x.ff > 0).length} / なし ${b.length}区間 霧あり ${b.filter(x => x.ff > 0).length}`);
      }
      // 平均版とEC版で段階が食い違う区間
      console.log('\n平均版とEC版で段階が食い違う区間（前夜発表）');
      const diff = ws.filter(x => tier(x.avg) !== tier(x.ec));
      let ecBetter = 0, avgBetter = 0;
      const score = (t, ff) => t === '○<30' ? (ff === 0 ? 1 : 0) : t === '●60+' ? (ff >= 0.5 ? 1 : 0) : (ff > 0 && ff < 1 ? 1 : 0.5);
      for (const x of diff) { const se = score(tier(x.ec), x.ff), sa = score(tier(x.avg), x.ff); if (se > sa) ecBetter++; else if (sa > se) avgBetter++; }
      console.log(`食い違い ${diff.length}/${ws.length}区間  EC寄りが良い ${ecBetter}  平均版が良い ${avgBetter}`);
      const tr = {}; for (const x of diff) { const k = `平均${tier(x.avg)}→EC${tier(x.ec)}`; (tr[k] = tr[k] || []).push(x); }
      for (const [k, s] of Object.entries(tr)) console.log(`  ${k}: ${s.length}区間 霧ゼロ${s.filter(x => x.ff === 0).length} 半分以上霧${s.filter(x => x.ff >= .5).length}  例 ${s.slice(0, 4).map(x => `${x.day.slice(5)}${x.w.slice(0, 2)}(${x.codes} avg${Math.round(x.avg)} ec${Math.round(x.ec)})`).join(' ')}`);
    }
  }
}

// ---- 5. 日単位 ----
console.log('\n\n# 5. 日単位（前夜発表、対象6-18時）');
{
  const rows = join('evening'); const days = [...new Set(rows.map(r => r.day))];
  const dd = days.map(day => { const s = rows.filter(r => r.day === day); const m = k => s.reduce((p, c) => p + (c.f[k] ?? 0), 0) / s.length; return { day, n: s.length, ff: s.filter(r => r.fog).length / s.length, avg: m('cl_avg'), ec: m('cl_ec'), bm: m('cl_bm'), codes: s.map(r => r.code).join('') }; });
  for (const d of dd) console.log(`${d.day.slice(5)} 霧${pct(d.ff * 100, 100).padStart(4)} avg${String(Math.round(d.avg)).padStart(3)} ec${String(Math.round(d.ec)).padStart(3)} bm${String(Math.round(d.bm)).padStart(3)}  ${d.codes}`);
  for (const k of ['avg', 'ec', 'bm']) {
    let s = 0, n = 0; for (const p of dd) if (p.ff >= 0.5) for (const q of dd) if (q.ff < 0.5) { s += p[k] > q[k] ? 1 : p[k] === q[k] ? .5 : 0; n++; }
    const fogDays = dd.filter(x => x.ff >= 0.5);
    console.log(`日AUC(霧が半分以上の日) ${k}: ${f2(s / n)}  霧日${fogDays.length}/${dd.length}`);
    for (const th of [30, 40, 50]) { const c = dd.filter(x => (x[k] >= th) === (x.ff >= 0.5)).length; console.log(`   ${k}日平均≥${th}%を霧の日: 正解 ${c}/${dd.length}`); }
  }
}

// ---- 6. below_wet ----
console.log('\n\n# 6. below_wet（下側のみ RH≥90%）の時刻の霧（全コホート別）');
for (const ck of ['evening', 'morning']) {
  const rows = join(ck);
  for (const m of ['ec', 'bm']) {
    const st = r => { const lo = r.f['rh2m_' + m], hi = r.f['rh_above_' + m]; if (lo === null || hi === null) return null; return lo >= 90 && hi >= 90 ? 'in_layer' : hi >= 90 ? 'above_wet' : lo >= 90 ? 'below_wet' : 'dry'; };
    const out = [];
    for (const s of ['in_layer', 'above_wet', 'below_wet', 'dry']) { const x = rows.filter(r => st(r) === s); out.push(`${s} ${pct(x.filter(r => r.fog).length, x.length)}(${x.filter(r => r.fog).length}/${x.length})`); }
    console.log(`${COHORTS[ck].label} ${m}: ${out.join('  ')}`);
    const bw = rows.filter(r => st(r) === 'below_wet');
    for (const [a, b] of [[90, 94], [94, 97], [97, 101]]) { const x = bw.filter(r => r.f['rh2m_' + m] >= a && r.f['rh2m_' + m] < b); console.log(`   below_wet 地上RH ${a}-${b === 101 ? 100 : b - 1}: 霧 ${pct(x.filter(r => r.fog).length, x.length)}(${x.filter(r => r.fog).length}/${x.length}) 日数${new Set(x.map(r => r.day)).size}`); }
    if (ck === 'evening' && m === 'ec') {
      const x = bw.filter(r => r.f.rh2m_ec >= 97);
      const byDay = {}; x.forEach(r => (byDay[r.day] = byDay[r.day] || []).push(r));
      for (const [d, s] of Object.entries(byDay)) console.log(`     ${d} ${s.map(r => `${r.hour}時${r.code}(RH${r.f.rh2m_ec}/${r.f.rh_above_ec} cl${r.f.cl_ec})`).join(' ')}`);
    }
  }
}
