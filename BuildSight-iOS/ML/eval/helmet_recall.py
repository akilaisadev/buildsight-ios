"""Scores helmet detection against hand-labelled photos (YOLO label files).

  ./eval-runner ML/models/PPEDetectorV2.mlpackage photos/ > predictions.jsonl
  python3 ML/eval/helmet_recall.py predictions.jsonl labels/ --class-index 3 --label helmet

predictions.jsonl comes from EvalRunner. labels/ holds one <photo name>.txt per photo in YOLO format
("class cx cy w h", all 0..1). --class-index is the helmet class number in YOUR labels and --label is
the matching name in the predictions (helmet, noHelmet, vest, gloves, noGloves).

Prints recall (helmets found), precision (boxes that were right) and AP@0.5. Use photos the model has
NOT been trained on: scores on training photos are inflated and tell you nothing about new sites.
"""
import argparse, collections, json, os

def load_labels(folder, stem, class_index):
    path = os.path.join(folder, stem + ".txt")
    boxes = []
    if os.path.exists(path):
        for line in open(path):
            parts = line.split()
            if len(parts) >= 5 and int(parts[0]) == class_index:
                cx, cy, w, h = map(float, parts[1:5])
                boxes.append((cx - w / 2, cy - h / 2, w, h))
    return boxes

def iou(a, b):
    ix = max(0, min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]))
    iy = max(0, min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]))
    inter = ix * iy
    union = a[2] * a[3] + b[2] * b[3] - inter
    return inter / union if union > 0 else 0

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("predictions"); ap.add_argument("labels")
    ap.add_argument("--class-index", type=int, required=True); ap.add_argument("--label", default="helmet")
    ap.add_argument("--min-score", type=float, default=0.0)
    a = ap.parse_args()

    dets, total = [], 0
    for line in open(a.predictions):
        r = json.loads(line)
        stem = os.path.splitext(r["image"])[0]
        total += len(load_labels(a.labels, stem, a.class_index))
        dets += [(o["score"], stem, (o["x"], o["y"], o["w"], o["h"])) for o in r["observations"] if o["label"] == a.label and o["score"] >= a.min_score]
    if total == 0: raise SystemExit("No ground-truth boxes for that class index. Check --class-index and the labels folder.")
    dets.sort(reverse=True)
    used, hits = collections.defaultdict(set), []
    for score, stem, box in dets:
        best, which = 0, -1
        for i, g in enumerate(load_labels(a.labels, stem, a.class_index)):
            v = iou(box, g)
            if v > best and i not in used[stem]: best, which = v, i
        if best >= 0.5: used[stem].add(which); hits.append(1)
        else: hits.append(0)
    cum, prec, rec = 0, [], []
    for i, h in enumerate(hits, 1):
        cum += h; prec.append(cum / i); rec.append(cum / total)
    ap_value, prev = 0.0, 0.0
    for i in range(len(hits)):
        ap_value += max(prec[i:]) * (rec[i] - prev); prev = rec[i]
    found = sum(hits)
    print(f"labelled: {total}   found: {found} ({100 * found / total:.0f}% recall)   boxes drawn: {len(hits)} ({100 * found / max(len(hits), 1):.0f}% right)   AP@0.5: {ap_value:.2f}")

if __name__ == "__main__":
    main()
