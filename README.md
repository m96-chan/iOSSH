# iOSSH

English | [日本語](README.jp.md)

> An SSH client for iOS, without unnecessary features.

Work correctly as a terminal. Stay fast. Keep everything else out.
Designed around image display through the Kitty Graphics Protocol and GPU rendering with Metal.

> **Status: Initial implementation — v1 acceptance testing is still in progress.**
> The numbered sections below describe the target design. Current implementation details and gaps are listed here.

The repository now contains an iPhone/iPad app with SwiftData host management, Keychain credentials, SSH PTY sessions, explicit first-use host key approval, reconnect, and a Metal terminal. The terminal uses the planned **SwiftTerm fallback** behind `TerminalEngine`; no libghostty-vt binary is required.

The iPad build now includes the dedicated [iPad workspace](#ipad-ui): an adaptive host sidebar, up to four retained connection tabs, and a session menu in narrow windows. iPhone keeps its single-session flow. Physical iPad acceptance and sustained-output profiling remain to be completed.

Implemented authentication: passwords, OpenSSH Ed25519 keys (including supported encrypted keys), unencrypted ECDSA PEM keys, and Tailscale SSH using the connected Tailscale app. Choose **Tailscale SSH** to connect by device name without entering a password or key; check-mode sign-in links appear when requested by the server. The current SSH dependency does not implement keyboard-interactive; RSA is also unavailable. These methods are not offered by the app.

**Import from Tailscale** obtains devices through Tailscale's official **Find Devices** Shortcuts action, then lets you select hosts and enter their SSH username in iOSSH. It requires no API token. A signed shortcut is bundled under **Set Up Shortcut**; see the [setup instructions](docs/DEVELOPMENT.md#import-tailscale-devices). Listed devices still need Tailscale SSH enabled and access allowed by their tailnet policy.

Rendering includes a CoreText glyph atlas, instanced Metal drawing, 24-bit colors, keyboard shortcuts and accessory keys, selection/copy/paste, scrollback, and dark/light themes. Kitty direct RGB/RGBA/PNG transfers have bounded storage. Graphics animation, compressed transfers, relative placements, and explicit source cropping remain unsupported. Ordinary image placements are cleared on resize; Unicode placeholder placements follow the text and survive reflow.

The bundled HackGen Console NF font provides Japanese and Starship/Nerd Font symbols at a default size of 9 pt. Noto Sans CJK JP is bundled as the explicit Japanese fallback for missing glyphs, including when using an imported font. Settings can import additional monospaced TTF/OTF fonts from Files for use inside iOSSH. Glyphs fit the terminal's cell widths, and the visible grid is updated around the keyboard and accessory row when returning to the app or reconnecting. Japanese input uses UIKit composition and sends text only after confirmation.

VT parsing runs on its own `TerminalParserActor`, off the main actor, and hands the UI immutable snapshots. The libghostty-vt backend, Display P3 output, and physical-device 120Hz/power measurements remain follow-up work. Screen lock and backgrounding retain the current SSH session and terminal contents. Returning checks the existing connection and resumes the same shell when it is alive; reconnecting after connection loss opens a new shell. Use a remote multiplexer when shell continuity across connection loss is needed.

See [development and validation notes](docs/DEVELOPMENT.md) for build commands, key formats, and test coverage.

---

## 1. Design Principles

| Pillar | Meaning |
| --- | --- |
| **Simple** | Keeping features out is the first criterion for design decisions. No additions just because they would be nice to have |
| **Correct** | Match desktop terminal behavior for VT / Unicode / Kitty. Get character widths, reflow, and colors right |
| **Fast** | Sustain ProMotion at 120Hz with GPU rendering and minimize latency from input to display |

Targets **both iPhone and iPad**, running **iOS / iPadOS 17+** (with Metal 3 and Swift 6 strict concurrency as baseline requirements). iPhone prioritizes one terminal on a small screen; iPad adds navigation and session switching around one large terminal. Layout follows the available window width, including iPad multitasking and window resizing.

---

## 2. Scope

### Included in v1

- Add and edit hosts
- Import selected Tailscale devices through the official Shortcuts action, without an API token
- Authentication: password / public key / keyboard-interactive
- Store credentials in Keychain, protected by Face ID / Touch ID
- Host key verification (TOFU + persistent storage equivalent to `known_hosts`, with warnings on changes)
- **PTY sessions with window size updates**: one session on iPhone; independent connection tabs on iPad, with one terminal visible at a time
- **Dedicated iPad UI**: collapsible host sidebar, connection tabs enabled by default, and a compact session picker in narrow windows
- **24-bit True Color / 256 colors / ANSI 16 colors**
- **Image display through the Kitty Graphics Protocol**
- Hardware keyboard, trackpad, and pointer support (iPad / Magic Keyboard)
- An accessory key bar above the software keyboard (Ctrl / Esc / Tab / arrows / `|` / `~`)
- Copy and paste, text selection
- Font selection/import, font size, and color theme settings
- Disconnection detection and reconnection

### Excluded from v1 (deliberately)

| Feature | Reason for exclusion |
| --- | --- |
| SFTP / file transfer | Belongs in a separate app. Adds substantial UI complexity |
| Port forwarding | Assumes a persistent connection, which fits poorly with iOS background restrictions |
| mosh | Requires a separate binary on the server. Use a reconnection flow instead |
| tmux control mode | Integration with native UI exceeds the complexity budget for v1 |
| Terminal split panes | One visible terminal keeps keyboard focus and the usable grid clear; iPad uses connection tabs to switch sessions |
| Multiple app windows | The first iPad workspace retains its sessions in one app window; separate window ownership is a later design decision |
| Agent forwarding | Requires security decisions beyond the validation scope of v1 |
| Sixel / iTerm2 image protocols | Standardize on Kitty for images |
| iCloud sync | Syncing private keys requires careful design and is outside v1 |

These are excluded from v1, not ruled out forever. Adding one requires an explicit decision to remove its row from this table.

### iPad UI

The iPad workspace is intended for editing on a remote server, following logs, and moving between machines with a hardware keyboard. Connection tabs are **enabled by default on iPad**. Each tab contains an independent SSH shell; terminal split panes remain outside this iteration.

#### Layout

| Context | Navigation | Terminal area |
| --- | --- | --- |
| iPhone | Host list followed by the current single-session terminal screen, with no navigation bar: close and session actions float over the terminal | One terminal using the available screen; no persistent tab strip |
| iPad with sufficient window width | Collapsible host sidebar, with connection tabs above the terminal | One large terminal beside the sidebar; hiding the sidebar expands it |
| iPad in a narrow window | Host picker and session picker in the toolbar; sidebar and tab strip collapse | The selected terminal fills the available width; all open sessions remain available |

The iPhone single-session screen has no navigation bar and extends the terminal colour to the screen edges, so no permanent row takes terminal height. Close and the session menu float over the grid as round buttons in the trailing corner, because output starts at the leading edge of every row; the destination name and connection state stay in a badge opposite them. The screen is modal and its close button is the only way out: there is no back gesture, so a mis-swipe cannot drop a live session.

The detail area's top row combines sidebar controls, connection tabs, and session actions. There is no separate centered destination title, leaving more terminal height when the software keyboard is open. Settings sits at the bottom of the sidebar and is available from the **Hosts** picker in narrow windows. The terminal has rounded corners and a small inner inset to keep characters clear of the edges. Its bottom edge is level with the sidebar's Settings row, at the bottom of the safe area, so the grid reaches as far down as the sidebar's own content without running under the home indicator.

```text
+------------------+-----------------------------------------------+
| iOSSH       [+]  | [dev *] [logs] [staging] [+]                  |
+------------------+-----------------------------------------------+
| Hosts            |                                               |
|   Development    | user@dev:~$                                   |
|   Logs           |                 Active terminal               |
|   Staging        |                                               |
|                  |                                               |
| Settings         |                                               |
+------------------+-----------------------------------------------+
| Ctrl  Esc  Tab  arrows  |  ~                      Hide keyboard  |
+------------------------------------------------------------------+
| Software keyboard, when shown                                    |
+------------------------------------------------------------------+
```

The diagram shows the expanded layout with a docked software keyboard, with `*` marking the selected tab. The sidebar contains saved hosts and Settings; the detail area contains connection tabs and the terminal. The accessory row appears with the software keyboard. All chrome respects system safe areas and window controls. Use adaptive navigation based on the actual window, following Apple's [layout guidance](https://developer.apple.com/design/human-interface-guidelines/layout) and [NavigationSplitView behavior](https://developer.apple.com/documentation/swiftui/navigationsplitview).

#### Host and tab behavior

- Selecting a sidebar host opens its shell in a tab. If that host already has open tabs, select its most recently used tab; **New Session** in the host menu explicitly opens another shell on the same host.
- The tab-strip `+` and `Command-T` open a **new-session host picker**: choosing a host there always creates a new session, even if that host already has a tab. Adding a saved host remains a separate action in the sidebar.
- Tabs show the saved host name and connection state: connecting, connected, checking, needs attention, or disconnected. Number repeated connections to distinguish them. Status must be accessible as text, not only color.
- Closing a tab explicitly ends that session only. Closing the last tab shows the host-selection empty state. A disconnected tab retains its output and provides **Reconnect**; reconnection creates a new authenticated shell in that tab.
- Overflow tabs scroll horizontally, keeping the selected tab visible. The compact session picker exposes the same tabs, status, and close actions. Resizing the window never closes or replaces a session.
- The initial limit is **four open tabs**, including connecting and disconnected tabs. At the limit, direct the user to an existing tab or to close one before creating another. Do not evict a live session to make room. Revisit the limit after device memory and sustained-output profiling.

#### Keyboard, pointer, and focus

| Shortcut | Workspace action |
| --- | --- |
| `Command-T` | Open the host picker for a new session |
| `Command-W` | Close the selected session tab |
| `Command-Shift-[` / `Command-Shift-]` | Select the previous / next session |
| `Command-1` … `Command-4` | Select a session by its tab order |
| `Command-,` | Open Settings |

Expose available shortcuts through the system keyboard shortcut help. Shell shortcuts such as `Ctrl-C`, `Ctrl-D`, and `Ctrl-Z`, Option-key sequences, and terminal copy/paste keep their existing behavior. Text fields and presented sheets keep normal editing shortcuts; workspace commands must not steal their input.

Only the selected terminal receives typing, paste, accessory-key actions, and Japanese IME confirmation. Switching sessions cancels local unconfirmed composition and clears transient modifiers, without sending those characters to either shell. Restore focus to the selected terminal after dismissing a picker or sheet. Pointer users can select and copy terminal text, scroll history, and use host/tab context menus. Sidebar and tab controls support Dynamic Type, VoiceOver, and at least 44-point touch targets; the terminal keeps its explicit font-size setting.

An asynchronous paste captures the session ID and connection attempt at initiation. If selection or that attempt changes before delivery, discard the unsent content and let the user paste again; never redirect it to the newly selected tab.

The final terminal row must remain above the opaque accessory row. Recalculate the visible grid after sidebar toggles, rotation, window resizing, and docked/floating/hardware-keyboard changes. A floating keyboard must not subtract its height from the entire terminal; keep the input caret and IME candidate anchor clear of its actual frame.

#### Session lifetime and resource use

- A workspace owns sessions by stable runtime IDs, separate from saved host IDs. Switching tabs, collapsing navigation, changing appearance, and presenting Settings preserve each SSH transport, shell, parser state, history, and cursor.
- Forward app background/foreground events to every retained session. On return from screen lock, check existing transports and resume live shells. Process termination or a closed transport requires a new connection; tab restoration must not silently create replacement shells.
- Only the selected session presents credentials, host-key approval, or Tailscale sign-in. Other tabs show an attention state. Serialize authentication sheets and label them with the destination. App-owned prompts offer **Later** to leave the request pending and use another tab, and **Cancel** to end that connection attempt. A deferred prompt reopens only through its tab's attention action; authentication deadlines continue while hidden. System biometric dialogs retain their normal OS behavior.
- Bind authentication responses to the originating session, connection attempt, and request ID; ignore stale callbacks after cancellation, tab closure, or reconnection. Deferring presentation alone must not trigger the current credential sheet's cancellation-on-dismiss behavior.
- Hidden sessions continue consuming and parsing output. Suspend their GPU drawing, cursor timers, and frequent snapshot publication; publish a current snapshot when selected. Hidden sessions retain their last valid PTY size and receive the measured viewport size on activation before keyboard input resumes.
- Keep render resources for the visible terminal only, releasing hidden GPU caches. The initial target is an **app-wide 64 MiB decoded Kitty image budget**, retaining the existing **16 MiB per-image limit**, plus the active renderer's bounded glyph atlas. Preserve bounded scrollback per session. Memory pressure may evict image/render caches, but must not silently disconnect SSH or erase terminal text. The workspace shares this budget across its sessions; standalone terminal engines retain their own limits.

#### Implementation and validation

- [x] Move `ConnectionModel` ownership into `WorkspaceSessionStore` and inject the selected model into `TerminalScreen`.
- [x] Add the adaptive iPad sidebar/detail layout, empty state, retained tabs, and compact session picker.
- [x] Bind input and authentication to each session and connection attempt; add workspace shortcuts.
- [x] Pause hidden snapshots/rendering and share the decoded-image budget across sessions.
- [ ] Complete physical iPad acceptance, including multitasking window controls, Magic Keyboard/trackpad, floating keyboard, and sustained-output/memory profiling.

---

## 3. Architecture

The diagram shows one session. In the iPad workspace, a session store owns an ordered set of `ConnectionModel` instances and the selected session ID. Each model retains its own `SSHSession` and `TerminalEngine`; only the selected model is attached to a visible `TerminalView`. The iPhone flow uses the same ownership model with one session. View disappearance alone must not close a connection.

```
        SwiftUI  (host list / settings / connection flow)
             │
      UIViewRepresentable
             ▼
   TerminalView (MTKView) ──► MetalRenderer ──┬──► GlyphAtlas  (MTLTexture)
             ▲                               └──► ImageStore  (Kitty graphics)
             │  grid snapshot + damage
             │
      TerminalEngine  (VT parsing / grid / scrollback / Kitty state)
             ▲
             │  bytes
      SSHSession  (PTY channel, keepalive, reconnection)
             ▲
      Citadel / swift-nio-ssh
```

**Define `TerminalEngine` as a protocol.** Keep its implementation (libghostty-vt bindings) replaceable. See [11. Known Risks / Open Questions](#11-known-risks--open-questions) for the rationale.

---

## 4. Technology Choices

Record the selected and rejected options for each layer.

| Layer | Selected | Rationale | Rejected alternatives |
| --- | --- | --- | --- |
| SSH | **[Citadel](https://github.com/orlandos-nl/Citadel)** (a high-level wrapper around [apple/swift-nio-ssh](https://github.com/apple/swift-nio-ssh)) | Pure Swift, managed entirely through SPM, with official iOS support. No C toolchain build management | **libssh2 wrapper ([SwiftSH](https://github.com/Frugghi/SwiftSH))**: C dependencies and cross-compilation overhead. **NMSSH**: stalled maintenance. **Direct swift-nio-ssh use**: requires building the client implementation ourselves, duplicating what Citadel already provides |
| VT engine | **[libghostty-vt](https://mitchellh.com/writing/libghostty-is-coming)** (a C API extracted from Ghostty) | **The engine already implements the Kitty Graphics Protocol**. SIMD parsing, Unicode width calculation, reflow, and scrollback are proven in production. Zero dependencies (not even libc), making it easy to embed | **Custom VT parser**: too much work, taking on the part where correctness is hardest to guarantee |
| VT engine (fallback) | **[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)**'s `Terminal` (only the UI-independent component) | Provides a fallback behind the protocol while libghostty-vt's API remains unstable. Kitty Graphics would need a custom implementation | — |
| Rendering | **Custom Metal renderer** (`MTKView` + instanced rendering) | CoreText-based approaches rebuild and draw `NSAttributedString` objects per line, becoming CPU-bound with many cells or frequent updates. Kitty images can be composited as textures in the same pipeline as text, with straightforward z-index handling | **Direct CoreText drawing**: CPU-bound as described above. **CALayer composition**: too many layers at cell granularity |
| Glyphs | **Dynamic rasterization with CoreText → cached in an atlas texture** | Terminals have fixed cell sizes and use only a few font sizes. Hinted rasterization produces sharper text | **MSDF**: resolution independence offers little benefit for a terminal, while quality suffers at small sizes. Also adds atlas generation preprocessing |
| UI | **SwiftUI (app shell) + UIKit (terminal and keyboard input)** | UIKit is the reliable place to handle `MTKView` and key events (`pressesBegan` / `UIKeyCommand` / `UIKeyInput`) | **SwiftUI only**: gaps in handling modifiers and key press/release events |
| Persistence | **Keychain (credentials and private keys) + SwiftData (host settings)** | Physically separate secrets from settings | Combining everything in a single store |
| Concurrency | **Swift 6 strict concurrency**, with the engine isolated to an actor | Enforce thread boundaries between SSH reception, VT parsing, and rendering through the type system | — |

---

## 5. GPU Rendering Design

Concrete decisions for GPU rendering.

### Rendering Triggers

Use **damage-driven rendering** with `MTKView.enableSetNeedsDisplay = true`, rather than a continuous frame loop.
Avoiding GPU work while idle is a core quality requirement on mobile.

### Render Passes

1. **Cell backgrounds** — instanced cell rectangles (background color only)
2. **Glyphs** — draw text using atlas UV coordinates
3. **Decorations** — underline / double underline / wavy underline / strikethrough / box-drawing lines
4. **Images** — composite Kitty graphics textures in z-index order (either behind or in front of text)
5. **Cursor** — block / bar / underline, with blinking

### Buffer Strategy

- An instance buffer with per-cell data (cell index / atlas UV / packed foreground and background colors / attribute bits)
- Triple-buffer `MTLBuffer` objects and use `DispatchSemaphore` to coordinate CPU and GPU progress
- Use engine damage information to update instances **only for changed rows**

### Color

- Handle 24-bit True Color directly. Resolve 256-color and ANSI 16-color values through the theme palette
- Support Display P3 / wide color and **blend in linear space** to avoid incorrect alpha compositing

### Power and Lifecycle

- Stop rendering when the app enters the background (GPU work is not allowed in the background)
- On ProMotion displays, use `preferredFramesPerSecond` as the upper limit while keeping actual rendering damage-driven

---

## 6. Kitty Protocol Support

Kitty has several specifications with different purposes. This section defines how the project handles each one.

| Specification | Target | Scope |
| --- | --- | --- |
| **24-bit True Color** | Required for v1 | `CSI 38;2;R;G;Bm` / `CSI 48;2;R;G;Bm`, 256 colors, ANSI 16 colors. Not Kitty-specific, but the baseline for color support |
| **[Kitty Graphics Protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/)** | v1 | See below |
| **[Kitty Keyboard Protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/)** | v1.1 | Progressive enhancement through `CSI > u` / `CSI < u` / `CSI = u`, with flag stack push/pop. Useful for Neovim / Helix on an iPad with an external keyboard |

### Graphics Protocol Details

| Item | v1 support |
| --- | --- |
| Transmission | **Direct (base64 chunks) only** — file-based and shared-memory transfers are impractical on iOS |
| Formats | RGB / RGBA / PNG |
| Placement | Cell-anchored placement, ordering relative to text through `z`, column/row offsets, scaling |
| Deletion | The various deletion commands using `d` |
| Unicode placeholders | Supported (used by Neovim image plugins, among others) |
| Animation | **Outside v1 scope** |

### `TERM` Handling

Advertise `TERM=xterm-kitty` once the required support is complete, since it causes applications to expect Kitty-specific features.
Some remote hosts lack the `xterm-kitty` terminfo entry, so provide a **per-host `TERM` override** (default to `xterm-256color`, and switch for hosts where Kitty features are desired).

---

## 7. Repository Structure

```
iOSSH/
├─ App/                   # SwiftUI entry point and screens
├─ Packages/
│  ├─ SSHCore/            # Citadel wrapper, authentication, known_hosts, reconnection
│  ├─ TerminalCore/       # TerminalEngine protocol, SwiftTerm adapter, Kitty graphics
│  └─ TerminalRender/     # Metal renderer, GlyphAtlas, shaders
├─ UITests/               # App interaction tests
├─ docs/                  # Development and validation notes
├─ iOSSH.xcodeproj/       # Generated Xcode project (committed)
├─ project.yml           # XcodeGen source
├─ Makefile
├─ README.md              # English version
└─ README.jp.md           # Japanese version
```

Keep the app target thin and put logic in local SPM packages.
Each package must be independently testable (`TerminalCore` must support testing byte sequences → grid state without a UI).

---

## 8. Development Environment

| Requirement | Purpose |
| --- | --- |
| Xcode 26+ / Swift 6.2+ | Current resolved dependencies; deployment target remains iOS 17 |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | Regenerate the Xcode project after changing `project.yml` |
| [Zig](https://ziglang.org/) (future backend only) | Not needed for the current SwiftTerm implementation |

```bash
git clone https://github.com/m96-chan/iOSSH.git
cd iOSSH
make bootstrap   # Generate the project and resolve Swift packages
open iOSSH.xcodeproj
```

---

## 9. Validation and Acceptance Criteria

Define what counts as working before implementation begins.

- **VT compatibility**: pass the basic `vttest` checks and the main `esctest` suites
- **Color**: `ls --color=always` / `htop` / `nvim` display matching colors on a physical device. No banding in True Color gradients
- **Kitty images**: `kitten icat image.png` (or `timg -p kitty`) displays images, follows scrolling, responds to deletion commands, and respects `z` ordering relative to text
- **Performance**: no dropped frames while running `yes` or streaming large volumes of logs. Sustain 120Hz on a physical device (verify with Instruments' Metal System Trace)
- **Resizing**: reflow remains correct when rotation or the software keyboard changes the cell count
- **Connection**: reconnect after network loss and recovery, and detect host key changes

### iPad UI acceptance

- Test portrait and landscape on small and large iPads, wide and narrow multitasking windows, sidebar show/hide, and continuous window resizing. Navigation transitions retain the same session IDs and live shells.
- Open four sessions, including two to the same host; switch while commands produce output. Each tab retains its own history, cursor, title, and connection state. Closing or reconnecting one leaves the others intact.
- Defer tab A's credential or host-key prompt with **Later**, use tab B, and return to A's attention action. Verify **Cancel** ends only A's attempt. Repeat with Tailscale sign-in and with delayed authentication/paste callbacks during tab switching, closure, and reconnection; stale results must neither affect a new attempt nor reach another tab.
- Test Japanese conversion, touch selection, trackpad scrolling, copy/paste, and workspace shortcuts with the software keyboard, floating keyboard, and a hardware keyboard. The terminal's last row and IME caret remain usable.
- Lock/unlock and foreground the app with several sessions open. Resume the same live shells, report genuine disconnections per tab, and avoid reconnecting because a tab was hidden.
- Profile four sessions under sustained output and Kitty image traffic. Only the visible terminal draws; buffers and caches stay bounded, input remains responsive, and memory warnings do not close healthy connections.
- Rerun iPhone connection, authentication, Japanese input, font, and viewport tests. Arbitrary active-paragraph reflow remains a known upstream limitation until separately resolved; see the [development notes](docs/DEVELOPMENT.md).

---

## 10. Security Policy

- Store private keys and passwords in **Keychain**, requiring biometric authentication for access
- Record host keys using TOFU and show a **blocking warning on changes** (never silently accept them)
- Keep private keys within the app, excluding them from cloud sync and backups
- Secure Enclave supports only P-256, so `ecdsa-sha2-nistp256` keys may be stored there (a v1.1 candidate, subject to validation)

---

## 11. Known Risks / Open Questions

| Risk | Impact | Mitigation |
| --- | --- | --- |
| **libghostty-vt's API is unstable** (development assumes breaking changes) | May require rewrites of the engine layer | Isolate it behind the `TerminalEngine` protocol and keep the option to fall back to SwiftTerm. Pin the version and choose when to adopt updates |
| **iOS background execution limits** | Suspension can interrupt networking or allow server timeouts | Retain and check the existing session on return; offer reconnection after connection loss. Indefinite background connectivity is not guaranteed |
| **Citadel's feature coverage is unverified** | PTY / window-change / ed25519 and ECDSA keys / keyboard-interactive support may be incomplete | Validate with a PoC before implementation. Fill any gaps at the swift-nio-ssh layer |
| **Integrating Zig cross-compilation into CI** | Build reproducibility | Standardize XCFramework generation through `make` and attach artifacts to releases |
| **Memory pressure from Kitty Graphics** | Repeated large images may trigger memory warnings | Add limits and eviction to `ImageStore` |
| **Multiple retained iPad sessions** | Hidden output can consume main-actor time; independent image and render caches multiply memory use | Start with four tabs, share an aggregate image budget, render only the selected terminal, and profile sustained output before raising limits |

---

## 12. Roadmap

- **v0.1** — a working baseline with connection / authentication / PTY / CoreText rendering
- **iPad workspace (initial implementation)** — adaptive sidebar/detail layout, retained connection tabs, keyboard/pointer support, and shared resource limits; physical iPad validation is next
- **v1.0** — Metal renderer, True Color, Kitty Graphics, key management, reconnection, and validated iPhone/iPad UI
- **v1.1** — Kitty Keyboard Protocol, Secure Enclave keys, additional themes

---

## 13. License

MIT (planned)

## References

- [Kitty: Terminal graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/)
- [Kitty: Keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/)
- [Libghostty Is Coming — Mitchell Hashimoto](https://mitchellh.com/writing/libghostty-is-coming)
- [ghostty-org/ghostling](https://github.com/ghostty-org/ghostling) — a minimal example using the libghostty C API
- [apple/swift-nio-ssh](https://github.com/apple/swift-nio-ssh)
- [orlandos-nl/Citadel](https://github.com/orlandos-nl/Citadel)
- [migueldeicaza/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
