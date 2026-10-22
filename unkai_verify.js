// 雲海指数の検証（2026-10-22）: forecast-history × unkai_log.csv（谷）× カメラの v1 自動ラベル（展望）。
// 使い方: node unkai_verify.js
// 発表: eve = 前日18時台、h23 = 前日23時台、h04 = 当日04時台（同じ時間帯に複数あれば issued_at が最も早いもの）。
// 谷: 朝・放射冷却型の記録だけ。方向の値は谷2地点 × 朝4時刻の最大（週間カードと同じ集約）。経験則は履歴の simple 列。
// 展望: カメラ HH:50 → 予報 HH+1:00。霧 = D + B。読み取り専用。結果の読み方と注意は unkai-verification-20261022.md を参照。
const fs = require('fs'), path = require('path');
const ROOT = __dirname;
const strip = s => s.replace(/^﻿/, '');
function parseLine(line) { const out = []; let cur = '', q = false; for (let i = 0; i < line.length; i++) { const ch = line[i]; if (q) { if (ch === '"') { if (line[i + 1] === '"') { cur += '"'; i++; } else q = false; } else cur += ch; } else if (ch === '"') q = true; else if (ch === ',') { out.push(cur); cur = ''; } else cur += ch; } out.push(cur); return out; }
function parseCsv(text) { const lines = strip(text).split(/\r?\n/).filter(l => l && !l.startsWith('#')); const h = parseLine(lines[0]); return lines.slice(1).map(l => { const c = parseLine(l); return Object.fromEntries(h.map((k, i) => [k, c[i] === undefined || c[i] === '' ? null : c[i]])); }); }
const num = v => v === null || v === undefined || v === '' ? null : +v;
const pct = (a, b) => b ? Math.round(100 * a / b) + '%' : '-';
const f2 = x => x === null || x === undefined || Number.isNaN(x) ? '-' : x.toFixed(2);
const addD = (day, n) => { const d = new Date(day + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };

// ---- 予報履歴 ----
const FH = path.join(ROOT, 'forecast-history');
const fcs = []; // {folder, cohort, model, issued, rows}
for (const day of fs.readdirSync(FH).filter(d => /^\d{4}-\d{2}-\d{2}$/.test(d))) {
  for (const f of fs.readdirSync(path.join(FH, day)).filter(f => f.endsWith('.json'))) {
    const m = f.match(/^(?:(h23|h04)-)?(average|best_match|ecmwf_ifs025)-/); if (!m) continue;
    const j = JSON.parse(strip(fs.readFileSync(path.join(FH, day, f), 'utf8')));
    const hdr = j.detail_header.split(',');
    const rows = j.detail_rows.map(r => { const c = typeof r === 'string' ? parseLine(r) : r; return Object.fromEntries(hdr.map((k, i) => [k, c[i] === undefined || c[i] === '' ? null : c[i]])); });
    fcs.push({ folder: day, cohort: m[1] || 'eve', model: m[2], issued: j.issued_at, rows });
  }
}
// 対象日 D に対する発表: eve = D-1 フォルダ、h23 = D-1、h04 = D。重複は issued_at が最も早いもの
function getFc(target, cohort, model) {
  const folder = cohort === 'h04' ? target : addD(target, -1);
  const c = fcs.filter(f => f.folder === folder && f.cohort === cohort && f.model === model).sort((a, b) => a.issued < b.issued ? -1 : 1)[0];
  if (!c) return null;
  const rows = c.rows.filter(r => r.date === target);
  return rows.length ? { issued: c.issued, rows } : null;
}

// ---- 谷の実績（朝・放射冷却型の観測のみ）----
const log = parseCsv(fs.readFileSync(path.join(ROOT, 'unkai_log.csv'), 'utf8'));
const valley = []; // {day, dir, yes, level, note}
for (const r of log) {
  if (!['なし', '一部', '広範囲'].includes(r.valley_unkai)) continue;
  if (r.date <= '2026-09-07') continue; // 9/7 は日中・雨上がり型
  if (r.date === '2026-09-27') continue; // 18時の観測（朝ではない）
  const dirs = r.direction === '-' ? ['北', '南'] : [r.direction];
  for (const dir of dirs) valley.push({ day: r.date, dir, yes: r.valley_unkai !== 'なし' ? 1 : 0, level: r.valley_unkai, below: /谷側から確認/.test(r.note || '') });
}
console.log('# 谷の実績（朝）');
console.log(valley.map(v => `${v.day.slice(5)}${v.dir}:${v.level}${v.below ? '(谷側から)' : ''}`).join('  '));

const DIRPTS = { '北': ['N_C', 'N_E'], '南': ['S_A', 'S_B'] };
// 方向ごとの朝の値: 4時刻 × 2地点の最大（本番カードと同じ集約）。hour 指定時はその時刻のみ
function dirVal(fc, dir, key, hour = null) {
  const v = fc.rows.filter(r => DIRPTS[dir].includes(r.point_id) && (hour === null || +r.time.slice(11, 13) === hour)).map(r => key === 'simple' ? (r.simple === null ? null : (r.simple === 'True' || r.simple === '1' || r.simple === 'true' ? 1 : 0)) : num(r[key])).filter(x => x !== null);
  return v.length ? Math.max(...v) : null;
}
function aucOf(items) { let s = 0, n = 0; for (const p of items) if (p.y) for (const q of items) if (!q.y) { s += p.s > q.s ? 1 : p.s === q.s ? 0.5 : 0; n++; } return n ? s / n : null; }

const FKEYS = [['F_c', '本番F(案c)'], ['idx', '指数'], ['F_add', '加算式'], ['F_b', '案b'], ['F_c_mlin', '案c・露点差線形'], ['F_c_mpow', '案c・露点差曲線'], ['F_c_rrange', '案c・日較差R'], ['F0', '当初案'], ['simple', '経験則○×'], ['RH', '谷の湿度'], ['day_range', '日較差'], ['C', 'C(中高層雲)'], ['W', 'W(風)']];
console.log('\n\n# A. 谷の雲海（F側）');
for (const cohort of ['eve', 'h23', 'h04']) for (const model of ['best_match', 'average', 'ecmwf_ifs025']) for (const hour of [null, 7]) {
  const items = valley.map(v => ({ ...v, fc: getFc(v.day, cohort, model) })).filter(v => v.fc);
  if (items.length < 3) continue;
  const ny = items.filter(v => v.yes).length;
  console.log(`\n## 発表 ${cohort} / ${model} / ${hour === null ? '朝4時刻の最大' : hour + '時のみ'}: ${items.length}件（あり${ny}・なし${items.length - ny}）・${new Set(items.map(v => v.day)).size}日`);
  const line = [];
  for (const [k, name] of FKEYS) {
    const s = items.map(v => ({ y: v.yes, s: dirVal(v.fc, v.dir, k, hour) })).filter(x => x.s !== null);
    line.push(`${name} ${f2(aucOf(s))}`);
  }
  console.log('AUC: ' + line.join(' | '));
  // 表
  console.log('日付 方向 実績        F_c   idx  simple  RH   日較差 C    W');
  for (const v of items) console.log(`${v.day.slice(5)} ${v.dir} ${(v.level + (v.below ? '(谷側)' : '')).padEnd(8)} ${f2(dirVal(v.fc, v.dir, 'F_c', hour))} ${String(dirVal(v.fc, v.dir, 'idx', hour)).padStart(4)}  ${dirVal(v.fc, v.dir, 'simple', hour) ? '○' : '×'}     ${String(dirVal(v.fc, v.dir, 'RH', hour)).padStart(3)}  ${f2(dirVal(v.fc, v.dir, 'day_range', hour))}  ${f2(dirVal(v.fc, v.dir, 'C', hour))} ${f2(dirVal(v.fc, v.dir, 'W', hour))}`);
  // 判定表
  const judge = (name, pred) => { let tp = 0, fp = 0, fn = 0, tn = 0; for (const v of items) { const p = pred(v); if (p === null) continue; if (p && v.yes) tp++; else if (p) fp++; else if (v.yes) fn++; else tn++; } return `${name}: 正解${tp + tn}/${tp + fp + fn + tn} (捕捉${tp}/${tp + fn} 空振り${fp}/${fp + tn})`; };
  console.log([judge('F≥0.40', v => { const x = dirVal(v.fc, v.dir, 'F_c', hour); return x === null ? null : x >= 0.4; }),
    judge('F≥0.70', v => { const x = dirVal(v.fc, v.dir, 'F_c', hour); return x === null ? null : x >= 0.7; }),
    judge('経験則○', v => { const x = dirVal(v.fc, v.dir, 'simple', hour); return x === null ? null : !!x; }),
    judge('谷の湿度≥80', v => { const x = dirVal(v.fc, v.dir, 'RH', hour); return x === null ? null : x >= 80; }),
    judge('常に「あり」', v => true)].join('\n'));
}

// ---- 展望側（V）: カメラ v1 ラベル ----
const crit = JSON.parse(strip(fs.readFileSync(path.join(ROOT, 'camera', 'fog-criteria-v1.json'), 'utf8')));
const cam = parseCsv(fs.readFileSync(path.join(ROOT, 'camera', 'mezuru_contrast.csv'), 'utf8'));
const camByTarget = {};
for (const r of cam) {
  if (r.dark !== '0') continue; const mean = num(r.mean_all), near = num(r.near_lc), far = num(r.far_lc);
  if (mean === null || near === null || far === null || mean < crit.dark_min || (r.note || '').includes('size_changed')) continue;
  const code = near < crit.near_dense_max && far < crit.far_hidden_max ? 'D' : far < crit.far_hidden_max ? 'B' : far < crit.far_clear_min ? 'H' : 'C';
  const d = new Date(r.captured_at_jst.slice(0, 13).replace(' ', 'T') + ':00:00Z'); d.setUTCHours(d.getUTCHours() + 1);
  camByTarget[d.toISOString().slice(0, 13).replace('T', ' ')] = code;
}
const fogC = c => c === 'D' || c === 'B' ? 1 : 0;
console.log('\n\n# B. 展望側（V）× カメラ（朝の各時刻。カメラ HH:50 → 予報 HH+1:00）');
const days = [...new Set(fcs.map(f => f.cohort === 'h04' ? f.folder : addD(f.folder, 1)))].sort();
function vRows(cohort, model) {
  const out = [];
  for (const day of days) {
    const fc = getFc(day, cohort, model); if (!fc) continue;
    const byTime = {};
    for (const r of fc.rows) (byTime[r.time] = byTime[r.time] || []).push(r);
    for (const [t, rs] of Object.entries(byTime)) {
      const code = camByTarget[t.slice(0, 13)]; if (!code) continue;
      if (cohort === 'h04' && t <= fc.issued.slice(0, 16).replace('T', ' ')) continue;
      const r0 = rs[0]; // V_summit は地点共通
      const idxMax = Math.max(...rs.map(r => num(r.idx) ?? -1)), fMax = Math.max(...rs.map(r => num(r.F_c) ?? -1));
      const vMax = Math.max(...rs.map(r => num(r.V) ?? -1));
      out.push({ day, t, hour: +t.slice(11, 13), code, fog: fogC(code), status: r0.summit_status, vs: num(r0.V_summit), rhB: num(r0.summit_rh_below), rhA: num(r0.summit_rh_above), vtop: rs.map(r => num(r.V_top_fog)), V: vMax < 0 ? null : vMax, idx: idxMax < 0 ? null : idxMax, F: fMax < 0 ? null : fMax, labels: rs.map(r => r.label) });
    }
  }
  return out;
}
for (const cohort of ['eve', 'h23', 'h04']) for (const model of ['ecmwf_ifs025', 'best_match', 'average']) {
  const rows = vRows(cohort, model); if (rows.length < 5) continue;
  const nf = rows.filter(r => r.fog).length;
  console.log(`\n## ${cohort} / ${model}: ${rows.length}時刻（霧${nf}=${pct(nf, rows.length)}）・${new Set(rows.map(r => r.day)).size}日  期間 ${rows[0].day}〜${rows[rows.length - 1].day}`);
  const st = {};
  for (const r of rows) { const k = r.status || 'null'; st[k] = st[k] || [0, 0]; st[k][0]++; st[k][1] += r.fog; }
  console.log('状態別の霧: ' + Object.entries(st).map(([k, [n, f]]) => `${k} ${pct(f, n)}(${f}/${n})`).join('  '));
  console.log(`AUC(V_summit 低いほど霧) ${f2(aucOf(rows.filter(r => r.vs !== null).map(r => ({ y: r.fog, s: -r.vs }))))}  AUC(V) ${f2(aucOf(rows.filter(r => r.V !== null).map(r => ({ y: r.fog, s: -r.V }))))}  AUC(山上地上RH) ${f2(aucOf(rows.filter(r => r.rhB !== null).map(r => ({ y: r.fog, s: r.rhB }))))}  AUC(850hPa RH) ${f2(aucOf(rows.filter(r => r.rhA !== null).map(r => ({ y: r.fog, s: r.rhA }))))}`);
  const bw = rows.filter(r => r.status === 'below_wet');
  for (const [a, b] of [[90, 94], [94, 97], [97, 101]]) { const x = bw.filter(r => r.rhB >= a && r.rhB < b); console.log(`  below_wet 地上RH ${a}-${b === 101 ? 100 : b - 1}: 霧 ${pct(x.filter(r => r.fog).length, x.length)}(${x.filter(r => r.fog).length}/${x.length}) ${new Set(x.map(r => r.day)).size}日`); }
  for (const h of [6, 7, 8]) { const x = bw.filter(r => r.hour === h); if (x.length) console.log(`  below_wet ${h}時: 霧 ${pct(x.filter(r => r.fog).length, x.length)}(${x.filter(r => r.fog).length}/${x.length})`); }
  if (model === 'ecmwf_ifs025' && cohort === 'eve') {
    console.log('  below_wet の内訳: ' + bw.map(r => `${r.day.slice(5)} ${r.hour}時${r.code}(${r.rhB}/${r.rhA})`).join(' '));
  }
}
// ---- C. 状態ごとの「展望あり」の割合と V_summit の値（EC・前夜）
console.log('\n\n# C. V_summit の状態ごとの展望あり割合（朝・前夜発表）');
for (const model of ['ecmwf_ifs025', 'best_match']) {
  const rows = vRows('eve', model); const st = {};
  for (const r of rows) { const k = r.status || 'null'; st[k] = st[k] || { n: 0, clear: 0, v: r.vs }; st[k].n++; st[k].clear += 1 - r.fog; }
  console.log(model + ': ' + Object.entries(st).map(([k, o]) => `${k} V=${o.v} 展望あり${pct(o.clear, o.n)}(${o.clear}/${o.n})`).join('  '));
  // Brier: V を「展望ありの確率」とみなした時
  const brier = vals => { const x = rows.filter(r => r.vs !== null); return (x.reduce((p, r) => p + (vals(r) - (1 - r.fog)) ** 2, 0) / x.length).toFixed(3); };
  console.log(`  Brier(現行) ${brier(r => r.vs)}  below_wet=0.15 ${brier(r => r.status === 'below_wet' ? 0.15 : r.vs)}  above_wet=0.50 ${brier(r => r.status === 'above_wet' ? 0.5 : r.vs)}`);
}
// ---- D. below_wet(EC) を規定版の山上地上湿度で分ける
console.log('\n# D. EC の below_wet を規定版の山上地上湿度で分ける（前夜）');
{
  const ec = vRows('eve', 'ecmwf_ifs025'), bm = Object.fromEntries(vRows('eve', 'best_match').map(r => [r.t, r]));
  const bw = ec.filter(r => r.status === 'below_wet' && bm[r.t]);
  for (const [a, b] of [[0, 90], [90, 97], [97, 101]]) { const x = bw.filter(r => bm[r.t].rhB >= a && bm[r.t].rhB < b); console.log(`  規定版地上RH ${a}-${b === 101 ? 100 : b - 1}: 霧 ${pct(x.filter(r => r.fog).length, x.length)}(${x.filter(r => r.fog).length}/${x.length}) ${new Set(x.map(r => r.day)).size}日`); }
  const all = ec.filter(r => bm[r.t]);
  console.log(`  参考 全状態で規定版地上RH≥97: 霧 ${pct(all.filter(r => bm[r.t].rhB >= 97 && r.fog).length, all.filter(r => bm[r.t].rhB >= 97).length)}(${all.filter(r => bm[r.t].rhB >= 97 && r.fog).length}/${all.filter(r => bm[r.t].rhB >= 97).length})  <97: ${pct(all.filter(r => bm[r.t].rhB < 97 && r.fog).length, all.filter(r => bm[r.t].rhB < 97).length)}`);
}
// ---- E. 谷の実績がある日の展望
console.log('\n# E. 谷の実績がある日の展望（カメラ）と V（平均版・前夜）');
for (const day of [...new Set(valley.map(v => v.day))]) {
  const rows = vRows('eve', 'average').filter(r => r.day === day);
  console.log(`  ${day.slice(5)} 谷:${valley.filter(v => v.day === day).map(v => v.dir + v.level).join('/')}  ` + rows.map(r => `${r.hour}時 カメラ${r.code} ${r.status}(V=${r.vs}) idx${r.idx}`).join(' | '));
}
// ---- F. 「姫鶴平から雲海が見られたか」（日単位）
console.log('\n# F. 姫鶴平から雲海が見られたか（日単位・平均版・前夜）');
const seen = { '2026-09-17': 1, '2026-10-01': 1, '2026-10-15': 1 };
const notSeen = ['2026-09-19', '2026-09-20', '2026-09-21', '2026-09-22', '2026-09-23', '2026-09-25', '2026-09-26', '2026-10-06', '2026-10-16', '2026-10-18', '2026-10-20', '2026-10-21'];
const items = [];
for (const day of [...Object.keys(seen), ...notSeen]) {
  const fc = getFc(day, 'eve', 'average'), fcb = getFc(day, 'eve', 'best_match'); if (!fc) { console.log('  発表なし ' + day); continue; }
  const mx = (f, k) => Math.max(...f.rows.map(r => num(r[k]) ?? -1));
  const simple = fcb ? Math.max(...fcb.rows.map(r => r.simple === '1' ? 1 : 0)) : null;
  items.push({ day, y: seen[day] ? 1 : 0, idx: mx(fc, 'idx'), F: mx(fc, 'F_c'), simple, label: fc.rows.filter(r => num(r.idx) === mx(fc, 'idx'))[0].label });
}
for (const it of items) console.log(`  ${it.day.slice(5)} ${it.y ? '見られた  ' : '見られない'} 指数${String(it.idx).padStart(4)} F${f2(it.F)} 経験則${it.simple ? '○' : '×'} ${it.label}`);
console.log(`  AUC 指数 ${f2(aucOf(items.map(i => ({ y: i.y, s: i.idx }))))}  F ${f2(aucOf(items.map(i => ({ y: i.y, s: i.F }))))}  経験則 ${f2(aucOf(items.map(i => ({ y: i.y, s: i.simple }))))}`);
for (const th of [50, 70]) { const tp = items.filter(i => i.y && i.idx >= th).length, fp = items.filter(i => !i.y && i.idx >= th).length; console.log(`  指数≥${th}: 捕捉 ${tp}/3 空振り ${fp}/${items.length - 3}`); }
{ const tp = items.filter(i => i.y && i.simple).length, fp = items.filter(i => !i.y && i.simple).length; console.log(`  経験則○: 捕捉 ${tp}/3 空振り ${fp}/${items.length - 3}`); }
