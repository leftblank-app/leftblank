#!/bin/bash
# Sign nested Sparkle executables before the framework and outer app.
set -euo pipefail
source "$(dirname "$0")/environment.sh"
app=$1
identity=${2:--}
keychain=${3:-}
entitlements=${4:-}
args=(--force --sign "$identity")
if [ "$identity" != - ]; then args+=(--options runtime --timestamp); fi
if [ -n "$keychain" ]; then args+=(--keychain "$keychain"); fi
framework="$app/Contents/Frameworks/Sparkle.framework"
if [ -d "$framework" ]; then
  for service in "$framework"/Versions/B/XPCServices/*.xpc; do
    [ ! -d "$service" ] || codesign "${args[@]}" --preserve-metadata=entitlements "$service"
  done
  codesign "${args[@]}" "$framework/Versions/B/Autoupdate"
  codesign "${args[@]}" "$framework/Versions/B/Updater.app"
  codesign "${args[@]}" "$framework"
fi
distribution=$(/usr/libexec/PlistBuddy -c 'Print LeftBlankDistribution' "$app/Contents/Info.plist")
helper_args=("${args[@]}")
if [ "$distribution" = appstore ]; then
  helper_args+=(--entitlements Resources/LeftBlank.Helper.entitlements)
  if [ -z "$entitlements" ]; then
    if [ "$identity" != - ]; then
      echo 'App Store signing requires validated provisioning-profile entitlements.' >&2
      exit 1
    fi
    entitlements=Resources/LeftBlank.AppStore.entitlements
  fi
fi
codesign "${helper_args[@]}" "$app/Contents/Helpers/tinymist"
codesign "${helper_args[@]}" "$app/Contents/Helpers/leftblank-mcp"
if [ -n "$entitlements" ]; then args+=(--entitlements "$entitlements"); fi
codesign "${args[@]}" "$app"
codesign --verify --deep --strict "$app"
