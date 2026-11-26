#!/bin/bash
# Lumen regression tools. Builds into build/tools (gitignored). See docs/TESTING.md.
#   Tools/test.sh unit                          run the parser XCTest suite
#   Tools/test.sh build                         build the app (Debug)
#   Tools/test.sh scenes [ids] [time] [layers]  render scenes in the corpus to PNG
#   Tools/test.sh stability <id> [minutes]      play a scene continuously at 30 fps and check trends
#   Tools/test.sh visual [N]                    rank the latest scene renders against author previews
#   Tools/test.sh visual diff <before> <after> [N]  rank pixel changes between two saved scene runs
#   Tools/test.sh shaders [v|<name>|dump:<name>] translate + compile every WE shader
#   Tools/test.sh steam                         check SteamCMD prompt parsing with a fake steamcmd
#   Tools/test.sh lockloop scene|web|codesea|prostrands <folder> [entry] [WxH]  record a Lock Screen loop to build/tools (no install)
#   Tools/test.sh native codesea|prostrands <resource|-> render native wallpapers' key frames to build/tools/native
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Lumen"
OUT="$ROOT/build/tools"
# Defaults: the popular-scene corpus in build/ and Lumen's own copy of Wallpaper Engine's assets.
CORPUS="${LUMEN_SCENE_CORPUS:-$ROOT/build/we-corpus-popular}"
ASSETS="${LUMEN_SCENE_ASSETS:-$HOME/Library/Application Support/Lumen/SceneAssets}"
mkdir -p "$OUT"

scene_sources() {
  ls "$SRC"/Engine/Scene/*.swift | grep -v SceneRenderer.swift
  ls "$SRC"/Engine/Scene/Shaders/*.swift
  echo "$SRC/Library/WallpaperEngineProject.swift"
  ls "$SRC"/Engine/Audio/*.swift
  echo "$SRC/Support/Support.swift"
}

build_scene_harness() {
  scene_sources | xargs swiftc -O -D DEBUG -enable-bare-slash-regex -o "$OUT/scene-harness" \
    "$ROOT/Tools/SceneHarness/main.swift" "$ROOT/Tools/SceneHarness/SceneStability.swift" \
    "$ROOT/Tools/SceneVisualRegression/SceneVisualRun.swift"
}

case "${1:-}" in
  native)
    kind="${2:?codesea or prostrands}"
    swiftc -O -o "$OUT/native-harness" "$ROOT/Tools/NativeHarness/main.swift" \
      "$SRC"/Engine/Native/CodeSea/CodeSea{Context,Core,Field,Text,Wings}.swift \
      "$SRC"/Engine/Native/PROStrands/PROStrands{Core,Layout,Sim}.swift
    "$OUT/native-harness" "$kind" "${3:--}" "$OUT/native"
    ;;
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
    mkdir -p "$OUT/scenes"
    rm -f -- "$OUT/scenes/visual-inputs.json"
    build_scene_harness
    LUMEN_SCENE_VIDEO_CACHE="$OUT/scene-videos" "$OUT/scene-harness" "$CORPUS" "$ASSETS" "$OUT/scenes" "${2:-}" "${3:-2}" ${4:+"$4"} | tee "$OUT/scenes.log" | awk '/ OK | FAIL /'
    echo "PNGs: $OUT/scenes   log: $OUT/scenes.log"
    ;;
  stability)
    if [[ $# -lt 2 || $# -gt 3 || "$2" == *,* || -z "$2" ]]; then
      echo "Usage: Tools/test.sh stability <scene-id> [minutes]" >&2
      exit 2
    fi
    build_scene_harness
    LUMEN_SCENE_VIDEO_CACHE="$OUT/scene-videos" LUMEN_STABILITY_MINUTES="${3:-5}" \
      "$OUT/scene-harness" "$CORPUS" "$ASSETS" "$OUT" "$2" | tee "$OUT/stability.log"
    ;;
  visual)
    if [[ "${2:-}" == diff ]]; then
      if [[ $# -lt 4 || $# -gt 5 ]]; then
        echo "Usage: Tools/test.sh visual diff <before-scenes> <after-scenes> [N]" >&2
        exit 2
      fi
      args=(diff "$3" "$4" "$OUT/visual" "${5-10}")
    else
      if [[ $# -gt 2 ]]; then
        echo "Usage: Tools/test.sh visual [N]" >&2
        exit 2
      fi
      args=("$OUT/scenes" "$OUT/visual" "${2-10}")
    fi
    swiftc -O -module-cache-path "$OUT/visual-module-cache" -o "$OUT/visual-regression" "$ROOT"/Tools/SceneVisualRegression/*.swift
    "$OUT/visual-regression" "${args[@]}"
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
  lockloop)
    # Compiles the app's sources (minus its @main) into a tool that records without installing.
    find "$SRC" -name '*.swift' ! -name LumenApp.swift > "$OUT/app-sources.txt"
    xargs swiftc -O -D DEBUG -enable-bare-slash-regex -module-name Lumen -o "$OUT/loop-recorder" \
      "$ROOT/Tools/LoopRecorderTest/main.swift" < "$OUT/app-sources.txt"
    # Native wallpapers load their shaders and text as bundle resources; a tool's bundle is its folder.
    cp "$SRC"/Engine/Native/*/*.msl "$SRC"/Engine/Native/CodeSea/CodeSeaVerses.txt "$OUT/"
    "$OUT/loop-recorder" "$2" "$3" "${4:-$([[ "$2" == web ]] && echo index.html || echo scene.json)}" "$OUT/lockloop.mov" "$ASSETS" "${5:-2560x1664}"
    echo "movie: $OUT/lockloop.mov"
    ;;
  *)
    sed -n '2,11p' "$0"; exit 1 ;;
esac
