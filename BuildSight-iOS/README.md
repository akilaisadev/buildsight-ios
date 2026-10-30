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
4. **Real iPhone or iPad:** copy `Config/Signing.xcconfig.example` to `Config/Signing.xcconfig` and set `DEVELOPMENT_TEAM` to your team ID (and `BUILDSIGHT_BUNDLE_ID` if `com.buildsight99.app` is taken on your team). Use the **BuildSight** scheme (not BuildSightWidgets), select the device, press Cmd+R, then trust your developer profile on the device (Settings > General > VPN & Device Management; also enable Developer Mode).
5. **Helmet model (optional):** put `PPEDetector.mlpackage` (and optionally `HelmetDetector.mlpackage`) in `ML/models/` and build. A build phase (`scripts/bundle_models.sh`) compiles them into the app; without them the app still works and Settings says no model is installed. Never commit them (licence).
6. Backend setup from scratch: [docs/BACKEND_SETUP.md](docs/BACKEND_SETUP.md). Tests: `cd Packages/BuildSightKit && swift test`.

## Helmet model

`ML/models/` holds a Core ML conversion of `keremberke/yolov8n-hard-hat-detection` (classes `Hardhat`, `NO-Hardhat`). **Its licence is unresolved**, so it is git-ignored and must not be redistributed until you decide it is acceptable (see [docs/HELMET_MODEL_FEASIBILITY.md](docs/HELMET_MODEL_FEASIBILITY.md)). **Accuracy has not been measured**: no evaluation images have been run. Without the model the app builds and reports "no helmet model installed".

Scope is **helmets only**. Vests, harnesses and gloves from the proposal are future work.

## Features

Auth (sign-in/out, reset, Keychain session, Face ID gate, expiry) · projects and dashboard · camera evidence with GPS/area/timestamp · issues with lifecycle, roles, audit history · inspections with checklists and stop-work flag · tasks · timeline · MapKit control tower · in-app notifications and local reminders · Sync Center · helmet detection with human review · widget · QR area scanning (stretch) · iPad split-view supervision layout.
