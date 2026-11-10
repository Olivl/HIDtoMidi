#!/bin/bash
# Compile HIDtoMidi.app en binaire universel (Apple Silicon + Intel), macOS 13 Ventura minimum.
# Sortie : build/HIDtoMidi.app et build/HIDtoMidi.zip (à copier sur l'autre Mac).
set -euo pipefail
cd "$(dirname "$0")"

APP=build/HIDtoMidi.app
SDK=$(xcrun --show-sdk-path)
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Contournement d'un bug de certains Command Line Tools : un ancien
# usr/include/swift/module.modulemap redéfinit « SwiftBridging ». On le masque
# (pour cette compilation seulement) via un overlay de système de fichiers.
EXTRA=()
TOOLS_INC="$(dirname "$(dirname "$(xcrun -f swiftc)")")/include/swift"
if [[ -f "$TOOLS_INC/module.modulemap" && -f "$TOOLS_INC/bridging.modulemap" ]]; then
  : > build/empty.modulemap
  cat > build/overlay.yaml <<YAML
{ "version": 0, "case-sensitive": "false", "roots": [ { "type": "directory", "name": "$TOOLS_INC",
  "contents": [ { "type": "file", "name": "module.modulemap", "external-contents": "$PWD/build/empty.modulemap" } ] } ] }
YAML
  EXTRA=(-vfsoverlay build/overlay.yaml -Xcc -ivfsoverlay -Xcc build/overlay.yaml)
fi

for ARCH in arm64 x86_64; do
  echo "→ Compilation $ARCH"
  xcrun swiftc -O -parse-as-library -swift-version 5 \
    -target "$ARCH-apple-macos13.0" -sdk "$SDK" \
    -framework IOKit -framework CoreMIDI ${EXTRA[@]+"${EXTRA[@]}"} \
    App/Sources/*.swift -o "build/HIDtoMidi-$ARCH"
done

lipo -create -output "$APP/Contents/MacOS/HIDtoMidi" build/HIDtoMidi-arm64 build/HIDtoMidi-x86_64
rm -f build/HIDtoMidi-arm64 build/HIDtoMidi-x86_64 build/overlay.yaml build/empty.modulemap
cp App/Info.plist "$APP/Contents/Info.plist"
cp App/Icons/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
ditto -c -k --keepParent "$APP" build/HIDtoMidi.zip

lipo -info "$APP/Contents/MacOS/HIDtoMidi"
echo "✅ $APP  (+ build/HIDtoMidi.zip)"
