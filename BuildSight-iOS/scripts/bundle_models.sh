#!/bin/sh
# Xcode build phase: compile ML/models/*.mlpackage into the app bundle when they exist.
# The model weights are git-ignored (licence), so a fresh clone has none; the app still
# builds and reports "no helmet model installed". Drop PPEDetector.mlpackage (and optionally
# HelmetDetector.mlpackage) into ML/models/ and build again to include them.
set -e
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
FOUND=0
for NAME in PPEDetector HelmetDetector; do
  SRC="$SRCROOT/ML/models/$NAME.mlpackage"
  rm -rf "$DEST/$NAME.mlmodelc"
  if [ -d "$SRC" ]; then
    xcrun coremlcompiler compile "$SRC" "$DEST"
    FOUND=$((FOUND + 1))
  fi
done
if [ "$FOUND" -eq 0 ]; then
  echo "warning: No Core ML model found in ML/models (PPEDetector.mlpackage). This build will say \"No helmet model is installed\". Copy the .mlpackage files into BuildSight-iOS/ML/models and build again."
else
  echo "Bundled $FOUND Core ML model(s)"
fi
