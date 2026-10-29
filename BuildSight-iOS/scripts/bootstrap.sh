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
# The Core ML models are not in the repository (licence). Leave out any that are
# missing so the project still builds; the app then reports "no model installed".
python3 - <<'PY'
import os, re
spec = open("project.yml").read()
def keep(m):
    return m.group(0) if os.path.exists(m.group(1)) else ""
spec = re.sub(r"      - path: (ML/models/[^\n]+\.mlpackage)\n        optional: true\n", keep, spec)
open(".project.generated.yml", "w").write(spec)
PY
xcodegen generate --spec .project.generated.yml
[ "${1:-}" = "--no-open" ] || open BuildSight.xcodeproj
echo "Done. In Xcode pick an iPhone simulator and press Cmd+R."
