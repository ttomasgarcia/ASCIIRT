#!/bin/bash
# Arma ASCIIRT.app desde el producto de SwiftPM.
#
# Por que no xcodebuild: en esta maquina no hay Xcode, solo Command Line Tools.
# SwiftPM compila el ejecutable; el bundle lo armamos a mano porque la camara
# necesita Info.plist con NSCameraUsageDescription y una identidad firmada para
# que TCC pueda otorgar el permiso.
#
# Los .metal NO se precompilan (no existe `metal` sin Xcode): se copian como
# recursos y ShaderLibrary los compila al arrancar. Ver Metal/ShaderLibrary.swift.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/ASCIIRT.app"

cd "$ROOT"
swift build -c "$CONFIG" --product ASCIIRT
BIN="$(swift build -c "$CONFIG" --product ASCIIRT --show-bin-path)/ASCIIRT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Shaders"

cp "$BIN" "$APP/Contents/MacOS/ASCIIRT"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Sources/ASCIIRT/Shaders/"*.metal "$APP/Contents/Resources/Shaders/"
cp "$ROOT/Sources/ShaderTypes/include/RenderParams.h" "$APP/Contents/Resources/Shaders/"

# Firma ad-hoc. Alcanza para que TCC identifique la app, pero la identidad es el
# cdhash: cada rebuild cambia el hash y macOS vuelve a pedir permiso de camara.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1

echo "→ $APP"
