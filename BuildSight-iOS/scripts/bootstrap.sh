#!/bin/zsh
# One-step setup after cloning: installs XcodeGen if needed, prepares the
# settings file, generates BuildSight.xcodeproj and opens it in Xcode.
set -e
cd "$(dirname "$0")/.."
xcodebuild -version >/dev/null 2>&1 || { echo "Install Xcode 16 or newer from the App Store first."; exit 1; }
if ! command -v xcodegen >/dev/null; then
  command -v brew >/dev/null || { echo "Install Homebrew (https://brew.sh), then run this again."; exit 1; }
  brew install xcodegen
fi
if [ ! -f Config/Secrets.xcconfig ]; then
  echo "Note: no Config/Secrets.xcconfig. The app will build and run but cannot sign in."
  echo "      Copy Config/Secrets.xcconfig.example to Config/Secrets.xcconfig and add the"
  echo "      backend URL and publishable key from the project owner."
fi
# The Core ML models are git-ignored (licence) and are bundled by a build phase
# (scripts/bundle_models.sh), so the project must not reference them. Move them aside
# while generating, then put them back.
ASIDE=$(mktemp -d)
restore() { find "$ASIDE" -maxdepth 1 -name "*.mlpackage" -exec mv {} ML/models/ \; 2>/dev/null; rmdir "$ASIDE" 2>/dev/null || true; }
trap restore EXIT
find ML/models -maxdepth 1 -name "*.mlpackage" -exec mv {} "$ASIDE"/ \;
xcodegen generate
restore
if [ ! -f Config/Signing.xcconfig ]; then
  echo "Note: to run on a real iPhone, copy Config/Signing.xcconfig.example to Config/Signing.xcconfig and set your team ID."
fi
[ "${1:-}" = "--no-open" ] || open BuildSight.xcodeproj
echo "Done. In Xcode pick an iPhone simulator and press Cmd+R."
