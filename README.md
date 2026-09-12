# iOSSH

English | [日本語](README.jp.md)

> An SSH client for iOS, without unnecessary features.

Work correctly as a terminal. Stay fast. Keep everything else out.
Designed around image display through the Kitty Graphics Protocol and GPU rendering with Metal.

> **Status: Design phase (implementation has not started)**
> This document also serves as the agreed design before implementation begins.

<!-- TODO: Screenshots (iPhone / iPad) -->

---

## 1. Design Principles

| Pillar | Meaning |
| --- | --- |
| **Simple** | Keeping features out is the first criterion for design decisions. No additions just because they would be nice to have |
| **Correct** | Match desktop terminal behavior for VT / Unicode / Kitty. Get character widths, reflow, and colors right |
| **Fast** | Sustain ProMotion at 120Hz with GPU rendering and minimize latency from input to display |

Targets **both iPhone and iPad**, running **iOS 17+** (with Metal 3 and Swift 6 strict concurrency as baseline requirements).

---

## 2. Scope

### Included in v1

- Add and edit hosts
- Authentication: password / public key / keyboard-interactive
- Store credentials in Keychain, protected by Face ID / Touch ID
- Host key verification (TOFU + persistent storage equivalent to `known_hosts`, with warnings on changes)
- **One shell session** (PTY, with window size updates)
- **24-bit True Color / 256 colors / ANSI 16 colors**
- **Image display through the Kitty Graphics Protocol**
- Hardware keyboard support (iPad / Magic Keyboard)
- An accessory key bar above the software keyboard (Ctrl / Esc / Tab / arrows / `|` / `~`)
- Copy and paste, text selection
- Font size and color theme settings
- Disconnection detection and reconnection

### Excluded from v1 (deliberately)

| Feature | Reason for exclusion |
| --- | --- |
| SFTP / file transfer | Belongs in a separate app. Adds substantial UI complexity |
| Port forwarding | Assumes a persistent connection, which fits poorly with iOS background restrictions |
| mosh | Requires a separate binary on the server. Use a reconnection flow instead |
| tmux control mode | Integration with native UI exceeds the complexity budget for v1 |
| Tabs / split panes | Keep one session per screen. Especially problematic on the iPhone's small display |
| Agent forwarding | Requires security decisions beyond the validation scope of v1 |
| Sixel / iTerm2 image protocols | Standardize on Kitty for images |
| iCloud sync | Syncing private keys requires careful design and is outside v1 |

These are excluded from v1, not ruled out forever. Adding one requires an explicit decision to remove its row from this table.

---

## 3. Architecture

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

## 7. Planned Repository Structure

```
iOSSH/
├─ App/                   # SwiftUI entry point and screens
├─ Packages/
│  ├─ SSHCore/            # Citadel wrapper, authentication, known_hosts, reconnection
│  ├─ TerminalCore/       # TerminalEngine protocol + libghostty-vt bindings
│  └─ TerminalRender/     # Metal renderer, GlyphAtlas, shaders
├─ Vendor/
│  └─ libghostty-vt.xcframework   # Cross-compiled with Zig
├─ README.md              # English version
└─ README.jp.md           # Japanese version
```

Keep the app target thin and put logic in local SPM packages.
Each package must be independently testable (`TerminalCore` must support testing byte sequences → grid state without a UI).

---

## 8. Development Environment

| Requirement | Purpose |
| --- | --- |
| Xcode 16+ / iOS 17 SDK | The app itself |
| Swift 6 | Strict concurrency |
| [Zig](https://ziglang.org/) | Cross-compile libghostty-vt for `aarch64-ios` / `aarch64-ios-simulator` and generate an XCFramework |

```bash
git clone https://github.com/m96-chan/iOSSH.git
cd iOSSH
make bootstrap   # TODO: Build libghostty-vt and generate the XCFramework
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
| **iOS background execution limits** | Suspension drops SSH connections | Accept that connections cannot stay up indefinitely and handle this through the **reconnection flow** (alongside the decision to exclude mosh) |
| **Citadel's feature coverage is unverified** | PTY / window-change / ed25519 and ECDSA keys / keyboard-interactive support may be incomplete | Validate with a PoC before implementation. Fill any gaps at the swift-nio-ssh layer |
| **Integrating Zig cross-compilation into CI** | Build reproducibility | Standardize XCFramework generation through `make` and attach artifacts to releases |
| **Memory pressure from Kitty Graphics** | Repeated large images may trigger memory warnings | Add limits and eviction to `ImageStore` |

---

## 12. Roadmap

- **v0.1** — a working baseline with connection / authentication / PTY / CoreText rendering
- **v1.0** — Metal renderer, True Color, Kitty Graphics, key management, reconnection
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
