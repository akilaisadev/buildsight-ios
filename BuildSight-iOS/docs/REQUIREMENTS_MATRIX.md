# Requirement-to-evidence matrix

Status key: **Verified** = checked by a test/tool run here · **Implemented** = code written, unverified on iOS · **Planned** · **Incomplete**. No marks are guaranteed.

## Source status
- LLM rule: the original assessment sheet **prohibits** LLM-generated code. You state your lecturer has since permitted AI-assisted implementation. **Get that in writing** (email/LMS post) and cite it in the report; this repository records it only as your statement. Disclose AI use accurately.
- Lecturer approved list (your scan, Index 25.1/07 1): Auth, Settings/Profile, API, Dashboard, Push Notifications, Face ID, Site Evidence (Issue), Activity timeline & Site map, Inspection. Advanced: Core ML (note beside it: "4 … 10%"), MapKit + Core Location, third slot blank.
- MVP approval (Component 1) is **not recorded as approved here**. Confirm.

## Component 1 — Prototype & MVP approval (10%)
| Criterion (marks) | Deliverable | Acceptance | Evidence | Status | Gap / next |
|---|---|---|---|---|---|
| Problem & concept (2) | Proposal PDF | Clear problem, USP | Proposal | Planned (exists, not mine to grade) | Update proposal text for helmet-only scope |
| Features & use cases (2) | Proposal journeys | Journeys tied to features | Proposal | Planned | Add a "scope refinement" note |
| High-fidelity prototype (4) | Figma + React prototype | Full journey, HIG | Prototype links | Planned | Native screens now differ; note in report |
| Tools & scope (2) | Proposal tools table | Justified, realistic | Proposal + `docs/DESIGN_DECISIONS.md` | Planned | Record actual approval and feedback |

## Component 2 — MVP & presentation (20%)
| Criterion | Feature | Acceptance | Evidence | Status | Gap |
|---|---|---|---|---|---|
| Core functionality (8) | All approved features + two platform features | Works end to end on device | 132 logic tests; views written | Implemented / logic Verified | Build & run on device; fix compile issues |
| Mandatory pair | **Core Data + Face ID/Touch ID** (baseline) | Real persistence; gate does not replace backend auth | `CoreDataLocalStore` tests; `SessionManager` tests | Verified (logic) / Implemented (LAContext) | Device test of Face ID |
| Push Notifications | proposal commitment | Remote delivery | none | **Incomplete** (local reminders + in-app only) | Needs APNs + server; decide if claimed |
| External integration (4) | Supabase REST: auth, upsert, pull, storage | Genuine fetch/sync/persist | `RemoteClientTests` (stub) | Implemented; **not run live** | Create Supabase project, run end-to-end |
| Workflow & navigation (3) | iPhone tabs + capture; iPad split | Coherent flows | Views, router, deep links | Implemented | Device walk-through |
| Viva (5) | Own the code | Explain any file | `VIVA_PREP.md` | Planned | Rehearse |

## Component 3 — Advanced SDK (20%)
| Criterion | Feature | Acceptance | Evidence | Status | Gap |
|---|---|---|---|---|---|
| Implementation (10) | Core ML+Vision helmet pipeline → safety issue → review → map/timeline/dashboard/widget | Genuine local inference integrated in workflow | `HelmetWorkflowTests` (fake analyser), smoke inference on macOS | Implemented; model run once on blank image | **Measure on real images; device test**; resolve licence |
| | MapKit + Core Location | Pins from real data, filters, permissions | `MapProjector` tests; `SiteMapView` | Implemented, unverified | Device test; geofencing not done |
| | WidgetKit | Shared summary, deep link, freshness | `WidgetSnapshot` tests; `BuildSightWidget` | Implemented, unverified | Confirm lecturer counts it |
| Relevance (5) / Complexity (5) | Same | Tied to site safety loop | `HELMET_MODEL_FEASIBILITY.md` | Planned | Report write-up |
Do not count Core Data, Face ID or Push here, nor the basic REST integration twice.

## Component 4 — Tests, accessibility, docs (15%)
| Criterion | Evidence | Status | Gap |
|---|---|---|---|
| Coverage (3) | Issue transitions/permissions, inspection completion, task grouping, project isolation, persistence, sync failure/duplicates, interpretation, safety creation/review, auth/biometric, REST, view models | Verified (132) | No UI tests; add Dynamic Type snapshot checks |
| Quality (3) | Swift Testing, fixed clock/calendar, mutation sanity check done | Verified | Package also runs under `swift test` in Xcode (confirm) |
| Accessibility (3) | Labels, combined elements, text+icon status, 44–50 pt targets, contrast test | Implemented | **Test VoiceOver, Dynamic Type (AX5), Reduce Motion on device** |
| Inclusive design (2) | Offline-first, glove-sized targets, sunlight palette, plain language, GPS-less capture | Implemented | Document in report |
| Documentation + LO reflection (4) | README, docs, comments | Partial | Write final report; LO1–LO4 reflection from real experience |

## Component 5 — Above & beyond (25% cap)
| Criterion | Candidate evidence | Status |
|---|---|---|
| Creativity (7) | Human-in-the-loop helmet flags, deterministic dedupe ids, stop-work digital notice, transparent metrics | Implemented |
| Technical sophistication (10) | Clean MVVM + DI + protocols, local-first sync with 3-way merge, idempotent RPC, per-account stores | Verified (logic) |
| Multi-device (5) | `NavigationSplitView`-style `PadShell` with sidebar + list/detail review | Implemented; **needs iPad run + justification text** |
| Polish (4) | Empty/error states, sync states | Implemented, unverified |
| Code quality (3) | Package separation, tests | Verified (structure) |
Exceeds baseline: conflict-merging sync, deterministic dedupe, QR area scanning (stretch), blur/size gating. Claim only after device verification.

## Component 6 — Tutorial 4 (10%)
Tracked separately. Not in this project; no game modes added. Status: **unknown to me** (needs your repo/commits).
