"""Download the candidate helmet checkpoint and convert it to Core ML.

Run inside an isolated virtualenv (see ML/README.md). The checkpoint is a
PyTorch pickle, so only load it from a source you have decided to trust, and
never in your main Python environment.

    python convert_helmet_model.py --out ../models

Writes HelmetDetector.mlpackage plus provenance.json (source, sha256, versions)
so the exact artefact that ships can be traced in the report.
"""
import argparse, hashlib, json, platform, shutil
from pathlib import Path

REPO = "keremberke/yolov8n-hard-hat-detection"
REVISION = "main"          # replaced by the resolved commit hash below
FILENAME = "best.pt"

def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--imgsz", type=int, default=640)
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    from huggingface_hub import HfApi, hf_hub_download
    info = HfApi().model_info(REPO, revision=REVISION)
    commit = info.sha
    weights = Path(hf_hub_download(REPO, FILENAME, revision=commit))
    digest = sha256(weights)
    print("checkpoint", weights, "sha256", digest, "commit", commit)

    import coremltools, torch, ultralytics
    from ultralytics import YOLO
    model = YOLO(str(weights))
    print("classes:", model.names)

    # nms=True bakes non-maximum suppression into the Core ML pipeline so Vision
    # returns VNRecognizedObjectObservation boxes directly.
    exported = Path(model.export(format="coreml", imgsz=args.imgsz, nms=True))
    target = args.out / "HelmetDetector.mlpackage"
    if target.exists():
        shutil.rmtree(target)
    shutil.move(str(exported), str(target))

    (args.out / "provenance.json").write_text(json.dumps({
        "source_repo": REPO, "source_commit": commit, "checkpoint_file": FILENAME,
        "checkpoint_sha256": digest, "classes": model.names, "imgsz": args.imgsz,
        "converter": {"ultralytics": ultralytics.__version__, "coremltools": coremltools.__version__,
                      "torch": torch.__version__, "python": platform.python_version()},
        "licence_status": "UNRESOLVED: repository declares no licence; YOLOv8 code is AGPL-3.0; "
                          "dataset licence must be checked on Roboflow Universe before redistribution.",
    }, indent=2))
    print("wrote", target)

if __name__ == "__main__":
    main()
