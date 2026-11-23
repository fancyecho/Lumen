#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

version="$(awk '/^[[:space:]]*MARKETING_VERSION:/ { gsub(/["\047]/, "", $2); print $2; exit }' project.yml)"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Expected a major.minor.patch MARKETING_VERSION in project.yml." >&2
  exit 1
fi

release="$ROOT/build/release"
mkdir -p "$release"
scratch="$(mktemp -d "$release/.stage.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
xcodegen generate
xcodebuild -project Lumen.xcodeproj -scheme Lumen -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$ROOT/build/DerivedData" \
  -resultBundlePath "$scratch/Release.xcresult" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  "LUMEN_UPDATE_FEED_URL=${LUMEN_UPDATE_FEED_URL:-}" build

app="$ROOT/build/DerivedData/Build/Products/Release/Lumen.app"
/usr/bin/codesign --verify --strict "$app"
mkdir "$scratch/image"
/usr/bin/ditto "$app" "$scratch/image/Lumen.app"
ln -s /Applications "$scratch/image/Applications"
name="Lumen-$version.dmg"
/usr/bin/hdiutil create -srcfolder "$scratch/image" -volname "Lumen $version" -format UDZO "$scratch/$name"
/usr/bin/hdiutil verify "$scratch/$name"
(cd "$scratch" && /usr/bin/shasum -a 256 "$name" > "$name.sha256")
mv -f "$scratch/$name" "$scratch/$name.sha256" "$release/"
cat "$release/$name.sha256"
printf '%s\n' "$release/$name"
