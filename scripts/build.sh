#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$project_dir/build/Suijiao.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$project_dir/packaging/Info.plist" "$app_dir/Contents/Info.plist"
xcrun swiftc \
  "$project_dir/tools/Suijiao.swift" \
  "$project_dir/tools/Companion.swift" \
  -target "$(uname -m)-apple-macos13.0" \
  -o "$app_dir/Contents/MacOS/Suijiao" \
  -framework AppKit -framework SwiftUI -framework IOKit \
  -framework ApplicationServices -framework Carbon
codesign --force --sign - "$app_dir"
codesign --verify --strict "$app_dir"
printf 'Built: %s\n' "$app_dir"
