#!/bin/bash
# Lumen regression tools. Builds into build/tools (gitignored). See docs/TESTING.md.
#   Tools/test.sh unit                          run the parser XCTest suite
#   Tools/test.sh build                         build the app (Debug)
#   Tools/test.sh scenes [ids] [time] [layers]  render scenes in the corpus to PNG
#   Tools/test.sh shaders [v|<name>|dump:<name>] translate + compile every WE shader
#   Tools/test.sh steam                         check SteamCMD prompt parsing with a fake steamcmd
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Lumen"
OUT="$ROOT/build/tools"
CORPUS="${LUMEN_SCENE_CORPUS:-$HOME/Library/Application Support/WallpaperMachine/Library}"
ASSETS="${LUMEN_SCENE_ASSETS:-$HOME/Library/Application Support/WallpaperMachine/SceneAssets}"
mkdir -p "$OUT"

scene_sources() {
  ls "$SRC"/Engine/Scene/*.swift | grep -v SceneRenderer.swift
  ls "$SRC"/Engine/Scene/Shaders/*.swift
  echo "$SRC/Library/WallpaperEngineProject.swift"
  ls "$SRC"/Engine/Audio/*.swift
  echo "$SRC/Support/Support.swift"
}

case "${1:-}" in
  build|unit)
    cd "$ROOT"
    xcodegen generate >/dev/null
    scheme=Lumen
    action=build
    if [[ "$1" == unit ]]; then
      scheme=LumenTests
      action=test
    fi
    xcodebuild -project Lumen.xcodeproj -scheme "$scheme" -configuration Debug \
      -destination 'platform=macOS' -derivedDataPath build/DerivedData "$action"
    ;;
  scenes)
    scene_sources | xargs swiftc -O -D DEBUG -enable-bare-slash-regex -o "$OUT/scene-harness" "$ROOT/Tools/SceneHarness/main.swift"
    mkdir -p "$OUT/scenes"
    "$OUT/scene-harness" "$CORPUS" "$ASSETS" "$OUT/scenes" "${2:-}" "${3:-2}" ${4:+"$4"} | tee "$OUT/scenes.log" | grep -E " OK | FAIL " || true
    echo "PNGs: $OUT/scenes   log: $OUT/scenes.log"
    ;;
  shaders)
    scene_sources | xargs swiftc -O -enable-bare-slash-regex -o "$OUT/shader-corpus" "$ROOT/Tools/ShaderCorpus/main.swift"
    cd "$OUT" && "$OUT/shader-corpus" "$ASSETS" "$CORPUS" "${2:-}"
    ;;
  steam)
    swiftc -enable-bare-slash-regex -o "$OUT/steamcmd-fake" "$ROOT/Tools/SteamCMDFake/main.swift" "$SRC/Library/Steam/SteamCMD.swift" "$SRC/Support/Support.swift"
    rm -rf "$OUT/steam-out"
    "$OUT/steamcmd-fake" "$ROOT/Tools/SteamCMDFake/fake-steamcmd.sh" "$OUT/steam-out"
    ;;
  *)
    sed -n '2,8p' "$0"; exit 1 ;;
esac
