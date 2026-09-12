.PHONY: bootstrap build test test-ui

# SwiftTerm 1.20.0's pinned build plugin generates version metadata from its Git checkout.
XCODEBUILD_FLAGS ?= -skipPackagePluginValidation

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
