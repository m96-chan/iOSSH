#!/bin/bash
# Prints the UDID of a booted simulator whose name starts with $1, after setting the two
# defaults that decide whether the UI tests can run at all. Neither is the same on a fresh
# runner as on a Mac somebody has opened Simulator.app on, so both are set here rather than
# assumed.
#
# ConnectHardwareKeyboard: a connected hardware keyboard leaves the software keyboard hidden,
# and KeyboardResizeUITests measures the terminal against the space that keyboard takes.
#
# AutoFillPasswords: once the app has saved a credential, focusing a text field raises iOS's
# AutoFill bar. It belongs to another process, so the app never reports itself idle and XCTest
# waits its full 60 seconds before each later interaction; #32's iPad tests took over twenty
# minutes that way. The app is responsive throughout — this is the harness waiting, not a hang.
set -euo pipefail

PREFIX="${1:?Pass a simulator name prefix, for example iPhone or iPad}"
UDID=$(xcrun simctl list devices available --json | python3 -c 'import json,sys; devices=json.load(sys.stdin)["devices"]; print(next(d["udid"] for runtime in sorted(devices, reverse=True) if "iOS" in runtime for d in devices[runtime] if d["isAvailable"] and d["name"].startswith(sys.argv[1])))' "$PREFIX")

# Simulator.app reads these from the host, per device as well as globally, and only as the
# device boots. A device left running from an earlier job would keep whatever it started with,
# so shut it down first rather than trust that a runner is clean.
xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false
defaults write com.apple.iphonesimulator DevicePreferences -dict-add "$UDID" '{ConnectHardwareKeyboard = 0;}'

# Those two defaults belong to Simulator.app, and nothing reads them when xcodebuild boots a
# device on its own: the guest then comes up with a hardware keyboard attached and shows only
# the shortcut bar, which is not the keyboard KeyboardResizeUITests measures against.
open -a Simulator --args -CurrentDeviceUDID "$UDID"

# AutoFill is a preference inside the guest, so the device has to be up to receive it.
xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl spawn "$UDID" defaults write com.apple.Preferences AutoFillPasswords -bool false

echo "$UDID"
