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

The keyboard resize UI test dismisses the English keyboard's first-use QuickPath introduction before operating the accessory row. On a fresh simulator, this system overlay can cover buttons that still appear in the accessibility hierarchy. CI retains the `ios-test-results` artifact for seven days; extract it into a folder named `CI.xcresult` and open it in Xcode to inspect failures and screenshots.

## Debug build on a physical device

Sign in to your Apple Account in Xcode's Settings > Accounts. Connect your iPhone or iPad to the Mac, unlock it, and accept the pairing prompt if shown. Enable [Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device) on the device when Xcode requests it.

```sh
xcrun devicectl list devices
make device-build TEAM_ID=YOUR_TEAM_ID DEVICE_ID=YOUR_DEVICE_UDID
make device-run DEVICE_ID=YOUR_DEVICE_UDID
```

Use the hardware UDID shown by Xcode's Devices and Simulators window for `DEVICE_ID`; `devicectl` also accepts its own device identifier for installation and launch. A Personal Team can be used for direct development installation. These commands create a signed **Debug** build with automatic provisioning, install it, and launch it. They may register the selected device with your team. The team ID is supplied at build time and is not saved in the shared project. The app is built at `build/DeviceDerivedData/Build/Products/Debug-iphoneos/iOSSH.app`.

For an already-built app, `make device-install DEVICE_ID=YOUR_DEVICE_UDID` only installs it. If the device is temporarily unavailable, omit `DEVICE_ID` from `device-build` to build for generic iOS; the signing profile must still include the device before installation. [Free Personal Team profiles expire after seven days](https://developer.apple.com/support/compare-memberships/); rebuild and reinstall after expiration. For breakpoints and interactive logs, select the same team and device in Xcode and run the iOSSH scheme with the Debug configuration.

Start physical testing by adding a server you control, checking its host-key fingerprint, and opening a shell. Check Japanese conversion/confirmation, rotation, copy/paste, saved-credential biometrics, and resuming the same shell after screen lock. Local-network connections may trigger the iOS network permission prompt.

If installation succeeds but iOS refuses to launch an untrusted developer app, open Settings > General > VPN & Device Management on the device and trust the certificate for the Apple Account used to sign this build. Follow any confirmation or restart prompts. Apple documents this [Personal Team setup](https://developer.apple.com/documentation/swiftui/food-truck-building-a-swiftui-multiplatform-app) for its sample apps as well.

## Connect

Add a hostname/IP address, SSH port, username, and authentication method. For password/key authentication, saving an empty credential is allowed; the app asks for it when connecting. Credentials entered on the connection screen are used for that connection unless **Save in Keychain** is enabled.

For **Tailscale SSH**, connect the Tailscale iOS app first, enter the server's MagicDNS device name (or full `.ts.net` name/Tailscale IP), port 22, and the server's username, then choose **Tailscale SSH** in Authentication. The server must have Tailscale SSH enabled and allow access through the tailnet SSH policy. This mode uses SSH `none` authentication and does not load, save, or ask for credentials. Existing password/key hosts retain their selected method; edit a host to change it. Name resolution uses the system resolver and the connected Tailscale app. See [Tailscale SSH](https://tailscale.com/docs/features/tailscale-ssh) and [MagicDNS](https://tailscale.com/docs/features/magicdns).

Check-mode approval messages appear while connecting. Tap the Tailscale HTTPS sign-in button to complete approval in the in-app Safari sheet. SSH authentication waits up to five minutes in this mode. Links are never opened automatically, and first-use/changed host-key checks still apply. Pending authentication is retained when the app backgrounds; if the network connection or authentication deadline expires while approving, reconnect afterward.

Saved secrets use Keychain with `WhenPasscodeSetThisDeviceOnly` and `biometryCurrentSet`, never SwiftData or UserDefaults. Enroll Face ID/Touch ID and set a device passcode before saving secrets. The app does not weaken storage protection when biometrics are unavailable; enter the credential per connection instead. Changing enrolled biometrics can invalidate existing saved credentials.

Supported keys:

- Ed25519 in OpenSSH private-key format, unencrypted or using the encryption supported by Citadel (AES-128/256-CTR with bcrypt rounds below 32).
- Unencrypted ECDSA P-256/P-384/P-521 in PEM format.
- RSA is unavailable because the current dependency's RSA implementation uses legacy `ssh-rsa`. Keyboard-interactive is not implemented by the current dependency.

First use shows the server's SHA-256 host-key fingerprint. Compare it through a trusted channel before accepting. Known keys persist in Application Support; a changed key blocks the connection. Deleting a host entry does not erase its trust record. There is no in-app host-key reset yet.

Screen lock and backgrounding retain the SSH session, terminal buffer, and cursor. Returning checks the existing connection and reapplies its current terminal size without authenticating again or opening another shell. Explicit Close/Disconnect still closes the connection. If the peer has closed or no longer responds, the app offers Reconnect; that opens a fresh authenticated shell with host-key verification and cannot recover a shell the server ended. iOS can suspend the app, so retaining a session does not guarantee indefinite background networking. See [Apple's background execution guidance](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time).

Shell output is read on demand: the app asks the SSH channel for the next batch only after the terminal has consumed the previous one. A burst such as a large directory listing therefore closes the SSH receive window and makes the server wait, instead of queueing unbounded output on the device or dropping bytes and ending the session.

## Import Tailscale devices

1. Install Tailscale and Shortcuts on the iPhone or iPad, sign in to Tailscale, and keep it connected.
2. In iOSSH's host list, open **Import from Tailscale** (the download icon), then **Set Up Shortcut → Save Shortcut File**. Choose **Save to Files**, open the saved `.shortcut` file, and tap **Add Shortcut**. Keep the name **Import Tailscale Hosts**. The same [signed file](../shortcuts/Import%20Tailscale%20Hosts.shortcut) and its [reviewable source](../shortcuts/README.md) are in this repository.
3. Return to iOSSH and tap **Fetch Devices**. Allow Shortcuts to access Tailscale results and pass them to iOSSH when asked.
4. In the returned list, select the servers to save and enter their SSH username. Tap **Add** to register them with **Tailscale SSH**, port **22**. Nothing is selected initially; importing never starts a connection.

The bundled shortcut uses the official [Find Devices action](https://tailscale.com/docs/features/mac-ios-shortcuts) without filters, preferring each device's MagicDNS address, then IPv4, then IPv6. To create it manually, add **Tailscale → Find Devices** followed by **iOSSH → Review Tailscale Hosts**, and set **Hostnames** to the **MagicDNS Address** property of the Devices result (IPv4 or IPv6 also works). Do not pass the device's display name or the whole object as text.

Discovery uses the Tailscale app's current account and requires no API token in iOSSH. The list does not report whether SSH is enabled or access is permitted; select servers configured for [Tailscale SSH](https://tailscale.com/docs/features/tailscale-ssh). An existing entry with the same normalized hostname/IP, username, and port is skipped, retaining its settings and credentials. Short names, full DNS names, and IP addresses cannot be matched to one another without alias information. First-use and changed host-key checks still apply when connecting.

Shortcuts only stages candidates in memory. Cancel discards them; saving requires explicit selection and a username. An import received during an SSH session preserves that session and waits for other app sheets or authentication to finish. The input is limited to 512 nonempty entries and 64 KiB; larger tailnets can use Find Devices filters. A failed or canceled shortcut leaves the previous candidate list available for review.

If fetching returns an error, iOSSH displays the error description supplied by Shortcuts. Use **Open Shortcuts**, confirm that **Import Tailscale Hosts** exists, and run it directly to identify the failing action. If it is missing, add the bundled file through **Set Up Shortcut** first.

`TailscaleHostImportTests` covers normalization, limits, duplicates, validation, and failed-save cleanup; `TailscaleImportInboxTests` checks App Intent delivery and callback handling. `TailscaleImportPresentationTests` hosts the native UI to check authentication priority and retained shells while reviewing devices and changing sessions. `TailscaleImportUITests` exercises selection, saved SSH settings, cancellation, and setup on iPhone/iPad using synthetic devices. The official Tailscale action and first-run permission prompts require a physical-device check with both apps installed.

## iPad workspace

On iPad, select a saved host in the sidebar to open or return to its most recently used session. The tab-strip **+**, **Command-T**, or a host's **New Session** context-menu action opens an independent shell, including another connection to the same host. Up to four tabs can stay open, including disconnected tabs. Closing one tab ends only that shell; a disconnected tab keeps its output until explicitly reconnected or closed.

Hide the sidebar to expand the terminal. Below 700 points of window width, Hosts and Sessions toolbar menus replace the sidebar and tab strip. The Sessions menu can select or close each tab. Resizing preserves every connection and its terminal state. iPhone keeps one full-screen session using the same session owner.

Sidebar controls, tabs, and session actions share one row at the top of the detail area, without a separate centered destination title. Settings is at the bottom of the sidebar or in the **Hosts** picker when narrow. The iPad terminal uses rounded corners with a small inner inset, preserving space above the software keyboard and keeping characters clear of the rounded edges.

**Later** leaves an authentication request pending so another tab can be used; choose **Continue** in the original tab to reopen it. **Cancel** ends that attempt. Host-key and credential replies are bound to the original session, connection attempt, and request. A hidden tab never opens a new authentication sheet automatically.

Hardware shortcuts include **Command-W** to close, **Command-Shift-[ / ]** to switch, **Command-1…4** to select by position, and **Command-,** for Settings. Commands apply while the terminal has focus; ordinary editing shortcuts remain available in text fields. Switching sessions cancels unconfirmed Japanese text and transient Ctrl state. An asynchronous paste is discarded if its session or connection attempt changes before delivery; it is never sent to another tab. PTY resize requests precede subsequent user input.

Only the selected terminal renders. Hidden sessions still parse output, keep bounded history, and receive foreground connection checks. All workspace sessions share a 64 MiB decoded Kitty-image cache with a 16 MiB per-image limit; memory warnings release cached images without closing SSH or deleting terminal text.

Run `make test-ui SIMULATOR='iPad Pro 11-inch (M5)'` using an installed iPad simulator. `iPadWorkspaceUITests` covers retained tabs, deferred authentication, duplicate hosts, the tab limit, closing, sidebar changes, and keyboard geometry. `WorkspaceLayoutTests` hosts the real adaptive UI at wide, narrow, and portrait dimensions with deterministic transports; it verifies native renderer ownership and PTY sizes without reconnecting. iPad-only tests skip on iPhone. Physical iPad testing remains necessary for window controls, Magic Keyboard/trackpad, floating keyboard interaction, and sustained-output performance.

## Terminal

Tap the terminal to show the keyboard. The accessory row includes Ctrl, Esc, Tab, arrows, pipe, and tilde. Hardware modifiers, application cursor keys, and bracketed paste are handled. Swipe vertically for history. Long press and drag to select; use the edit menu or Command-C/Command-V to copy/paste. Settings change the font size and dark/light palette.

The default font is bundled **HackGen Console NF**, at **8.5 pt on iPhone** and **9 pt on iPad**, with Japanese and Nerd Font symbols for Starship. Shell output assumes 80 columns, and a portrait iPhone is the narrowest grid the app draws: 8.5 pt fits 83 columns into both 375 points at 2× and 390 points at 3×, while 9 pt fits only 78. Cell widths round up to a device pixel, so the font size steps by half a point in Settings; whole points would jump straight past the size that keeps 80 columns. An iPad is wide enough at the larger size. Saved font sizes are retained. Rows use the font's natural line height rounded to device pixels, without extra point-based leading that elongates block art at small sizes. Missing characters fall back explicitly to bundled **Noto Sans CJK JP** Regular/Bold, including behind imported fonts; emoji retain the system color-emoji fallback. Latin and Japanese advances use a 1:2 ratio. Oversized symbol ink is fitted within the cell span reported by the terminal parser; Powerline separators meet the cell edges. Settings previews the selected font, shows the configured Japanese fallback, and includes all bundled font licenses. Server-side prompt width settings must still match the terminal's Unicode widths.

Wide-character continuation cells inherit the leading cell's resolved colors and visual attributes. This compensates for SwiftTerm 1.20.0 assigning a stale default background to those cells, which produced white rectangles over the right half of Japanese text. GPU tests compare complete frames against independent glyph rasters, including fullwidth spaces and following ASCII text.

Solid block elements, including half blocks, eighths, and quadrants, fill cell-aligned pixel rectangles. Complementary shapes share the same rounded boundary even at odd pixel dimensions; font bearings, italic transforms, and antialiasing cannot create seams in ANSI art. Shade patterns and other characters retain font rendering.

SwiftTerm 1.20.0 leaves the paragraph containing the active cursor out of resize reflow. Narrowing can truncate that paragraph until the remote program redraws it; completed paragraphs reflow normally.

Settings can import monospaced `.ttf` and `.otf` files from Files. Imports are copied into iOSSH's Application Support directory and registered for this app, not installed system-wide. The selected font is restored on launch; removing an imported selection returns to the bundled default.

Japanese composition is handled by a native UIKit text input at the terminal cursor. Marked text and candidate edits remain local until confirmed; deleting or canceling a composition does not erase text already sent to the server.

The last terminal row stays above the opaque accessory row. Layout is recalculated from current keyboard/accessory geometry after keyboard changes, foregrounding, and reconnection, and the resulting rows/columns are sent to the PTY.

Every window size sent to the PTY also carries the terminal's size in pixels, taken from the measured cell size. Image tools read that from the remote tty's window size rather than from an escape sequence, and refuse to draw when it is zero. A font change keeps the same rows and columns but changes the pixel size, so it sends a window change of its own. `CSI 14 t` and `CSI 16 t` answer with the same measured cell size.

Keyboard height changes preserve the pixel size of text and images and change the available row count. The paused Metal view synchronizes its drawable with its bounds and requests a fresh frame even when the shell is idle. On iPad, an offscreen keyboard notification invalidates a stale keyboard guide, restoring the terminal to the bottom inset after dismissal. A still-visible accessory row continues to reserve its actual height.

The terminal protocol keeps the view independent of SwiftTerm. Parser state, terminal buffers, and decoded images are isolated to `TerminalParserActor`; the UI reaches them through `TerminalPipeline`, which runs every command in the order it was submitted and answers queries after the work queued ahead of them. Parsing a full-screen repaint costs tens of milliseconds, so keeping it off the main actor leaves input, layout, and drawing unblocked. Immutable snapshots carry grid cells, damage, cursor state, and images into the renderer. Snapshot publication is coalesced. Metal uses a bounded glyph atlas and triple instance buffers, rebuilding changed rows in each buffer slot. Rendering pauses when inactive.

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

## App Store preparation

The app uses `io.github.m96-chan.iossh` as its bundle identifier and Shortcuts
callback URL scheme. The shared project leaves `DEVELOPMENT_TEAM` empty; pass
your team at build time. Builds with this ID install alongside the previous
`moe.technologies.iossh` app with separate hosts, Keychain credentials, settings,
known-host records, and imported fonts. These do not migrate automatically.
Replace the old **Import Tailscale Hosts** shortcut with the file exported from
the new app, keeping its name, then fetch devices from the new app. See the
[shortcut migration steps](../shortcuts/README.md#updating-from-the-previous-app-identifier).

[Store listing and review notes](APP_STORE.md), [support](SUPPORT.md), and
[privacy policy](PRIVACY.md) are drafts until their remaining release inputs are
filled. The app's privacy manifest declares its app-local UserDefaults access
with reason `CA92.1`.

Software license text is bundled as `App/Resources/ThirdPartyNotices.txt` and
available under **Settings → Open source licenses**. After changing dependencies,
review the linked targets and regenerate it from Xcode's resolved checkouts:

```sh
python3 scripts/generate_third_party_notices.py --checkouts build/DerivedData/SourcePackages/checkouts
python3 scripts/generate_third_party_notices.py --checkouts build/DerivedData/SourcePackages/checkouts --check
```

Use your actual DerivedData path. Generation is offline and reads pinned Git
objects; bundled C notices include Citadel bcrypt, SwiftNIO's cpp_magic.h,
BoringSSL, and fiat-crypto. Separate font notices remain in **Font licenses**.
`xcodegen generate` includes both the notices and app privacy manifest as resources.

Before submission, review the final archive's SDK privacy declarations.
SwiftTerm 1.20.0 includes `stat`/`fstat` in its Kitty local-file/shared-memory
transfer implementation and has no privacy manifest. iOSSH handles Kitty
graphics separately and only accepts direct transfers, so those SDK paths are
unused here. Whether these retained paths need an iOS-specific SDK change
remains to be resolved; the presence of those symbols alone is not evidence of
an App Store rejection, and an unrelated approved API reason must not be added
to silence validation.

## Verified locally

On 2026-09-12, with Xcode 26.5 / Swift 6.3.2:

- Version 0.1.0 build 10 fixes jagged ANSI block art by rasterizing solid blocks and quadrants on shared cell boundaries. The old renderer failed all eight new block mask/GPU cases; the fix passes them at 9/16 pt and 2×/3×, along with all 77 app/render tests on both simulators and the native resize/layout checks. The user's original ANSI art was rendered locally before and after the fix and visually compared; the temporary input and diagnostic test are not included in the repository. The signed build installed over Wi-Fi and launched on both physical devices; iPhone launch succeeded after screen unlock.
- iOS Simulator app build succeeded (iPhone and iPad target families).
- Version 0.1.0 build 9 changes the initial font size to 9 pt and removes the extra 2 pt of leading. At 9 pt on a 2× display, HackGen cells change from 10×25 to 10×21 pixels. The 75 app/render tests and native resize/GPU tests passed on both simulators; fallback and Powerline/emoji coverage now includes 9/16 pt at 2×/3×. iPhone Japanese Kana input and iPad settings, native workspace layout, and repeated keyboard dismissal passed. The signed build installed over Wi-Fi and launched on both physical devices. Comparison with actual SSH output after this update remains a manual check.
- Version 0.1.0 build 8 fixes stretched terminal pixels during keyboard resizing and the stale bottom keyboard gap on iPad. The missing idle redraw and extra iPad gap were reproduced before the fixes. All 75 app/render tests and both new native resize/GPU tests passed on iPhone and iPad simulators. Three consecutive keyboard show/hide cycles passed on each, including iPad's system dismissal button; iPad workspace/layout tests and iPhone Japanese Kana input, foreground return, and reconnect also passed. Signature/provisioning checks passed, and the build installed over Wi-Fi and launched on iPhone 17e and iPad Air (4th generation). Verification with the user's actual SSH output remains pending.
- Version 0.1.0 build 7 adopts the selected B artwork as the app icon. The supplied PNG was resized to the 1024-pixel app-icon asset without changing its composition. Device and simulator builds passed, as did signature and provisioning checks for both devices. The build installed over Wi-Fi and launched on iPhone 17e and iPad Air (4th generation); icons retrieved from both devices confirmed the B artwork.
- Version 0.1.0 build 6 moves iPad tabs into the top header, removes the duplicate destination title, moves Settings into the sidebar, and rounds the terminal surface. The native iPad window test, both iPad workspace UI flows, Settings on both device families, and the iPhone keyboard/foreground/reconnect flow passed. Screenshots were inspected; the signed build installed over Wi-Fi and launched on the iPad Air (4th generation).
- Version 0.1.0 build 5 adds the iPad workspace. The 75 app/render tests passed on both iPad Pro 11-inch (M5) and iPhone 17 simulators. The native iPad window test passed at wide, narrow, and portrait dimensions, preserving three shells and one active renderer. Both new iPad UI flows and all five existing iPhone UI tests passed, including actual Japanese Kana candidate selection and confirmation. The shared-image-budget update passed all 26 TerminalCore tests. Build 5 was installed over Wi-Fi and launched on an iPad Air (4th generation); the user also confirmed it works. Full physical acceptance, including window controls, hardware input, and sustained-output profiling, remains pending.
- A Personal Team signed Debug build passed signature validation, installed, and launched on iPhone 17e / iOS 26.6.1 after trusting the developer certificate. The user confirmed a successful connection to a Tailscale SSH server with the initial build.
- Version 0.1.0 build 3 passed signature, Personal Team profile, and bundled HackGen Regular/Bold checksum checks, then installed on the same iPhone over Wi-Fi. After the user unlocked the screen, the updated app launched successfully. The user confirmed Japanese input works on this build. The user's Starship theme, screen-lock session resumption, and Tailscale check-mode flow still need physical-device confirmation.
- Version 0.1.0 build 4 passed signature and bundled HackGen/Noto font checksum checks, installed over Wi-Fi, and launched on the same iPhone. The right-half white-background issue was reproduced in GPU output before the fix; after the fix, the full rendered frame matches the independent reference within 1 RGB level. Physical confirmation with the user's server output remains pending.
- SSHCore: 24 unit/protocol tests passed, including Tailscale authentication, bounded authentication banners, and retained-connection probes (peer acknowledgement, refusal, timeout, and cancellation). The optional real OpenSSH test passed during initial validation and was skipped for this update.
- TerminalCore: 21 tests / 24 parameterized cases passed, including both-half colors/styles and completed Japanese paragraph reflow.
- App/renderer: 53 tests passed on iPhone 17 / iOS 26.5 Simulator, covering retained-session lifecycle, Tailscale sign-in, HackGen coverage/rasterization, font import/removal/reimport, explicit Noto JP fallback, native Japanese composition, keyboard viewport geometry, and full-frame GPU comparisons that reproduce and verify the right-half background fix.
- UI: Japanese Kana input and Settings both passed again for build 4. Earlier, 5 tests passed on iPhone 17 across the full run and focused reruns, including keyboard display, foreground return, reconnect, rotation, and real Japanese Kana candidate selection/confirmation. The local preedit and native candidate-bar screenshot was inspected. Initial terminal startup/cancellation also passed on iPad Pro 11-inch (M5) / iOS 26.5 Simulator.
- The standalone Metal GPU rendering/blending check passed; terminal and iPad startup screenshots were inspected.

## Remaining acceptance work

- Physical iPhone/iPad validation of Keychain biometrics, hardware keyboards, background behavior, and international input.
- `vttest` and `esctest` against a real server, and Neovim/Helix image-plugin compatibility.
- Instruments measurements for 120Hz, sustained output, memory pressure, and idle power.
- Display P3 output, parser isolation outside the main actor, and the future libghostty-vt backend.
- Keyboard-interactive authentication, broader key support, and image placement preservation across reflow.
