"""Detection metrics for the helmet model, kept apart from the Swift code.

Inputs
  predictions.jsonl  one line per image from EvalRunner (raw observations, ms)
  labels/            YOLO txt labels (class cx cy w h, normalised), one per image;
                     class 0 = Hardhat, 1 = NO-Hardhat. An empty or missing file
                     means "no annotated heads" (a true negative image).

Outputs (JSON): per-class AP@0.5 and precision/recall/F1 at the app's flag
threshold, false-positive and false-negative counts, and latency statistics.
Scores are raw model confidences, NOT calibrated probabilities.

    python ml_metrics.py predictions.jsonl labels/ --flag-score 0.5
"""
import argparse, json, statistics, sys
from pathlib import Path

CLASSES = {"helmet": 0, "noHelmet": 1}

def iou(a, b):
    ax2, ay2, bx2, by2 = a[0] + a[2], a[1] + a[3], b[0] + b[2], b[1] + b[3]
    iw = max(0.0, min(ax2, bx2) - max(a[0], b[0])); ih = max(0.0, min(ay2, by2) - max(a[1], b[1]))
    inter = iw * ih
    union = a[2] * a[3] + b[2] * b[3] - inter
    return inter / union if union > 0 else 0.0

def load_gt(path: Path):
    boxes = []
    if path.exists():
        for line in path.read_text().split("\n"):
            p = line.split()
            if len(p) == 5:
                c, cx, cy, w, h = int(p[0]), *map(float, p[1:])
                boxes.append((c, (cx - w / 2, cy - h / 2, w, h)))
    return boxes

def match(preds, gts, thr):
    """Greedy match by score; returns list of (pred, matched_gt_index or None)."""
    used, out = set(), []
    for p in sorted(preds, key=lambda x: -x["score"]):
        best, best_i = 0.0, None
        for i, (_, gbox) in enumerate(gts):
            if i in used: continue
            v = iou((p["x"], p["y"], p["w"], p["h"]), gbox)
            if v > best: best, best_i = v, i
        if best_i is not None and best >= thr:
            used.add(best_i); out.append((p, best_i))
        else:
            out.append((p, None))
    return out

def average_precision(records, n_gt):
    """records: list of (score, is_tp). All-point interpolated AP."""
    if n_gt == 0: return None
    records.sort(key=lambda r: -r[0])
    tp = fp = 0; prec, rec = [], []
    for _, ok in records:
        tp += ok; fp += not ok
        prec.append(tp / (tp + fp)); rec.append(tp / n_gt)
    mrec, mpre = [0.0] + rec + [1.0], [0.0] + prec + [0.0]
    for i in range(len(mpre) - 2, -1, -1): mpre[i] = max(mpre[i], mpre[i + 1])
    return sum((mrec[i + 1] - mrec[i]) * mpre[i + 1] for i in range(len(mrec) - 1))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("predictions", type=Path); ap.add_argument("labels", type=Path)
    ap.add_argument("--flag-score", type=float, default=0.5); ap.add_argument("--iou", type=float, default=0.5)
    a = ap.parse_args()

    rows = [json.loads(l) for l in a.predictions.read_text().splitlines() if l.strip()]
    per = {c: {"recs": [], "gt": 0} for c in CLASSES.values()}
    at_flag = {c: {"tp": 0, "fp": 0, "fn": 0} for c in CLASSES.values()}
    empty_scene_false_flags = 0; empty_scenes = 0
    for r in rows:
        gts = load_gt(a.labels / (Path(r["image"]).stem + ".txt"))
        if not gts:
            empty_scenes += 1
            if any(o["label"] == "noHelmet" and o["score"] >= a.flag_score for o in r["observations"]): empty_scene_false_flags += 1
        for c in CLASSES.values():
            g = [x for x in gts if x[0] == c]; per[c]["gt"] += len(g)
            preds = [o for o in r["observations"] if CLASSES[o["label"]] == c]
            m = match(preds, g, a.iou)
            per[c]["recs"] += [(p["score"], idx is not None) for p, idx in m]
            kept = [(p, idx) for p, idx in m if p["score"] >= a.flag_score]
            at_flag[c]["tp"] += sum(idx is not None for _, idx in kept)
            at_flag[c]["fp"] += sum(idx is None for _, idx in kept)
            at_flag[c]["fn"] += len(g) - len({idx for _, idx in kept if idx is not None})

    names = {v: k for k, v in CLASSES.items()}
    report = {"images": len(rows), "iou": a.iou, "flag_score": a.flag_score, "classes": {}}
    for c, d in per.items():
        t = at_flag[c]
        p = t["tp"] / (t["tp"] + t["fp"]) if t["tp"] + t["fp"] else None
        r_ = t["tp"] / (t["tp"] + t["fn"]) if t["tp"] + t["fn"] else None
        f1 = 2 * p * r_ / (p + r_) if p and r_ else None
        report["classes"][names[c]] = {"ground_truth": d["gt"], "ap50": average_precision(d["recs"], d["gt"]), **t, "precision": p, "recall": r_, "f1": f1}
    report["empty_scenes"] = {"images": empty_scenes, "falsely_flagged_missing_helmet": empty_scene_false_flags}
    ms = [r["ms"] for r in rows]
    if ms:
        s = sorted(ms)
        report["latency_ms"] = {"median": statistics.median(ms), "p95": s[min(len(s) - 1, int(0.95 * len(s)))], "max": s[-1],
                                "note": "Measured on the machine that ran EvalRunner; NOT a phone measurement unless run on one."}
    json.dump(report, sys.stdout, indent=2); print()

if __name__ == "__main__":
    main()
