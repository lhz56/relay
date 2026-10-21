#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
build_dir="${RELAY_BUILD_DIR:-$project_dir/.build}"
app_dir="${RELAY_APP_DIR:-$project_dir/dist/Relay.app}"
swift build --package-path "$project_dir" --scratch-path "$build_dir" --configuration release --product Relay
bin_dir="$(swift build --package-path "$project_dir" --scratch-path "$build_dir" --configuration release --show-bin-path)"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/Relay" "$app_dir/Contents/MacOS/Relay"
cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --sign "${RELAY_SIGN_IDENTITY:--}" --entitlements "$project_dir/entitlements.plist" "$app_dir"
codesign --verify --strict "$app_dir"
print "Built $app_dir"
