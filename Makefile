.PHONY: bootstrap build test test-ui check-pins device-build device-install device-run

# SwiftTerm 1.20.0's pinned build plugin generates version metadata from its Git checkout.
XCODEBUILD_FLAGS ?= -skipPackagePluginValidation
DEVICE_DERIVED_DATA ?= build/DeviceDerivedData
# The app target depends on GhosttyEngine, whose binary target resolves to this path.
# build/ is gitignored, so a fresh clone has to build it before anything else works.
GHOSTTY_XCFRAMEWORK ?= build/vendor/ghostty-vt.xcframework
# Device builds default to Debug; pass CONFIGURATION=Release to measure or trial
# what the optimiser produces, which is what the parser comparison in #10 needs.
CONFIGURATION ?= Debug

bootstrap:
	@command -v xcodegen >/dev/null || { echo "Install XcodeGen: brew install xcodegen"; exit 1; }
	@xcrun --find metal >/dev/null || { echo "Install the Xcode Metal component: xcodebuild -downloadComponent MetalToolchain"; exit 1; }
	# Package resolution reads GhosttyEngine's binary target, so the xcframework has to exist
	# before xcodegen and xcodebuild run. Building it takes minutes, so skip it once it is there;
	# delete it to pick up a moved GHOSTTY_REF.
	@test -d $(GHOSTTY_XCFRAMEWORK) || { command -v zig >/dev/null || { echo "Install Zig: brew install zig"; exit 1; }; scripts/build_ghostty_vt.sh; }
	xcodegen generate
	xcodebuild -resolvePackageDependencies -project iOSSH.xcodeproj -scheme iOSSH

build:
	xcodebuild -project iOSSH.xcodeproj -scheme iOSSH -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData $(XCODEBUILD_FLAGS) CODE_SIGNING_ALLOWED=NO build

test:
	swift test --package-path Packages/SSHCore
	swift test --package-path Packages/TerminalCore
	# GhosttyEngine ships in the app, so its comparison against the SwiftTerm parser runs here
	# rather than only on a developer's machine. It links $(GHOSTTY_XCFRAMEWORK); run bootstrap first.
	swift test --package-path spike/GhosttyEngine

# Catches a dependency bump applied to one Package.resolved and not the other, which would
# otherwise leave `make test` and `make build` on different versions of a dependency.
check-pins:
	python3 scripts/check_package_pins.py

# SIMULATOR is a device-name prefix, so the names the docs use still select what they always did.
# It goes through the same preparation as CI: an iPad left with a hardware keyboard attached, or
# with AutoFill on, fails the keyboard test and adds a 60s wait to every later interaction.
test-ui:
	udid=$$(scripts/prepare_simulator.sh '$(or $(SIMULATOR),iPhone 17)'); \
	trap "xcrun simctl shutdown $$udid >/dev/null 2>&1 || true" EXIT; \
	xcodebuild -project iOSSH.xcodeproj -scheme iOSSH -destination "platform=iOS Simulator,id=$$udid" -derivedDataPath build/DerivedData $(XCODEBUILD_FLAGS) -parallel-testing-enabled NO test

device-build:
	@test -n "$(TEAM_ID)" || { echo "Set TEAM_ID to your Apple Developer team ID."; exit 1; }
	# Recreate generated bundles so removed or updated fonts are reflected in the installed app.
	rm -rf '$(DEVICE_DERIVED_DATA)/Build/Products/$(CONFIGURATION)-iphoneos/iOSSH.app' '$(DEVICE_DERIVED_DATA)/Build/Products/$(CONFIGURATION)-iphoneos/TerminalRender_TerminalRender.bundle'
	xcodebuild -project iOSSH.xcodeproj -scheme iOSSH -configuration $(CONFIGURATION) -destination '$(if $(DEVICE_ID),id=$(DEVICE_ID),generic/platform=iOS)' -destination-timeout 30 -derivedDataPath '$(DEVICE_DERIVED_DATA)' $(XCODEBUILD_FLAGS) -allowProvisioningUpdates -allowProvisioningDeviceRegistration DEVELOPMENT_TEAM='$(TEAM_ID)' CODE_SIGN_STYLE=Automatic build

device-install:
	@test -n "$(DEVICE_ID)" || { echo "Set DEVICE_ID using xcrun devicectl list devices."; exit 1; }
	xcrun devicectl device install app --device '$(DEVICE_ID)' --timeout 60 '$(DEVICE_DERIVED_DATA)/Build/Products/$(CONFIGURATION)-iphoneos/iOSSH.app'

device-run: device-install
	xcrun devicectl device process launch --device '$(DEVICE_ID)' --timeout 30 io.github.m96-chan.iossh
