# App Store release draft

English | [日本語](APP_STORE.jp.md)

These fields describe the implemented app. The first submission was returned on
September 16, 2026 under Guideline 2.1 for additional review information; Apple
did not cite a defect in the binary. The release uses the individual Apple
Developer membership and bundle identifier `io.github.m96-chan.iossh`.

This installs separately from previous `moe.technologies.iossh` development
builds. Saved hosts, credentials, settings, and imported fonts do not migrate
automatically. Replace **Import Tailscale Hosts** with the shortcut exported
from the new app before fetching devices; see the [migration steps](../shortcuts/README.md#updating-from-the-previous-app-identifier).

## Store listing

- Intended publisher: **Yusuke Harada**, as an individual
- Name: **iOSSH**
- Subtitle: **SSH terminal for iPhone & iPad**
- Suggested category: **Developer Tools**
- Keywords: `ssh,terminal,shell,server,console,developer,linux,remote`

### Description

iOSSH brings your remote shell to iPhone and iPad. Save your SSH hosts, connect
with a password or supported private key, and work in a terminal with color,
scrollback, copy and paste, and hardware keyboard support.

On iPad, switch between up to four connection tabs and show or hide the host
sidebar to fit your workspace. On iPhone, focus on one terminal at a time.

HackGen Console NF and Noto Sans CJK JP are included for Japanese text and shell
prompt symbols. Adjust the font size and theme, or import a monospaced TTF or OTF
font from Files. The terminal also displays supported Kitty graphics transfers.

Using Tailscale SSH? Connect through the Tailscale app and import selected devices
with Tailscale's official Shortcuts action. Setup requires the Tailscale app, a
connected tailnet, and the bundled shortcut. Your server and tailnet must allow
the SSH connection.

iOSSH supports password authentication, OpenSSH Ed25519 keys, and unencrypted
ECDSA PEM keys. RSA keys and keyboard-interactive authentication are currently
unsupported.

Returning to the app resumes the same shell while its connection remains alive.
Reconnecting after a lost connection starts a new shell; use a remote terminal
multiplexer when you need sessions to survive connection loss.

## Review preparation

The app has no iOSSH account or subscription login. Testing a terminal requires
an SSH server that accepts a supported authentication method. Supply a maintained
review server and its credentials in App Review Information before submission;
do not put credentials in this repository. The simulator-only UI test fixtures
are not a review server or a release demo mode.

Tailscale is optional. Reviewers can test ordinary SSH without Tailscale. Its
device import flow requires adding **Import Tailscale Hosts** from **Import from
Tailscale → Set Up Shortcut**, then using **Fetch Devices** and selecting hosts
before registration.

## Guideline 2.1 review response

Apple requested the following information for submission
`9afe9cac-389d-4f2d-bb18-7f378de6ccf3`. Paste the completed response both into
the App Store Connect conversation and **App Review Information → Notes**.
Replace every bracketed value there; the review server credentials and recording
must remain outside this repository.

### Copy-ready response

```text
Thank you for reviewing iOSSH. Please find the requested information below.

1. Physical-device screen recording

[Attach or link a recording made on a physical iPhone or iPad.] The recording
starts from app launch and shows the typical flow: adding the review SSH host,
connecting with the supplied credentials, using the live terminal, and
disconnecting.

iOSSH has no app-specific account registration, login, or account deletion.
It does not host user-generated content and therefore has no reporting or
blocking flow. It has no paid digital content, subscriptions, or in-app
purchases.

2. Purpose and target audience

iOSSH is an SSH terminal client for iPhone and iPad. It is intended for
developers, system administrators, and other technical users who need to access
servers from a mobile device. Its main features are a standards-compatible
terminal, password and supported private-key authentication, Unicode and
Japanese input, hardware-keyboard support, configurable fonts and themes,
Kitty graphics display, and up to four simultaneous session tabs on iPad.

3. Setup instructions and review credentials

No iOSSH account is required. To test the main functionality:
1) Launch iOSSH and choose Add Host.
2) Enter the SSH host, port, username, and Password authentication shown below.
3) Save the host, select it, enter the supplied password, and approve the host
   key when prompted.
4) Run commands in the terminal. Use the close button or Terminal options >
   Disconnect when finished.

SSH host: [APP STORE CONNECT ONLY]
Port: [APP STORE CONNECT ONLY]
Username: [APP STORE CONNECT ONLY]
Authentication: Password
Password: [APP STORE CONNECT ONLY]

The credentials will remain active throughout the review. Tailscale import is
an optional feature and is not required to review the SSH terminal. If desired,
it requires the separately installed Tailscale app and a configured tailnet;
Import from Tailscale > Set Up Shortcut installs the bundled shortcut, and Fetch
Devices runs Tailscale's official Find Devices Shortcuts action.

4. External services, tools, and platforms

iOSSH has no developer-operated backend, account service, analytics service,
advertising service, payment processor, or AI service. Its core network function
connects directly to SSH servers selected and controlled by the user. Tailscale
is optional and is accessed through the Tailscale app and its official Find
Devices Shortcuts action without an API token. The app includes open-source SSH,
cryptography, terminal parsing, and rendering libraries, including Citadel,
swift-nio-ssh, swift-crypto, SwiftTerm, and libghostty-vt.

5. Regional differences

There are no regional differences in features or behavior. iOSSH functions
consistently in every region where it is distributed. English and Japanese text
support and the bundled CJK font are localization features, not regional
restrictions.

6. Regulated industry and third-party material

iOSSH is a general-purpose developer tool and does not operate in a regulated
industry. It does not bundle licensed entertainment or other protected
third-party content. Its bundled third-party software and fonts are open source,
and their license notices are available in Settings > Open source licenses.
Content displayed during an SSH session comes from a server selected by the
user and is not supplied by iOSSH.
```

## Resubmission checklist

- Keep a dedicated review SSH server online for the entire review window. Put
  its host, port, username, and password only in App Store Connect.
- Record the complete flow on a physical device: launch → add the review host →
  connect → use the terminal → disconnect. Attach the recording to the review
  reply.
- Paste the completed response above into both the review conversation and
  **App Review Information → Notes**.
- Replace any store screenshot that exposes a private hostname, username, IP
  address, terminal history, or third-party media. Screenshots must show the app
  in use with review-safe test data.
- Reconfirm App Privacy, age rating, export compliance, pricing, availability,
  privacy policy URL, support URL, review contact, and the selected build before
  resubmitting.

## Release records and recurring checks

- The public [privacy policy](PRIVACY.md) and [support page](SUPPORT.md) must stay
  registered in App Store Connect and match the links in **Settings → About**.
- App Privacy, age rating, and encryption/export compliance must be reviewed for
  every release. SSH uses cryptography through its dependencies;
  `ITSAppUsesNonExemptEncryption` remains deliberately unset so App Store
  Connect receives an explicit answer rather than an inferred one.
- Verify the shipped software notices under **Settings → Open source licenses**
  and the separate bundled font licenses. The software notices are generated;
  `scripts/generate_third_party_notices.py --check` fails when they drift from
  what the app links, including libghostty-vt, which ships in every build but
  has no `Package.resolved` pin to be discovered from.
- Capture store screenshots from the final iPhone and iPad build with review-safe
  test hosts and no private server information. Complete the physical-device
  checks listed in [development notes](DEVELOPMENT.md).
- Confirm the review contact and working SSH review access before every
  submission.

Apple references: [Create an app record](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app),
[upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds),
[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).
