"""Read-only audit of saved forecasts, fixed camera criteria, and prior visual review.

Run with Python 3. Outputs audit JSON next to this script. Does not change forecasts
or camera data. Times are JST. Actual blocks use camera clock hours; full forecast
blocks use the application's 5-10, 11-15, 16-20 hour ranges. Night is unobserved.
"""
import csv
import hashlib
import json
import math
import random
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(__file__).with_suffix('.json')
JST = timezone(timedelta(hours=9))
START = datetime(2026, 9, 12)
POST = datetime(2026, 9, 25)
END = datetime(2026, 10, 10)
BLOCKS = [('朝', 5, 10), ('昼', 11, 15), ('夕', 16, 20)]
FIELDS = ['cl_avg', 'cl_bm', 'cl_ec', 'rh2m_bm', 'rh2m_ec', 'wind_bm']

def load_csv(name):
    data = (ROOT / name).read_bytes()
    return list(csv.DictReader(data.decode('utf-8-sig').splitlines())), hashlib.sha256(data).hexdigest()

def num(r, k):
    try:
        n = float(r[k])
        return n if math.isfinite(n) else None
    except (KeyError, TypeError, ValueError):
        return None

def mean(v):
    v = [x for x in v if x is not None]
    return sum(v) / len(v) if v else None

def auc(rows, field='cl_avg', same_day=False):
    rows = [r for r in rows if r.get(field) is not None]
    if same_day:
        groups = defaultdict(list)
        for r in rows:
            groups[r['day']].append(r)
        wins = total = 0
        for group in groups.values():
            pos = [r[field] for r in group if r['fog']]
            neg = [r[field] for r in group if not r['fog']]
            wins += sum((p > n) + 0.5 * (p == n) for p in pos for n in neg)
            total += len(pos) * len(neg)
        return wins / total if total else None
    ordered = sorted(rows, key=lambda r: r[field])
    rank_sum = 0
    i = 0
    while i < len(ordered):
        j = i + 1
        while j < len(ordered) and ordered[j][field] == ordered[i][field]:
            j += 1
        rank_sum += (i + 1 + j) / 2 * sum(r['fog'] for r in ordered[i:j])
        i = j
    p = sum(r['fog'] for r in ordered)
    n = len(ordered) - p
    return (rank_sum - p * (p + 1) / 2) / (p * n) if p and n else None

def boot_auc(rows, field, draws=1000):
    groups = defaultdict(list)
    for r in rows:
        groups[r['day']].append(r)
    days = list(groups)
    rng = random.Random(20261009)
    values = []
    for _ in range(draws):
        sample = [r for _ in days for r in groups[rng.choice(days)]]
        value = auc(sample, field)
        if value is not None:
            values.append(value)
    values.sort()
    return [values[int(len(values)*.05)], values[min(len(values)-1, int(len(values)*.95))]] if values else None

def confusion(rows, predict):
    c = Counter()
    for r in rows:
        p = predict(r)
        if p is None:
            continue
        c['tp' if p and r['fog'] else 'fp' if p else 'fn' if r['fog'] else 'tn'] += 1
    tp, fp, fn, tn = (c[k] for k in ['tp', 'fp', 'fn', 'tn'])
    n = tp + fp + fn + tn
    recall = tp / (tp + fn) if tp + fn else None
    specificity = tn / (tn + fp) if tn + fp else None
    return dict(n=n, tp=tp, fp=fp, fn=fn, tn=tn, accuracy=(tp+tn)/n if n else None,
                recall=recall, specificity=specificity,
                precision=tp/(tp+fp) if tp+fp else None,
                balanced_accuracy=(recall+specificity)/2 if recall is not None and specificity is not None else None)

def summarize(rows):
    metrics = {}
    for field in FIELDS:
        metrics[field] = dict(auc=auc(rows, field), ci90_day_bootstrap=boot_auc(rows, field),
                              within_day_auc=auc(rows, field, True), n=sum(r.get(field) is not None for r in rows))
    bins = []
    for lo, hi in [(0, 30), (30, 40), (40, 50), (50, 60), (60, 101)]:
        group = [r for r in rows if r.get('cl_avg') is not None and lo <= r['cl_avg'] < hi]
        bins.append(dict(low=lo, high=hi, n=len(group), fog=sum(r['fog'] for r in group),
                         days=len({r['day'] for r in group}), rate=mean([r['fog'] for r in group])))
    return dict(n=len(rows), days=len({r['day'] for r in rows}), fog=sum(r['fog'] for r in rows),
                no_fog_baseline=mean([1-r['fog'] for r in rows]), metrics=metrics, bins=bins,
                thresholds={str(t): confusion(rows, lambda r: r['cl_avg'] >= t if r.get('cl_avg') is not None else None)
                            for t in [30, 40, 45, 50, 60]},
                mid_rain={name: dict(n=len(s), fog=sum(r['fog'] for r in s), rate=mean([r['fog'] for r in s]))
                          for name, s in [('rain_ge1', [r for r in rows if 30 <= r['cl_avg'] < 60 and r.get('rain') is not None and r['rain'] >= 1]),
                                          ('rain_lt1', [r for r in rows if 30 <= r['cl_avg'] < 60 and r.get('rain') is not None and r['rain'] < 1])]},
                mid_humidity={str(t): {name: dict(n=len(s), fog=sum(r['fog'] for r in s), rate=mean([r['fog'] for r in s]))
                                      for name, s in [('ge', [r for r in rows if 30 <= r['cl_avg'] < 60 and r.get('rh2m_ec') is not None and r['rh2m_ec'] >= t]),
                                                      ('lt', [r for r in rows if 30 <= r['cl_avg'] < 60 and r.get('rh2m_ec') is not None and r['rh2m_ec'] < t])]}
                              for t in [90, 95, 98]})

camera, camera_hash = load_csv('mezuru_contrast.csv')
forecast, forecast_hash = load_csv('fog_forecast.csv')
criteria = json.loads((ROOT/'fog-criteria-v1.json').read_text(encoding='utf-8-sig'))
visual = json.loads((ROOT/'visual-review-20260923.json').read_text(encoding='utf-8-sig'))['observations']
qc = Counter()
obs = []
seen = set()
for r in camera:
    time = datetime.fromisoformat(r['captured_at_jst'])
    if not START <= time < END:
        continue
    qc['camera_in_period'] += 1
    if time in seen:
        qc['duplicate_time'] += 1
        continue
    seen.add(time)
    if r['dark'] != '0' or num(r, 'mean_all') is None or num(r, 'mean_all') < criteria['dark_min']:
        qc['dark_or_missing_brightness'] += 1
        continue
    if 'size_changed' in r.get('note', ''):
        qc['size_changed'] += 1
        continue
    near, far, mid = (num(r, k) for k in ['near_lc', 'far_lc', 'mid_lc'])
    if None in (near, far, mid):
        qc['contrast_missing'] += 1
        continue
    age = None
    if r.get('http_last_modified'):
        modified = parsedate_to_datetime(r['http_last_modified']).astimezone(JST).replace(tzinfo=None)
        age = (time-modified).total_seconds()/60
        if age > 90 or age < -5:
            qc['stale_or_future_image'] += 1
            continue
    if not 5 <= time.hour <= 18 or time.minute != 50:
        qc['outside_fixed_hour'] += 1
        continue
    code = 'D' if near < 1 and far < .3 else 'B' if far < .3 else 'H' if far < 1.5 else 'C'
    obs.append(dict(time=time.isoformat(' ', timespec='minutes'), day=str(time.date()), hour=time.hour,
                    target=(time.replace(minute=0)+timedelta(hours=1)).isoformat(' ', timespec='minutes'),
                    code=code, fog=int(code in ['D', 'B']), far=far, near=near, old_label=r['label'], age_min=age,
                    review=abs(far-.3) <= .1 or abs(near-1) <= .2 or (code == 'C' and mid < 3.5),
                    image=f"images/mezuru_{time:%Y%m%d_%H%M}.jpg"))
obs.sort(key=lambda r: r['time'])
findex = {}
for r in forecast:
    k = (r['issued_at'], r['target_time'])
    if k in findex:
        qc['duplicate_forecast'] += 1
        if r != findex[k]:
            raise ValueError('Conflicting forecasts with same issue and target')
    findex[k] = r

def issue(day, cohort):
    d = datetime.fromisoformat(day)
    return ((d-timedelta(days=1)).strftime('%Y-%m-%d')+' 18:25' if cohort == 'evening' else day+' 06:25')

def enrich(o, cohort):
    issued = issue(o['day'], cohort)
    if issued >= o['time']:
        return None
    f = findex.get((issued, o['target']))
    if not f or num(f, 'cl_avg') is None:
        return None
    pb, pe = num(f, 'precip_bm'), num(f, 'precip_ec')
    rain = .7*pb+.3*pe if pb is not None and pe is not None else pb if pe is None else pe
    return {**o, **{k: num(f, k) for k in FIELDS}, 'issued': issued, 'rain': rain}

cohorts = {}
for cohort in ['evening', 'morning']:
    joined = [j for o in obs if (j := enrich(o, cohort)) is not None]
    cohorts[cohort] = dict(full=summarize(joined), post_implementation=summarize([r for r in joined if r['day'] >= str(POST.date())]), rows=joined)

auto_index = {r['time']: r for r in obs}
overlap = [(v, auto_index[v['time']]) for v in visual if v['time'] in auto_index and v['visual'] in ['D', 'B', 'H', 'C']]
qc_visual = dict(n=len(overlap), binary_agreement=mean([int((v['visual'] in ['D','B']) == bool(a['fog'])) for v,a in overlap]),
                 four_class_agreement=mean([int(v['visual']==a['code']) for v,a in overlap]),
                 disagreements=[dict(time=v['time'], visual=v['visual'], auto=a['code'], far=a['far'], near=a['near']) for v,a in overlap if (v['visual'] in ['D','B']) != bool(a['fog'])])
visual_results = {}
for cohort in ['evening', 'morning']:
    rows = []
    for v in visual:
        if v['visual'] not in ['D','B','H','C']:
            continue
        t = datetime.fromisoformat(v['time'])
        o = dict(time=v['time'], day=str(t.date()), hour=t.hour, target=(t.replace(minute=0)+timedelta(hours=1)).isoformat(' ', timespec='minutes'), fog=int(v['visual'] in ['D','B']), code=v['visual'])
        if (j := enrich(o, cohort)) is not None:
            rows.append(j)
    visual_results[cohort] = summarize(rows)

blocks = {}
for cohort in ['evening', 'morning']:
    out = []
    for day in sorted({o['day'] for o in obs}):
        for name, first, last in BLOCKS:
            issued = issue(day, cohort)
            if issued >= f'{day} {first:02}:00':
                continue  # Cannot reconstruct a full morning block from a 06:25 future-only snapshot.
            actual = [o for o in obs if o['day']==day and first <= o['hour'] <= last]
            if len(actual) < 4 or f'{day} {last:02}:59' > max(r['captured_at_jst'] for r in camera):
                continue
            fs = [findex.get((issued, f'{day} {h:02}:00')) for h in range(first,last+1)]
            fs = [f for f in fs if f is not None]
            if len(fs) != last-first+1 or any(num(f,'cl_avg') is None for f in fs):
                continue  # Saved hours stop at 19:00: full evening outlook is unidentifiable.
            cloud = mean([num(f,'cl_avg') for f in fs])
            rains = [(.7*pb+.3*pe if pb is not None and pe is not None else pb if pe is None else pe)
                     for f in fs for pb,pe in [(num(f,'precip_bm'),num(f,'precip_ec'))]]
            rain = max((r for r in rains if r is not None), default=None)
            level = 'low' if cloud < 30 else 'high' if cloud >= 60 else 'midrain' if rain is not None and rain >= 1 else 'mid'
            out.append(dict(day=day, block=name, cloud=cloud, rain=rain, level=level,
                            n_observed=len(actual), fog_n=sum(o['fog'] for o in actual), fog_rate=mean([o['fog'] for o in actual]),
                            dense_rate=mean([int(o['code']=='D') for o in actual]), fog=int(mean([o['fog'] for o in actual])>=.5)))
    blocks[cohort] = {}
    for period in ['full', 'post_implementation']:
        rs = [r for r in out if period=='full' or r['day'] >= str(POST.date())]
        group_summary = {}
        for level in ['low', 'mid', 'midrain', 'high']:
            g = [r for r in rs if r['level']==level]
            group_summary[level] = dict(blocks=len(g), days=len({r['day'] for r in g}),
                                        mean_fog_rate=mean([r['fog_rate'] for r in g]),
                                        mean_dense_rate=mean([r['dense_rate'] for r in g]),
                                        obs=sum(r['n_observed'] for r in g), fog_obs=sum(r['fog_n'] for r in g),
                                        majority_fog=sum(r['fog'] for r in g))
        blocks[cohort][period] = dict(n=len(rs), groups=group_summary, rows=rs)

daily = []
for day in sorted({o['day'] for o in obs}):
    os = [o for o in obs if o['day']==day]
    js = [r for r in cohorts['evening']['rows'] if r['day']==day]
    daily.append(dict(day=day, n=len(os), fog_rate=mean([o['fog'] for o in os]), dense_rate=mean([int(o['code']=='D') for o in os]),
                      cl_avg=mean([r['cl_avg'] for r in js]), cl_bm=mean([r['cl_bm'] for r in js]), cl_ec=mean([r['cl_ec'] for r in js]),
                      codes=''.join(o['code'] for o in os)))

new_review = json.loads((Path(__file__).parent/'visual-review-20261009.json').read_text(encoding='utf-8'))
new_obs = []
new_disagreements = []
for day, sequence in new_review['sequences'].items():
    os = [o for o in obs if o['day']==day]
    assert len(os)==len(sequence), (day,len(os),len(sequence))
    for o, label in zip(os, sequence):
        assert label in 'DBHC'
        reviewed = {**o, 'code':label, 'fog':int(label in 'DB')}
        new_obs.append(reviewed)
        if o['fog'] != reviewed['fog']:
            new_disagreements.append(dict(time=o['time'], auto=o['code'], visual=label))
new_visual_results = {}
new_visual_blocks = {}
for cohort in ['evening', 'morning']:
    joined = [j for o in new_obs if (j:=enrich(o,cohort)) is not None]
    new_visual_results[cohort] = {**summarize(joined),'rows':joined}
    vblocks = []
    for b in blocks[cohort]['post_implementation']['rows']:
        _, first, last = next(x for x in BLOCKS if x[0]==b['block'])
        actual = [o for o in new_obs if o['day']==b['day'] and first<=o['hour']<=last]
        vblocks.append({**b, 'fog_n':sum(o['fog'] for o in actual), 'fog_rate':mean([o['fog'] for o in actual]),
                        'dense_rate':mean([int(o['code']=='D') for o in actual]),
                        'fog':int(mean([o['fog'] for o in actual])>=.5)})
    groups = {}
    for level in ['low','mid','midrain','high']:
        g=[b for b in vblocks if b['level']==level]
        groups[level]=dict(blocks=len(g),days=len({b['day'] for b in g}),
                           mean_fog_rate=mean([b['fog_rate'] for b in g]),mean_dense_rate=mean([b['dense_rate'] for b in g]),
                           obs=sum(b['n_observed'] for b in g),fog_obs=sum(b['fog_n'] for b in g),
                           majority_fog=sum(b['fog'] for b in g))
    new_visual_blocks[cohort]=dict(n=len(vblocks),groups=groups,rows=vblocks)

result = dict(created_at=datetime.now(JST).isoformat(timespec='seconds'),
              sources=dict(camera_sha256=camera_hash, forecast_sha256=forecast_hash, camera_rows=len(camera), forecast_rows=len(forecast),
                           latest_camera=max(r['captured_at_jst'] for r in camera), latest_forecast_issue=max(r['issued_at'] for r in forecast),
                           forecast_issue_times=dict(Counter(r['issued_at'][11:] for r in forecast)),
                           missing_precip_ec=sum(num(r,'precip_ec') is None for r in forecast)),
              qc=dict(qc), camera_observations=len(obs), camera_codes=dict(Counter(o['code'] for o in obs)),
              prior_visual_agreement=qc_visual, prior_visual_results=visual_results, cohorts=cohorts, blocks=blocks, daily=daily,
              post_visual_results=new_visual_results, post_visual_blocks=new_visual_blocks, post_visual_disagreements=new_disagreements)
OUT.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps({k:v for k,v in result.items() if k not in ['cohorts','blocks','daily','prior_visual_results','post_visual_results','post_visual_blocks']}, ensure_ascii=False, indent=2))
for c in new_visual_results:
    print('POST_VISUAL',c,json.dumps({k:v for k,v in new_visual_results[c].items() if k!='rows'},ensure_ascii=False))
    print('POST_VISUAL_BLOCK',c,json.dumps({k:v for k,v in new_visual_blocks[c].items() if k!='rows'},ensure_ascii=False))
