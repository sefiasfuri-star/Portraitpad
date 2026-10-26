#!/bin/bash
# Builds and installs PortraitPad without opening Xcode.
#   portraitpad.sh install   update the code, install the Mac app in /Applications, refresh the iPad app
#   portraitpad.sh ipad      only refresh the iPad app (the free Apple ID needs this every 7 days)
# Xcode must be installed and signed in to your Apple ID once (Xcode > Settings > Accounts).
set -uo pipefail

MODE="${1:-install}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
cd "$ROOT"

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
fail() { printf '\n\033[31m%s\033[0m\n' "$1"; exit 1; }

if [ "$MODE" = "install" ]; then
    step "Getting the latest version"
    git pull --ff-only || echo "(Couldn't update; using the copy you have.)"
fi

if ! command -v xcodegen >/dev/null; then
    step "Installing XcodeGen"
    brew install xcodegen || fail "Couldn't install XcodeGen. Is Homebrew installed?"
fi
xcodegen --quiet || fail "Couldn't create the Xcode project."

# Your team id is inside the "Apple Development" certificate Xcode made when you signed in.
TEAM=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -n 1)
[ -n "$TEAM" ] || fail "No Apple Development certificate found. Open Xcode once, sign in under Settings > Accounts, and build the iPad app one time."

SIGNING=(DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates)

if [ "$MODE" = "install" ]; then
    step "Building the Mac app"
    xcodebuild -project PortraitPad.xcodeproj -scheme PortraitPadHost -configuration Release \
        -derivedDataPath "$BUILD" "${SIGNING[@]}" -quiet build || fail "The Mac app didn't build."

    step "Installing it in Applications"
    osascript -e 'quit app "PortraitPad Host"' >/dev/null 2>&1
    sleep 1
    rm -rf "/Applications/PortraitPad Host.app"
    cp -R "$BUILD/Build/Products/Release/PortraitPad Host.app" /Applications/ || fail "Couldn't copy the app to Applications."
    open "/Applications/PortraitPad Host.app"
fi

step "Building the iPad app"
xcodebuild -project PortraitPad.xcodeproj -scheme PortraitPad -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$BUILD" \
    "${SIGNING[@]}" -allowProvisioningDeviceRegistration -quiet build || fail "The iPad app didn't build."

step "Installing it on the iPad"
DEVICES_JSON="$BUILD/devices.json"
xcrun devicectl list devices --json-output "$DEVICES_JSON" >/dev/null 2>&1
DEVICE=$(/usr/bin/python3 - "$DEVICES_JSON" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    sys.exit()
paired = [d for d in devices
          if d.get("connectionProperties", {}).get("pairingState") == "paired"
          and d.get("hardwareProperties", {}).get("platform", "iOS") == "iOS"]
# Prefer an iPad, then the one on the cable.
paired.sort(key=lambda d: (d.get("hardwareProperties", {}).get("deviceType") != "iPad",
                           d.get("connectionProperties", {}).get("transportType") != "wired"))
ipads = paired
if ipads:
    print(ipads[0]["identifier"])
PY
)
[ -n "$DEVICE" ] || fail "No iPad found. Plug it in with the cable, unlock it, and run this again."

xcrun devicectl device install app --device "$DEVICE" \
    "$BUILD/Build/Products/Release-iphoneos/PortraitPad.app" >/dev/null || fail "Couldn't install on the iPad. Is it unlocked?"
xcrun devicectl device process launch --device "$DEVICE" com.sefi.portraitpad.viewer >/dev/null 2>&1

step "Done"
if [ "$MODE" = "install" ]; then
    echo "PortraitPad Host is in Applications and opens by itself when you log in."
fi
echo "The iPad app is good for the next 7 days."
