"""Train a multi-class PPE detector (helmet, no-helmet, vest, no-vest, gloves).

Meant to run in Google Colab with a GPU. Merges two CC BY 4.0 Roboflow datasets
mirrored on Hugging Face:
  keremberke/hard-hat-detection              hardhat, no-hardhat   (19,745 imgs)
  keremberke/construction-safety-object-detection  + vest, no-vest, gloves ... (398 imgs)

Known limitation (also in the report): the hard-hat images were never labelled
for vests/gloves, so unlabelled vests there count as background. That lowers
vest/glove recall; the safety set is oversampled to compensate. There is NO
harness class and NO "no-gloves" class in any data used here.

Every number printed at the end comes from the datasets' own held-out TEST
splits, which are never used for training or model selection.
"""
import json, os, random, shutil, subprocess, sys, zipfile
from pathlib import Path
from urllib.request import urlretrieve

HF = "https://huggingface.co/datasets/keremberke/{}/resolve/main/data/{}.zip"
# (dataset, split) -> unified class names. Source names are lower-cased first.
CLASSES = ["hardhat", "no-hardhat", "safety vest", "no-safety vest", "gloves"]
ALIASES = {"hardhat": "hardhat", "no-hardhat": "no-hardhat", "safety vest": "safety vest",
           "no-safety vest": "no-safety vest", "gloves": "gloves"}
WORK = Path(os.environ.get("PPE_WORK", "/content/ppe"))
HARDHAT_TRAIN_CAP = int(os.environ.get("HARDHAT_TRAIN_CAP", "4000"))
SAFETY_OVERSAMPLE = int(os.environ.get("SAFETY_OVERSAMPLE", "5"))
random.seed(0)


def fetch(dataset: str, split: str) -> Path:
    out = WORK / "raw" / dataset / split
    if out.exists():
        return out
    out.parent.mkdir(parents=True, exist_ok=True)
    z = out.parent / f"{split}.zip"
    urlretrieve(HF.format(dataset, split), z)
    with zipfile.ZipFile(z) as f:
        f.extractall(out)
    z.unlink()
    return out


def coco_to_yolo(folder: Path, dest_img: Path, dest_lbl: Path, prefix: str, limit=None, repeat=1) -> int:
    """Converts one COCO split to YOLO txt with the unified class ids.
    Images whose labels are all outside CLASSES are kept as background."""
    coco = json.loads((folder / "_annotations.coco.json").read_text())
    names = {c["id"]: c["name"].lower().strip() for c in coco["categories"]}
    by_image = {}
    for a in coco["annotations"]:
        by_image.setdefault(a["image_id"], []).append(a)
    images = [im for im in coco["images"] if (folder / im["file_name"]).exists()]
    if limit:
        random.shuffle(images)
        images = images[:limit]
    dest_img.mkdir(parents=True, exist_ok=True)
    dest_lbl.mkdir(parents=True, exist_ok=True)
    n = 0
    for im in images:
        W, H = im["width"], im["height"]
        lines = []
        for a in by_image.get(im["id"], []):
            unified = ALIASES.get(names.get(a["category_id"], ""))
            if unified is None:
                continue
            x, y, w, h = a["bbox"]
            if w <= 1 or h <= 1:
                continue
            cx, cy = (x + w / 2) / W, (y + h / 2) / H
            lines.append(f"{CLASSES.index(unified)} {cx:.6f} {cy:.6f} {w / W:.6f} {h / H:.6f}")
        for r in range(repeat):
            stem = f"{prefix}{r}_{Path(im['file_name']).stem}"
            shutil.copy(folder / im["file_name"], dest_img / f"{stem}{Path(im['file_name']).suffix}")
            (dest_lbl / f"{stem}.txt").write_text("\n".join(lines))
            n += 1
    return n


def build_dataset() -> Path:
    root = WORK / "yolo"
    if root.exists():
        shutil.rmtree(root)
    counts = {}
    for split, hf_split, cap, rep in [("train", "train", HARDHAT_TRAIN_CAP, 1), ("val", "valid", None, 1), ("test", "test", None, 1)]:
        counts[f"hardhat-{split}"] = coco_to_yolo(fetch("hard-hat-detection", hf_split), root / split / "images", root / split / "labels", "hh", limit=cap, repeat=rep)
    for split, hf_split, rep in [("train", "train", SAFETY_OVERSAMPLE), ("val", "valid", 1), ("test", "test", 1)]:
        counts[f"safety-{split}"] = coco_to_yolo(fetch("construction-safety-object-detection", hf_split), root / split / "images", root / split / "labels", "cs", repeat=rep)
    (root / "data.yaml").write_text(
        f"path: {root}\ntrain: train/images\nval: val/images\ntest: test/images\nnames:\n"
        + "".join(f"  {i}: {n}\n" for i, n in enumerate(CLASSES)))
    print("dataset counts", counts)
    return root / "data.yaml"


def main():
    subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", "ultralytics", "coremltools"])
    from ultralytics import YOLO
    data = build_dataset()
    model = YOLO("yolov8s.pt")
    model.train(data=str(data), epochs=int(os.environ.get("EPOCHS", "40")), imgsz=640, batch=32, project=str(WORK / "runs"), name="ppe", exist_ok=True, patience=10, workers=2, plots=False)
    best = YOLO(str(WORK / "runs/ppe/weights/best.pt"))
    metrics = best.val(data=str(data), split="test", imgsz=640, project=str(WORK / "runs"), name="test", exist_ok=True)
    report = {"classes": CLASSES, "test_map50": float(metrics.box.map50), "test_map50_95": float(metrics.box.map),
              "per_class": {CLASSES[int(i)]: {"precision": float(metrics.box.p[k]), "recall": float(metrics.box.r[k]), "ap50": float(metrics.box.ap50[k])}
                            for k, i in enumerate(metrics.box.ap_class_index)}}
    (WORK / "test_metrics.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    best.export(format="coreml", imgsz=640, nms=True)
    out = WORK / "runs/ppe/weights/best.mlpackage"
    shutil.make_archive(str(WORK / "PPEDetector"), "zip", out.parent, out.name)
    print("exported", WORK / "PPEDetector.zip")


if __name__ == "__main__":
    main()
