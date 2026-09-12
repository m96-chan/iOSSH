.PHONY: bootstrap build test test-ui device-build device-install device-run

# SwiftTerm 1.20.0's pinned build plugin generates version metadata from its Git checkout.
XCODEBUILD_FLAGS ?= -skipPackagePluginValidation
DEVICE_DERIVED_DATA ?= build/DeviceDerivedData

bootstrap:
	@command -v xcodegen >/dev/null || { echo "Install XcodeGen: brew install xcodegen"; exit 1; }
	@xcrun --find metal >/dev/null || { echo "Install the Xcode Metal component: xcodebuild -downloadComponent MetalToolchain"; exit 1; }
	xcodegen generate
	xcodebuild -resolvePackageDependencies -project iOSSH.xcodeproj -scheme iOSSH

build:
	xcodebuild -project iOSSH.xcodeproj -scheme iOSSH -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData $(XCODEBUILD_FLAGS) CODE_SIGNING_ALLOWED=NO build

test:
	swift test --package-path Packages/SSHCore
	swift test --package-path Packages/TerminalCore

test-ui:
	xcodebuild -project iOSSH.xcodeproj -scheme iOSSH -destination 'platform=iOS Simulator,name=$(or $(SIMULATOR),iPhone 17)' -derivedDataPath build/DerivedData $(XCODEBUILD_FLAGS) -parallel-testing-enabled NO test

device-build:
	@test -n "$(TEAM_ID)" || { echo "Set TEAM_ID to your Apple Developer team ID."; exit 1; }
	xcodebuild -project iOSSH.xcodeproj -scheme iOSSH -configuration Debug -destination '$(if $(DEVICE_ID),id=$(DEVICE_ID),generic/platform=iOS)' -destination-timeout 30 -derivedDataPath '$(DEVICE_DERIVED_DATA)' $(XCODEBUILD_FLAGS) -allowProvisioningUpdates -allowProvisioningDeviceRegistration DEVELOPMENT_TEAM='$(TEAM_ID)' CODE_SIGN_STYLE=Automatic build

device-install:
	@test -n "$(DEVICE_ID)" || { echo "Set DEVICE_ID using xcrun devicectl list devices."; exit 1; }
	xcrun devicectl device install app --device '$(DEVICE_ID)' --timeout 60 '$(DEVICE_DERIVED_DATA)/Build/Products/Debug-iphoneos/iOSSH.app'

device-run: device-install
	xcrun devicectl device process launch --device '$(DEVICE_ID)' --timeout 30 moe.technologies.iossh
