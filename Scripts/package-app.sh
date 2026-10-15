#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
cd "$project_dir"
(cd Bridge/Claude && npm ci --ignore-scripts --no-audit --no-fund)
swift build -c release --product Shastra
swift build -c release --product ShastraService
swift build -c release --product ShastraCLI

bundle="$project_dir/dist/Shastra.app"
mkdir -p "$bundle/Contents/MacOS"
mkdir -p "$bundle/Contents/Resources/ThirdParty"
icon_tmp=$(mktemp -d)
trap 'rm -rf "$icon_tmp"' EXIT
swift Scripts/generate-app-icon.swift Sources/ShastraApp/Resources/ShastraMark.svg "$icon_tmp/Shastra.iconset"
iconutil -c icns "$icon_tmp/Shastra.iconset" -o "$bundle/Contents/Resources/Shastra.icns"
rsync -a "$project_dir/.build/release/Shastra_ShastraApp.bundle" "$bundle/Contents/Resources/"
for executable in Shastra ShastraService ShastraCLI; do
  cp "$project_dir/.build/release/$executable" "$bundle/Contents/MacOS/$executable.next"
  mv "$bundle/Contents/MacOS/$executable.next" "$bundle/Contents/MacOS/$executable"
done
mkdir -p "$bundle/Contents/Resources/ClaudeBridge"
rsync -a --delete --exclude 'bridge.test.mjs' "$project_dir/Bridge/Claude/" "$bundle/Contents/Resources/ClaudeBridge/"
cp -f "$project_dir/.build/checkouts/SwiftTerm/LICENSE" "$bundle/Contents/Resources/ThirdParty/SwiftTerm-LICENSE.txt"
cp -f "$project_dir/.build/checkouts/GRDB.swift/LICENSE" "$bundle/Contents/Resources/ThirdParty/GRDB-LICENSE.txt"
if [[ -d "$project_dir/.build/release/GRDB_GRDB.bundle" ]]; then
  rsync -a "$project_dir/.build/release/GRDB_GRDB.bundle" "$bundle/Contents/Resources/"
fi
cp -f "$project_dir/.build/checkouts/TOMLDecoder/LICENSE.md" "$bundle/Contents/Resources/ThirdParty/TOMLDecoder-LICENSE.md"
chmod u+w "$bundle/Contents/Resources/ThirdParty/SwiftTerm-LICENSE.txt"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Shastra</string>
  <key>CFBundleDisplayName</key><string>Shastra</string>
  <key>CFBundleIdentifier</key><string>dev.shastra.personal</string>
  <key>CFBundleExecutable</key><string>Shastra</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>Shastra</string>
  <key>CFBundleShortVersionString</key><string>0.6.0</string>
  <key>CFBundleVersion</key><string>11</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --deep --sign - "$bundle"
echo "$bundle"
