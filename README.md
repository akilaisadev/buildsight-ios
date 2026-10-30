# BuildSight (native iOS app)

Construction-site field evidence: every photo, issue, inspection and task carries its project, site area, time, GPS (when available) and author. An on-device model suggests possible missing helmets for a person to review, and reports vests and gloves it can see.

**All the code is in [`BuildSight-iOS/`](BuildSight-iOS/).** Start with its README:
[`BuildSight-iOS/README.md`](BuildSight-iOS/README.md) has the setup steps, what is and is not verified, and how to run the tests.

## Quick start

1. Install Xcode 16.2 or newer (iOS 17+ SDK) on a Mac.
2. Open `BuildSight-iOS/BuildSight.xcodeproj` in Xcode. (Checked: a fresh clone builds for the simulator with no setup, secrets or model files.) Run `./scripts/bootstrap.sh` only after editing `project.yml` or to add local model files.
3. Create `BuildSight-iOS/Config/Secrets.xcconfig` from `Config/Secrets.xcconfig.example` and fill in the backend URL and publishable key from the project owner (never a secret key).
4. Build and run. Sign in with a test account the owner has created.

## Not in this repository

- Your own signing settings (`Config/Signing.xcconfig`) and any private override of the backend settings (`Config/Secrets.xcconfig`). Both are git-ignored on purpose.

See [`BuildSight-iOS/docs/KNOWN_LIMITATIONS.md`](BuildSight-iOS/docs/KNOWN_LIMITATIONS.md) for what has been verified and what has not.
