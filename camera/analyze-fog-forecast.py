"""Compare saved fog forecasts with the fixed v1 camera visibility criteria.

Camera HH:50 observations are matched to the following whole forecast hour.
The script is read-only and uses only Python's standard library.
"""
from __future__ import annotations

import csv
import json
import math
from collections import Counter
from datetime import datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent
START = datetime(2026, 9, 11)


def num(row, key):
    try:
        return float(row[key]) if row[key] != "" else None
    except (KeyError, TypeError, ValueError):
        return None


def pearson(xs, ys):
    pairs = [(x, y) for x, y in zip(xs, ys) if x is not None and y is not None]
    if len(pairs) < 3:
        return None
    xbar = sum(x for x, _ in pairs) / len(pairs)
    ybar = sum(y for _, y in pairs) / len(pairs)
    top = sum((x-xbar)*(y-ybar) for x, y in pairs)
    bot = math.sqrt(sum((x-xbar)**2 for x, _ in pairs) * sum((y-ybar)**2 for _, y in pairs))
    return top / bot if bot else None


def ranks(values):
    order = sorted(range(len(values)), key=values.__getitem__)
    out = [0.0] * len(values)
    i = 0
    while i < len(order):
        j = i + 1
        while j < len(order) and values[order[j]] == values[order[i]]:
            j += 1
        rank = (i + 1 + j) / 2
        for k in order[i:j]:
            out[k] = rank
        i = j
    return out


def spearman(xs, ys):
    pairs = [(x, y) for x, y in zip(xs, ys) if x is not None and y is not None]
    return pearson(ranks([x for x, _ in pairs]), ranks([y for _, y in pairs])) if len(pairs) >= 3 else None


def auc(scores, labels):
    pos = [s for s, y in zip(scores, labels) if s is not None and y == 1]
    neg = [s for s, y in zip(scores, labels) if s is not None and y == 0]
    if not pos or not neg:
        return None
    wins = sum(1 if p > n else 0.5 if p == n else 0 for p in pos for n in neg)
    return wins / (len(pos) * len(neg))


def confusion(rows, field, threshold, high_is_fog=True):
    pairs = [(r[field], r["fog"]) for r in rows if r[field] is not None]
    tp = fp = tn = fn = 0
    for score, actual in pairs:
        pred = score >= threshold if high_is_fog else score <= threshold
        if pred and actual: tp += 1
        elif pred: fp += 1
        elif actual: fn += 1
        else: tn += 1
    sensitivity = tp / (tp + fn) if tp + fn else None
    specificity = tn / (tn + fp) if tn + fp else None
    accuracy = (tp + tn) / len(pairs) if pairs else None
    balanced = (sensitivity + specificity) / 2 if sensitivity is not None and specificity is not None else None
    return {"n": len(pairs), "tp": tp, "fn": fn, "fp": fp, "tn": tn,
            "sensitivity": sensitivity, "specificity": specificity,
            "accuracy": accuracy, "balanced_accuracy": balanced}


def mean_absolute_error(xs, ys):
    pairs = [(x, y) for x, y in zip(xs, ys) if x is not None and y is not None]
    return sum(abs(x-y) for x, y in pairs) / len(pairs) if pairs else None


criteria = json.loads((ROOT / "fog-criteria-v1.json").read_text(encoding="utf-8-sig"))
with (ROOT / "mezuru_contrast.csv").open(encoding="utf-8-sig", newline="") as f:
    camera_raw = list(csv.DictReader(f))
with (ROOT / "fog_forecast.csv").open(encoding="utf-8-sig", newline="") as f:
    forecast_raw = list(csv.DictReader(f))

observations = []
for r in camera_raw:
    captured = datetime.strptime(r["captured_at_jst"], "%Y-%m-%d %H:%M")
    near, mid, far, mean = (num(r, k) for k in ("near_lc", "mid_lc", "far_lc", "mean_all"))
    if captured < START or r.get("dark") != "0" or None in (near, mid, far, mean):
        continue
    if mean < criteria["dark_min"] or "size_changed" in r.get("note", ""):
        continue
    if near < criteria["near_dense_max"] and far < criteria["far_hidden_max"]:
        code = "D"
    elif far < criteria["far_hidden_max"]:
        code = "B"
    elif far < criteria["far_clear_min"]:
        code = "H"
    else:
        code = "C"
    actual_v = {"D": 0.0, "B": 0.25, "H": 0.5, "C": 1.0}[code]
    observations.append({"captured": captured, "target": captured.replace(minute=0) + timedelta(hours=1),
                         "near": near, "mid": mid, "far": far, "code": code,
                         "actual_v": actual_v, "fog": 1 if code in ("D", "B") else 0})

forecasts = []
for r in forecast_raw:
    issued = datetime.strptime(r["issued_at"], "%Y-%m-%d %H:%M")
    target = datetime.strptime(r["target_time"], "%Y-%m-%d %H:%M")
    forecasts.append({"issued": issued, "target": target, **{k: num(r, k) for k in
        ("lead_h", "cl_bm", "cl_ec", "cl_avg", "v_bm", "v_ec", "wind_bm", "vis_bm", "precip_bm", "precip_ec")}})

by_target = {}
for f in forecasts:
    by_target.setdefault(f["target"], []).append(f)


def joined(cohort):
    out = []
    for o in observations:
        candidates = [f for f in by_target.get(o["target"], []) if f["issued"] < o["target"]]
        if cohort == "latest":
            candidates = sorted(candidates, key=lambda f: f["issued"], reverse=True)[:1]
        elif cohort == "morning":
            candidates = [f for f in candidates if f["issued"].date() == o["target"].date() and f["issued"].strftime("%H:%M") == "06:25"]
        elif cohort == "previous_evening":
            candidates = [f for f in candidates if f["issued"].date() == o["target"].date() - timedelta(days=1) and f["issued"].strftime("%H:%M") == "18:25"]
        if candidates:
            out.append({**o, **sorted(candidates, key=lambda f: f["issued"], reverse=True)[0]})
    return out


result = {"period": {"camera_start": observations[0]["captured"].isoformat(" "),
                     "camera_end": observations[-1]["captured"].isoformat(" "),
                     "forecast_first_issue": min(f["issued"] for f in forecasts).isoformat(" ")},
          "observations": {"n": len(observations), "codes": dict(Counter(o["code"] for o in observations)),
                           "fog": sum(o["fog"] for o in observations)}, "cohorts": {}}

for cohort in ("latest", "morning", "previous_evening"):
    rows = joined(cohort)
    labels = [r["fog"] for r in rows]
    metrics = {}
    for field in ("cl_bm", "cl_ec", "cl_avg"):
        scores = [r[field] for r in rows]
        metrics[field] = {"n": sum(s is not None for s in scores),
                          "pearson_with_far": pearson(scores, [r["far"] for r in rows]),
                          "spearman_with_far": spearman(scores, [r["far"] for r in rows]),
                          "pearson_with_fog": pearson(scores, labels),
                          "auc_fog": auc(scores, labels),
                          "threshold_30": confusion(rows, field, 30),
                          "threshold_50": confusion(rows, field, 50)}
    metrics["vis_bm"] = {"pearson_with_far": pearson([r["vis_bm"] for r in rows], [r["far"] for r in rows]),
                         "spearman_with_far": spearman([r["vis_bm"] for r in rows], [r["far"] for r in rows]),
                         "auc_fog": auc([-r["vis_bm"] if r["vis_bm"] is not None else None for r in rows], labels)}
    for field in ("v_bm", "v_ec"):
        scores = [r[field] for r in rows]
        actual = [r["actual_v"] for r in rows]
        metrics[field] = {"n": sum(s is not None for s in scores),
                          "pearson_with_far": pearson(scores, [r["far"] for r in rows]),
                          "spearman_with_far": spearman(scores, [r["far"] for r in rows]),
                          "pearson_with_actual_v": pearson(scores, actual),
                          "spearman_with_actual_v": spearman(scores, actual),
                          "mae_actual_v": mean_absolute_error(scores, actual),
                          "auc_fog": auc([-s if s is not None else None for s in scores], labels),
                          "mean_by_code": {code: (sum(r[field] for r in rows if r["code"] == code and r[field] is not None) /
                                                  sum(1 for r in rows if r["code"] == code and r[field] is not None))
                                           if any(r["code"] == code and r[field] is not None for r in rows) else None
                                           for code in ("D", "B", "H", "C")}}
    result["cohorts"][cohort] = {"n": len(rows), "start": min((r["target"].isoformat(" ") for r in rows), default=None),
                                  "end": max((r["target"].isoformat(" ") for r in rows), default=None),
                                  "fog": sum(labels), "clear": len(rows)-sum(labels), "metrics": metrics,
                                  "rows": [{k: (v.isoformat(" ") if isinstance(v, datetime) else v) for k, v in r.items()
                                            if k in ("captured","target","issued","lead_h","code","actual_v","fog","far","cl_bm","cl_ec","cl_avg","v_bm","v_ec","vis_bm")} for r in rows]}

print(json.dumps(result, ensure_ascii=False, indent=2))
