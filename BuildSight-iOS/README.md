# BuildSight (native iOS)

Construction-site field intelligence: every photo, issue, inspection and task carries its project, site area, time, GPS (when available) and author, and an on-device model flags possible missing helmets for a person to review and reports vests and gloves it can see.

The React prototype in the repository root is untouched. This directory is the native SwiftUI app.

> **Status: simulator build and launch verified.** The iOS app builds with Xcode 16.2, launches on an iPhone 16 simulator, and the shared package passes 151 tests. Device hardware and signed-in workflows still need hands-on verification. See [docs/KNOWN_LIMITATIONS.md](docs/KNOWN_LIMITATIONS.md).

## Layout

| Path | What it is |
|---|---|
| `Packages/BuildSightKit` | Swift package: domain model, rules, view models, repositories, Core Data store, sync engine, REST client, helmet interpretation and Core ML/Vision analyser. No UIKit; builds and tests on macOS. |
| `BuildSight/` | The iOS app target: SwiftUI views, hardware services (camera, location, Keychain, Face ID, QR, notifications), composition root. |
| `Widgets/` | WidgetKit extension (helmet-flag summary + deep link). |
| `Backend/supabase/schema.sql` | PostgreSQL schema with row-level security and the `upsert_record` function. |
| `ML/` | Model conversion script, provenance, evaluation runner and metrics. |
| `docs/` | Requirement matrix, design decisions, viva prep, submission checklists. |
| `scripts/` | `run-kit-tests.sh`, `typecheck-app.sh`. |

## Architecture (MVVM)

```
View (SwiftUI)  →  ViewModel (@Observable, @MainActor)  →  Repository / Workflow  →  LocalStore (Core Data)  →  SyncEngine  →  RemoteBackend (REST)
                                     │                              │
                                     └── Rules (pure functions) ◄───┘   LocationProviding, EvidenceFileStoring, HelmetAnalyzing… (protocols, injected)
```

- **Rules** (`IssueWorkflow`, `InspectionRules`, `TaskScheduling`, `HelmetInterpreter`, `SafetyIssueFactory`) are pure and own every business decision. Views never contain them.
- **Local-first:** every change is committed to Core Data together with its queue entry in one save. The UI never waits on the network.
- **One snapshot per project** (`ProjectSnapshot`) feeds dashboard, lists, map and timeline, so their counts cannot disagree.
- **Per-account storage:** each account has its own SQLite file and evidence folder.

## Setup

1. Install Xcode 16+ (`./scripts/bootstrap.sh` installs XcodeGen and generates the project if you edit `project.yml`).
2. Open `BuildSight.xcodeproj`. The backend URL and publishable key are committed in `Config/Backend.xcconfig`, so a fresh clone connects without any file to create. To use a different backend, copy `Config/Secrets.xcconfig.example` to `Config/Secrets.xcconfig` (git-ignored; it overrides).
3. **Simulator:** pick an iPhone or iPad simulator and press Cmd+R. No signing needed.
4. **Real iPhone or iPad:** run `./scripts/setup_signing.sh` once. It writes `Config/Signing.xcconfig` (git-ignored) with your team ID and a bundle id unique to you (`com.buildsight.<your account name>`), so Apple never says the bundle id or app group is "not available". If it cannot find your team, pass it: `./scripts/setup_signing.sh YOURTEAMID` (Xcode > Settings > Accounts). Do **not** type a bundle id into Xcode's Signing screen; the config file owns it. Then use the **BuildSight** scheme (not BuildSightWidgets), select the device, press Cmd+R, and trust your developer profile on the device (Settings > General > VPN & Device Management; also enable Developer Mode).
   - Already hit "Application Group ... is not available"? `git checkout -- BuildSight.xcodeproj && git pull`, run the script above, then Product > Clean Build Folder.
5. **Helmet model:** `ML/models/PPEDetector.mlpackage` (and the helmet-only `HelmetDetector.mlpackage`) are committed, and a build phase (`scripts/bundle_models.sh`) compiles them into the app, so every build includes them. If a build ever says "No helmet model is installed", the folder is missing them: `git pull`, or `git checkout -- ML/models`.
6. **"Missing package product BuildSightKit" or other odd Xcode errors after a pull:** quit Xcode and run `./scripts/reset_xcode.sh`, then open the project again.
7. Backend setup from scratch: [docs/BACKEND_SETUP.md](docs/BACKEND_SETUP.md). Tests: `cd Packages/BuildSightKit && swift test`.

## Backend access for markers

The app talks to a hosted Supabase project, so nothing has to be installed or created to run it.

- **Backend URL and key:** committed in `Config/Backend.xcconfig` (the project URL and the *publishable* key, which is designed to ship inside an app). A fresh clone connects with no extra file. No secret key is in this repository.
- **Test account:** sign in with `test@gmail.com` / `test@123`. It belongs to the demo project, so photos, issues, inspections and tasks can be created and will sync.
- **Sign-ups are off.** Only accounts the owner adds can sign in, so a marker should use the test account above.
- **How data reaches the backend:** every change is saved on the device first (Core Data) and put in a sync queue. When the phone is online, the queue is sent to the server through one function, `upsert_record()`. It checks the user's role and project membership, ignores repeats, and rejects stale versions so the app can merge them. Photos go to a private `evidence` storage bucket. The **Sync** screen shows what is waiting, and a discarded change is undone locally and never sent.
- **Row-level security:** the app cannot write the tables directly. The rules are in `Backend/supabase/schema.sql` and are tested by `Backend/supabase/test_schema.sh`.
- **Checking it yourself:** sign in, capture a photo, then open the Site Log. Turn on airplane mode, add another item, then turn it off and watch the Sync screen send it.

## Helmet model

`ML/models/` holds the Core ML models. `HelmetDetector` (helmet-only) decides whether a head has a helmet; `PPEDetector` / `PPEDetectorV2` report the vests and gloves they can see. The app combines them on the phone (`CompositeHelmetAnalyzer`), and a person always reviews a flag before it counts. **The licences of the model weights are unresolved**, so they are included for coursework only and must not be published or redistributed (see [docs/HELMET_MODEL_FEASIBILITY.md](docs/HELMET_MODEL_FEASIBILITY.md)).

Accuracy can be scored on labelled photos with `ML/eval/helmet_recall.py`. The models may have seen similar pictures in training, so accuracy on a real site could be lower than the test photos show. Without the models the app still builds and says "no helmet model installed".

## Features

Auth (sign-in/out, reset, Keychain session, Face ID gate, expiry) · projects and dashboard · camera evidence with GPS/area/timestamp · issues with lifecycle, roles, audit history · inspections with checklists and stop-work flag · tasks · timeline · MapKit control tower · in-app notifications and local reminders · Sync Center · helmet detection with human review · widget · QR area scanning (stretch) · iPad split-view supervision layout.
