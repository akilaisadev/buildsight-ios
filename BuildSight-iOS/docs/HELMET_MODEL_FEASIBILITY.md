# Helmet model feasibility

## Candidate
`keremberke/yolov8n-hard-hat-detection` (Hugging Face), commit `287bafa2feb311ee45d21f9e9b33315ff6ff955d`, `best.pt` SHA-256 `05ed3a517485292d42d6eb6c9be3987ea51cd162e04807d2741eadcac8a19e6c` (5.9 MB, 3.0 M parameters).

| Check | Finding |
|---|---|
| Labels | `Hardhat`, `NO-Hardhat` (read from the checkpoint). Head-level: **missing helmet is a trained class, not the absence of a helmet box.** No `person`/`worker` class, so "which worker" is approximated by the head box. |
| Input / output | 640×640 RGB image; raw output (1, 6, 8400) = 4 box + 2 class scores. Converted with Ultralytics 8.3.40 / coremltools 7.2 / torch 2.2.2 **with NMS in the Core ML pipeline**, so Vision returns `VNRecognizedObjectObservation`. (Ultralytics 8.0.23's own NMS export failed for mlprogram; the newer exporter loaded the old checkpoint fine.) |
| Platform | Loads and runs through Vision on macOS 14 (smoke test). iOS 17 deployment target; not run on a phone. |
| Training data | Roboflow "Hard Hats" dataset, 13,782 train / 3,962 valid / 2,001 test images, **CC BY 4.0** (per the dataset card). Images are 640×640 stretched web photos. |
| Reported metric | Model card: mAP@0.5 = 0.836 on the **validation** split (the split used while training). Not independent evidence for phone photos. |
| **Licence / provenance** | **Unresolved.** The model repository declares no licence. YOLOv8 code and weights trained with it are AGPL-3.0 by default. The checkpoint is a pickle from an individual account. Do not bundle in a distributed build, and disclose all of this in the report. |

## Limitations to state
- Trained on construction-site web imagery; phone-camera perspectives, PPE colours, night scenes, distance, occlusion and partial bodies are unmeasured.
- Detects head-level helmet state only; cannot see a helmet hanging on a belt vs worn correctly (chin strap etc.).
- Class scores are raw model confidences, not calibrated probabilities. The threshold policy (`HelmetThresholdPolicy`: noise floor 0.30, flag 0.50, conflict IoU 0.5 / margin 0.15, blur and size gates) is a documented choice, **not tuned**.
- Blur gate threshold (Laplacian variance 20) is a guess until evaluated.

## Preprocessing
Upright decode (EXIF applied) capped at 1600 px → Vision `.scaleFill` to 640×640 → model → NMS in pipeline → boxes flipped from Vision's bottom-left to top-left once (`NormalizedRect(visionRect:)`, unit tested).

## Evaluation status
Tooling is ready (`ML/eval/EvalRunner.swift`, `ml_metrics.py`; the metrics script was checked on a hand-computed synthetic example). **No evaluation was run**: downloading the 114 MB test split was declined. Required to complete: held-out images covering helmets worn, absent, multiple people, none, bad light, occlusion, distance, ambiguous; real device timing. Until then, state "accuracy not measured".


## Five-class PPE model (current candidate)
Trained in this project with `ML/training/train_ppe_v2.py` on Colab (T4, 30 epochs, seed 0): YOLOv8s, classes `helmet`, `no-helmet`, `vest`, `gloves`, `no-gloves`. Data: Ultralytics Construction-PPE (licence stated AGPL-3.0; the only source of `no_helmet` and `no_gloves`) plus Roboflow `ppe-detection_data-adcya` v3 via Hugging Face `Mr-Kamal/PPE_Detection` (CC BY 4.0). Core ML export has NMS built in; zip SHA-256 `bfab6fb6c7992d39480604efe776201f0564a285be376d06b13c05d8aa431b9b`. Full provenance: `ML/models/provenance_ppe.json`.

| Held-out test | helmet | no-helmet | vest | gloves | no-gloves | mAP50 |
|---|---|---|---|---|---|---|
| Construction-PPE, 141 imgs (AP50) | 0.90 | 0.12 | 0.87 | 0.75 | 0.09 | 0.55 |
| Roboflow, 1,234 imgs, 3 classes (AP50) | 0.76 | n/a | 0.83 | 0.53 | n/a | 0.71 |

How the app uses it: heads (helmet / no-helmet) follow the existing policy and review flow; vests and gloves are reported as detected facts only; `no-gloves` is shown as an unconfirmed "possible bare hand" hint above the flag score; a vest not being found is never treated as a violation. The same raw confidence caveats apply.

Honest limits: the test splits share sources with the training data; the two "no-" classes are weak; the Roboflow set has no "no-" labels so those classes can only be scored on Construction-PPE's small test split; the model is slower or faster on a phone than on this Mac in ways not measured here. Licence is unresolved (see above).
