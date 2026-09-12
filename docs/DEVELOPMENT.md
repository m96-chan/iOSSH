# Development and validation

English | [日本語](DEVELOPMENT.jp.md)

Use Xcode 26 or newer with Swift 6.2 or newer. The app targets iOS 17 and supports iPhone and iPad. The local SSHCore and TerminalCore packages can also be tested on macOS 14 or newer.

```sh
brew install xcodegen
make bootstrap
open iOSSH.xcodeproj
```

Install the Metal compiler component if Xcode reports it missing: `xcodebuild -downloadComponent MetalToolchain`. Choose the iOSSH scheme and a simulator. For a physical device, choose your development team under Signing & Capabilities. Xcode may ask to trust SwiftTerm's build plugin; the pinned plugin generates source-control version metadata. The command-line build opts into that plugin with `-skipPackagePluginValidation` for reproducible unattended builds.

The generated Xcode project is committed, so XcodeGen is only needed for regeneration. Change `project.yml` first, then run `xcodegen generate`. Commit `Package.resolved` files with dependency changes. No Zig toolchain or downloaded XCFramework is needed for the SwiftTerm backend.

```sh
make build                         # Unsigned simulator build
make test                          # SSHCore and TerminalCore unit tests
make test-ui SIMULATOR='iPhone 17'  # Use an installed simulator's name
```

The GitHub Actions workflow runs package tests, a simulator build, and app/UI tests. App unit tests cover connection cancellation, resize during authentication, early remote exit, queued input failures, and host-key decisions. UI tests cover host creation, editing, deletion, validation, settings, terminal startup, and credential cancellation. Use `--ui-testing` as an app launch argument only for tests; it selects an in-memory host store.

## Debug build on a physical device

Sign in to your Apple Account in Xcode's Settings > Accounts. Connect your iPhone or iPad to the Mac, unlock it, and accept the pairing prompt if shown. Enable [Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device) on the device when Xcode requests it.

```sh
xcrun devicectl list devices
make device-build TEAM_ID=YOUR_TEAM_ID DEVICE_ID=YOUR_DEVICE_UDID
make device-run DEVICE_ID=YOUR_DEVICE_UDID
```

Use the hardware UDID shown by Xcode's Devices and Simulators window for `DEVICE_ID`; `devicectl` also accepts its own device identifier for installation and launch. A Personal Team can be used for direct development installation. These commands create a signed **Debug** build with automatic provisioning, install it, and launch it. They may register the selected device with your team. The team ID is supplied at build time and is not saved in the shared project. The app is built at `build/DeviceDerivedData/Build/Products/Debug-iphoneos/iOSSH.app`.

For an already-built app, `make device-install DEVICE_ID=YOUR_DEVICE_UDID` only installs it. If the device is temporarily unavailable, omit `DEVICE_ID` from `device-build` to build for generic iOS; the signing profile must still include the device before installation. [Free Personal Team profiles expire after seven days](https://developer.apple.com/support/compare-memberships/); rebuild and reinstall after expiration. For breakpoints and interactive logs, select the same team and device in Xcode and run the iOSSH scheme with the Debug configuration.

Start physical testing by adding a server you control, checking its host-key fingerprint, and opening a shell. Check typing, rotation, copy/paste, saved-credential biometrics, and reconnection after returning from the background. Local-network connections may trigger the iOS network permission prompt.

If installation succeeds but iOS refuses to launch an untrusted developer app, open Settings > General > VPN & Device Management on the device and trust the certificate for the Apple Account used to sign this build. Follow any confirmation or restart prompts. Apple documents this [Personal Team setup](https://developer.apple.com/documentation/swiftui/food-truck-building-a-swiftui-multiplatform-app) for its sample apps as well.

## Connect

Add a hostname/IP address, SSH port, username, and authentication method. For password/key authentication, saving an empty credential is allowed; the app asks for it when connecting. Credentials entered on the connection screen are used for that connection unless **Save in Keychain** is enabled.

For **Tailscale SSH**, connect the Tailscale iOS app first, enter the server's MagicDNS device name (or full `.ts.net` name/Tailscale IP), port 22, and the server's username, then choose **Tailscale SSH** in Authentication. The server must have Tailscale SSH enabled and allow access through the tailnet SSH policy. This mode uses SSH `none` authentication and does not load, save, or ask for credentials. Existing password/key hosts retain their selected method; edit a host to change it. Name resolution uses the system resolver and the connected Tailscale app. See [Tailscale SSH](https://tailscale.com/docs/features/tailscale-ssh) and [MagicDNS](https://tailscale.com/docs/features/magicdns).

Check-mode approval messages appear while connecting. Tap the Tailscale HTTPS sign-in button to complete approval in the in-app Safari sheet. SSH authentication waits up to five minutes in this mode. Links are never opened automatically, and first-use/changed host-key checks still apply. Switching to an external browser can background the app and close SSH; reconnect after approval in that case.

Saved secrets use Keychain with `WhenPasscodeSetThisDeviceOnly` and `biometryCurrentSet`, never SwiftData or UserDefaults. Enroll Face ID/Touch ID and set a device passcode before saving secrets. The app does not weaken storage protection when biometrics are unavailable; enter the credential per connection instead. Changing enrolled biometrics can invalidate existing saved credentials.

Supported keys:

- Ed25519 in OpenSSH private-key format, unencrypted or using the encryption supported by Citadel (AES-128/256-CTR with bcrypt rounds below 32).
- Unencrypted ECDSA P-256/P-384/P-521 in PEM format.
- RSA is unavailable because the current dependency's RSA implementation uses legacy `ssh-rsa`. Keyboard-interactive is not implemented by the current dependency.

First use shows the server's SHA-256 host-key fingerprint. Compare it through a trusted channel before accepting. Known keys persist in Application Support; a changed key blocks the connection. Deleting a host entry does not erase its trust record. There is no in-app host-key reset yet.

Reconnect opens a fresh authenticated shell, including host-key verification. It cannot recover a shell that the server ended. The app closes SSH when backgrounded and offers reconnection on return.

## Terminal

Tap the terminal to show the keyboard. The accessory row includes Ctrl, Esc, Tab, arrows, pipe, and tilde. Hardware modifiers, application cursor keys, and bracketed paste are handled. Swipe vertically for history. Long press and drag to select; use the edit menu or Command-C/Command-V to copy/paste. Settings change the font size and dark/light palette.

The default font is bundled **UDEV Gothic NF** in regular, bold, italic, and bold italic styles, with Japanese and Nerd Font symbols for Starship. Latin and Japanese advances use a 1:2 ratio. Oversized symbol ink is fitted within the cell span reported by the terminal parser; Powerline separators meet the cell edges. Settings previews the same font and includes its licenses. Server-side prompt width settings must still match the terminal's Unicode widths.

The last terminal row stays above the opaque accessory row. Layout is recalculated from current keyboard/accessory geometry after keyboard changes, foregrounding, and reconnection, and the resulting rows/columns are sent to the PTY.

The terminal protocol keeps the view independent of SwiftTerm. Parser state is isolated to `MainActor`, while immutable snapshots carry grid cells, damage, cursor state, and images into the renderer. Snapshot publication is coalesced. Metal uses a bounded glyph atlas and triple instance buffers, rebuilding changed rows in each buffer slot. Rendering pauses when inactive.

Kitty images use direct base64 transfers only, RGB/RGBA/PNG, and bounded payload, image, and placement storage. Unsupported commands return protocol errors instead of claiming support. Resize invalidates ordinary placements; the application on the server must redraw them. Unicode placeholder placements follow the text and survive reflow. Keep `TERM=xterm-256color` unless you have independently validated the host application's expectations for another value.

The standalone renderer check `swift Packages/TerminalRender/Scripts/validate-metal.swift` compiles all shader pipelines, renders through the GPU, and checks linear alpha composition.

## Real SSH integration test

An optional SSHCore test can use an SSH server you control:

```sh
IOSSH_TEST_SSH_HOST=127.0.0.1 \
IOSSH_TEST_SSH_PORT=22222 \
IOSSH_TEST_SSH_USER="$USER" \
IOSSH_TEST_SSH_KEY_PATH=/absolute/path/to/test_ed25519 \
swift test --package-path Packages/SSHCore --filter SSHIntegrationTests
```

Use a disposable test key and account. The test checks PTY output, remote `stty` dimensions, disconnection, and reconnect without a repeated trust prompt. It does not change the app's known-host or credential stores. The integration test skips when its environment variables are absent.

## Verified locally

On 2026-09-12, with Xcode 26.5 / Swift 6.3.2:

- iOS Simulator app build succeeded (iPhone and iPad target families).
- A Personal Team signed Debug build passed signature validation, installed, and launched on iPhone 17e / iOS 26.6.1 after trusting the developer certificate. The user confirmed a successful connection to a Tailscale SSH server with the initial build.
- Version 0.1.0 build 2 was signed with all four bundled fonts verified in the app and installed on the same iPhone over Wi-Fi. The user's Starship theme and Tailscale check-mode flow still need physical-device confirmation with this update.
- SSHCore: 20 unit/protocol tests passed, including Tailscale authentication and bounded authentication banners. The optional real OpenSSH test passed during initial validation and was skipped for this update.
- TerminalCore: 18 tests / 19 parameterized cases passed.
- App/renderer: 21 tests / 22 parameterized cases passed on iPhone 17 / iOS 26.5 Simulator, covering connection lifecycle, Tailscale sign-in, font coverage/rasterization, and keyboard viewport geometry.
- UI: 4 tests passed on iPhone 17, including keyboard display, foreground return, reconnect, and rotation; its final landscape screenshot was inspected. Initial terminal startup/cancellation also passed on iPad Pro 11-inch (M5) / iOS 26.5 Simulator.
- The standalone Metal GPU rendering/blending check passed; terminal and iPad startup screenshots were inspected.

## Remaining acceptance work

- Physical iPhone/iPad validation of Keychain biometrics, hardware keyboards, background behavior, and international input.
- `vttest` and `esctest` against a real server, and Neovim/Helix image-plugin compatibility.
- Instruments measurements for 120Hz, sustained output, memory pressure, and idle power.
- Display P3 output, parser isolation outside the main actor, and the future libghostty-vt backend.
- Keyboard-interactive authentication, broader key support, and image placement preservation across reflow.
