# Viva preparation

Be able to open and explain any of these without notes:
- **Capture → issue flow:** `CaptureViewModel.saveAndAnalyse` → `HelmetWorkflow.analyse` → `HelmetInterpreter.interpret` → `SafetyIssueFactory.makeIssue` → one `store.commit`. Why the photo is saved first.
- **Why `NO-Hardhat` is a class** and why "no helmet detected" ≠ violation. What `unableToAssess` covers.
- **Sync:** `SyncEngine.drain`, idempotency key, backoff, conflict merge, partial upload resume. Walk through "airplane mode → capture → reconnect".
- **Core Data:** why payload + indexed columns; what `commit` guarantees; per-account store files.
- **Auth:** `SessionManager` states; why biometrics cannot restore an expired session.
- **Rules:** issue transition table, verifier ≠ resolver, task buckets (overdue = due instant passed).
- **MapKit:** only GPS-backed records get pins; approximate rings; tasks via related issue.
- **Honest limits:** unmeasured accuracy, unresolved model licence, no remote push, not yet built in Xcode (say what you verified and how).

Likely live questions: add a field to `Issue` (what changes?); why `@MainActor @Observable`; what happens if two devices edit one issue offline; how would you add vest detection (new classes + label map + policy, interpretation per head); what breaks if `upsert_record` is called twice.

AI-use honesty: you must be able to explain every file yourself. Read each file once and rewrite one small piece (e.g. `TaskScheduling.bucket`) from memory.
