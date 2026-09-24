#!/bin/zsh
# Builds Record 9:16.app next to this script.
# Signs with the "Record916 Signing" certificate if it exists in the keychain, so the
# code-signing identity stays stable across rebuilds and macOS keeps the Screen
# Recording permission. Falls back to ad-hoc signing (permission must be re-granted).
set -e
cd "$(dirname "$0")"
APP="Record 9:16.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/Record916" Sources/main.swift -framework AppKit -framework Carbon
cp Info.plist "$APP/Contents/Info.plist"
if security find-certificate -c "Record916 Signing" >/dev/null 2>&1; then
  codesign --force --sign "Record916 Signing" --identifier com.arthurwalsh.record916 "$APP"
  echo "Signed with Record916 Signing"
else
  codesign --force --sign - "$APP"
  echo "WARNING: ad-hoc signed; Screen Recording permission will need re-granting"
fi
echo "Built: $(pwd)/$APP"
