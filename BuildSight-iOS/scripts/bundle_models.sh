#!/bin/sh
# Xcode build phase: compiles any ML/models/*.mlpackage into the app bundle.
# With none present the app still builds and says no helmet model is installed.
set -e
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
FOUND=0
for NAME in PPEDetectorV2 PPEDetector HelmetDetector; do
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
