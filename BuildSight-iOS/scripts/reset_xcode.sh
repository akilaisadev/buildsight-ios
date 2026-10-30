#!/bin/zsh
# Fixes "Missing package product 'BuildSightKit'" and other stale Xcode state after a pull.
# Quit Xcode first (Cmd+Q), then run: ./scripts/reset_xcode.sh
cd "$(dirname "$0")/.."
if pgrep -x Xcode >/dev/null; then echo "Quit Xcode first (Cmd+Q), then run this again."; exit 1; fi
rm -rf ~/Library/Developer/Xcode/DerivedData/BuildSight-*
rm -rf Packages/BuildSightKit/.build
rm -rf BuildSight.xcodeproj/project.xcworkspace/xcshareddata/swiftpm BuildSight.xcodeproj/project.xcworkspace/xcuserdata BuildSight.xcodeproj/xcuserdata
xcodebuild -resolvePackageDependencies -project BuildSight.xcodeproj -scheme BuildSight | tail -3
echo "Done. Open BuildSight.xcodeproj, pick the BuildSight scheme and run."
