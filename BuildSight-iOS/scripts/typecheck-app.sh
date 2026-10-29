#!/bin/zsh
# Type-checks the SwiftUI app sources against the macOS SDK (with a small shim)
# as a development aid when Xcode is unavailable. iOS-only files (camera, QR,
# Keychain, LocalAuthentication, widgets) are excluded; they need the iOS SDK.
cd "$(dirname "$0")/.."
OUT=/tmp/bsk
swiftc -typecheck -parse-as-library -I $OUT -module-name BuildSightApp \
  scripts/macos-typecheck-shim.swift \
  $(find BuildSight/App BuildSight/Shared BuildSight/Features -name '*.swift') \
  BuildSight/Services/LocationService.swift BuildSight/Services/ConnectivityMonitor.swift BuildSight/Services/NotificationScheduler.swift BuildSight/Services/SyncCoordinator.swift BuildSight/Services/KeychainSessionStore.swift BuildSight/Services/BiometricService.swift \
  -vfsoverlay $OUT/vfs.yaml -Xcc -ivfsoverlay -Xcc $OUT/vfs.yaml 2>&1 | grep -E "error:" | sed "s|$PWD/||" | sort -u
