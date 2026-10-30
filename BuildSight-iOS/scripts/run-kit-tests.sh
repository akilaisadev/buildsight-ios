#!/bin/zsh
# Builds BuildSightKit and runs its tests without SwiftPM, for machines with only the
# Command Line Tools. With full Xcode use `swift test` or Cmd+U instead.
# The clang overlay hides a duplicate SwiftBridging modulemap that some CLT releases ship.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/Packages/BuildSightKit"
OUT="${TMPDIR:-/tmp}/bsk-build"
FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
mkdir -p "$OUT"
: > "$OUT/empty.modulemap"
cat > "$OUT/vfs.yaml" <<YAML
{ "version": 0, "roots": [ { "name": "$(xcode-select -p)/usr/include/swift/module.modulemap", "type": "file", "external-contents": "$OUT/empty.modulemap" } ] }
YAML
OVERLAY=()
[[ "$(xcode-select -p)" == *CommandLineTools* ]] && OVERLAY=(-vfsoverlay "$OUT/vfs.yaml" -Xcc -ivfsoverlay -Xcc "$OUT/vfs.yaml")

swiftc -parse-as-library -enable-testing -emit-module -module-name BuildSightKit -emit-library \
  -o "$OUT/libBuildSightKit.dylib" -emit-module-path "$OUT/BuildSightKit.swiftmodule" \
  $(find "$PKG/Sources" -name '*.swift') "${OVERLAY[@]}"

cat > "$OUT/main.swift" <<'SWIFT'
import Testing
@main struct Runner { static func main() async { await Testing.__swiftPMEntryPoint() as Never } }
SWIFT

swiftc -parse-as-library -o "$OUT/kit-tests" -I "$OUT" -L "$OUT" -lBuildSightKit \
  -F "$FRAMEWORKS" -framework Testing -Xlinker -rpath -Xlinker "$FRAMEWORKS" -Xlinker -rpath -Xlinker "$OUT" \
  $(find "$PKG/Tests" -name '*.swift') "$OUT/main.swift" "${OVERLAY[@]}"

"$OUT/kit-tests" "$@"
