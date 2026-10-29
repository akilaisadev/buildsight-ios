# ML assets (kept separate from app tests)

- `tools/convert_helmet_model.py` downloads the pinned checkpoint and converts it (run in an isolated virtualenv: the checkpoint is a pickle).
- `models/HelmetDetector.mlpackage`, `models/provenance.json`: converted artefact and its provenance (git-ignored: licence unresolved).
- `eval/EvalRunner.swift` runs the same `CoreMLHelmetAnalyzer` the app uses over a folder of images → `predictions.jsonl`.
- `eval/ml_metrics.py predictions.jsonl labels/` → AP@0.5, precision/recall/F1 at the app's flag threshold, false positives on empty scenes, latency.

Unit tests (`swift test`) never load the model; they exercise interpretation with synthetic observations. Model quality is reported only from `ml_metrics.py` runs on held-out images.

## Five-class PPE model
- `training/train_ppe_v2.py` trains it (Colab GPU); `training/train_ppe.py` is the earlier, failed attempt (vest/glove AP 0) kept for the record.
- `models/PPEDetector.mlpackage` and `models/provenance_ppe.json`: model (git-ignored) and its provenance, held-out test numbers and caveats.
- `eval/EvalRunner.swift` picks the PPE label map when the model file name starts with `PPE`. `eval/ml_metrics.py` still scores only the two helmet classes; extend it before using it on vest/gloves labels.
- The app prefers `PPEDetector` when bundled and falls back to `HelmetDetector` (see `project.yml`, `AppEnvironment.loadAnalyzer`).
