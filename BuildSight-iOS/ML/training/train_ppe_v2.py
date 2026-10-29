"""Train a 5-class PPE detector: helmet, no-helmet, vest, gloves, no-gloves.

Runs in Google Colab (GPU). Uses two datasets already extracted under /content/d:
  cppe   Ultralytics Construction-PPE (1,416 imgs, licence stated as AGPL-3.0).
         Only source with no_helmet and no_gloves labels.
  k      Roboflow "ppe-detection_data-adcya" v3 via Hugging Face Mr-Kamal/PPE_Detection
         (CC BY 4.0; 8,774 / 2,070 / 1,234 imgs). Gives helmet, vest, gloves volume.

Class mapping (everything else is dropped, so those objects count as background):
  cppe: helmet0 gloves1 vest2 no_helmet7 no_gloves9   (boots, goggles, none, Person, no_goggle, no_boots dropped)
  k:    Gloves0 Vest1 helmet3                          (goggles, mask, safety_shoe dropped)

Known limitations, repeated in the report:
  * No "no-vest" class: a vest that is not found is NOT a violation.
  * The k set has no "no-*" classes, so bare hands/heads there are unlabelled.
    Because of that, "no-*" precision is only meaningful on the cppe test split.
  * Test splits come from the same sources as training; they do not prove
    performance on phone photos taken on a real site.
"""
import json, os, random, shutil, subprocess, sys
from pathlib import Path

CLASSES = ["helmet", "no-helmet", "vest", "gloves", "no-gloves"]
CPPE_MAP = {0: 0, 7: 1, 2: 2, 1: 3, 9: 4}
K_MAP = {3: 0, 1: 2, 0: 3}
CPPE_ROOT, K_ROOT = Path("/content/d/cppe"), Path("/content/d/k")
WORK = Path(os.environ.get("PPE_WORK", "/content/ppe2"))
K_TRAIN_CAP = int(os.environ.get("K_TRAIN_CAP", "5000"))
K_VAL_CAP = int(os.environ.get("K_VAL_CAP", "600"))
CPPE_REPEAT = int(os.environ.get("CPPE_REPEAT", "3"))
random.seed(0)


def remap(label_file: Path, mapping: dict) -> list:
    out = []
    if label_file.exists():
        for line in label_file.read_text().splitlines():
            p = line.split()
            if len(p) >= 5 and p[0].isdigit() and int(p[0]) in mapping:
                out.append(" ".join([str(mapping[int(p[0])])] + p[1:]))
    return out


def copy_split(img_dir: Path, lbl_dir: Path, mapping, dest: Path, prefix: str, limit=None, repeat=1) -> int:
    imgs = sorted(p for p in img_dir.iterdir() if p.suffix.lower() in (".jpg", ".jpeg", ".png"))
    if limit:
        random.shuffle(imgs)
        imgs = imgs[:limit]
    (dest / "images").mkdir(parents=True, exist_ok=True)
    (dest / "labels").mkdir(parents=True, exist_ok=True)
    n = 0
    for im in imgs:
        lines = remap(lbl_dir / f"{im.stem}.txt", mapping)
        for r in range(repeat):
            stem = f"{prefix}{r}_{im.stem}"
            shutil.copy(im, dest / "images" / f"{stem}{im.suffix}")
            (dest / "labels" / f"{stem}.txt").write_text("\n".join(lines))
            n += 1
    return n


def write_yaml(root: Path, name: str, val: str, test: str) -> Path:
    y = root / name
    y.write_text(f"path: {root}\ntrain: train/images\nval: {val}/images\ntest: {test}/images\nnames:\n"
                 + "".join(f"  {i}: {n}\n" for i, n in enumerate(CLASSES)))
    return y


def build() -> Path:
    root = WORK / "yolo"
    if root.exists():
        shutil.rmtree(root)
    c = {}
    c["train-cppe"] = copy_split(CPPE_ROOT / "images/train", CPPE_ROOT / "labels/train", CPPE_MAP, root / "train", "c", repeat=CPPE_REPEAT)
    c["train-k"] = copy_split(K_ROOT / "train/images", K_ROOT / "train/labels", K_MAP, root / "train", "k", limit=K_TRAIN_CAP)
    c["val-cppe"] = copy_split(CPPE_ROOT / "images/val", CPPE_ROOT / "labels/val", CPPE_MAP, root / "val", "c")
    c["val-k"] = copy_split(K_ROOT / "valid/images", K_ROOT / "valid/labels", K_MAP, root / "val", "k", limit=K_VAL_CAP)
    c["test-cppe"] = copy_split(CPPE_ROOT / "images/test", CPPE_ROOT / "labels/test", CPPE_MAP, root / "test_cppe", "c")
    c["test-k"] = copy_split(K_ROOT / "test/images", K_ROOT / "test/labels", K_MAP, root / "test_k", "k")
    # Count boxes per class in what training will actually see.
    for split in ("train", "val", "test_cppe", "test_k"):
        h = {n: 0 for n in CLASSES}
        for f in (root / split / "labels").glob("*.txt"):
            for line in f.read_text().splitlines():
                if line.strip():
                    h[CLASSES[int(line.split()[0])]] += 1
        print("boxes", split, h)
    print("image counts", c)
    write_yaml(root, "data.yaml", "val", "test_cppe")
    write_yaml(root, "data_cppe.yaml", "val", "test_cppe")
    write_yaml(root, "data_k.yaml", "val", "test_k")
    return root


def evaluate(best, yaml: Path, tag: str) -> dict:
    m = best.val(data=str(yaml), split="test", imgsz=640, project=str(WORK / "runs"), name=f"test_{tag}", exist_ok=True)
    per = {CLASSES[int(i)]: {"precision": float(m.box.p[k]), "recall": float(m.box.r[k]), "ap50": float(m.box.ap50[k])}
           for k, i in enumerate(m.box.ap_class_index)}
    return {"map50": float(m.box.map50), "map50_95": float(m.box.map), "per_class": per}


def main():
    subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", "ultralytics", "coremltools"])
    from ultralytics import YOLO
    root = build()
    model = YOLO("yolov8s.pt")
    model.train(data=str(root / "data.yaml"), epochs=int(os.environ.get("EPOCHS", "30")), imgsz=640, batch=32,
                project=str(WORK / "runs"), name="ppe", exist_ok=True, patience=8, workers=2, plots=False)
    best = YOLO(str(WORK / "runs/ppe/weights/best.pt"))
    report = {"classes": CLASSES,
              "test_cppe_all_classes": evaluate(best, root / "data_cppe.yaml", "cppe"),
              "test_k_helmet_vest_gloves_only": evaluate(best, root / "data_k.yaml", "k")}
    (WORK / "test_metrics.json").write_text(json.dumps(report, indent=2))
    print("REPORT_BEGIN"); print(json.dumps(report, indent=2)); print("REPORT_END")
    best.export(format="coreml", imgsz=640, nms=True)
    out = WORK / "runs/ppe/weights/best.mlpackage"
    shutil.make_archive(str(WORK / "PPEDetector"), "zip", out.parent, out.name)
    print("exported", WORK / "PPEDetector.zip")


if __name__ == "__main__":
    main()
