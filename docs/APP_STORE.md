# App Store release draft

English | [日本語](APP_STORE.jp.md)

These fields describe the implemented app. They have not been submitted to App
Store Connect. The release uses the individual Apple Developer membership and
bundle identifier `io.github.m96-chan.iossh`.

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

## Remaining release inputs

- Verify the new bundle ID with the distribution team, then create the
  App Store Connect app record and validate the signed archive.
- Confirm the store name's availability, primary language, price, and countries.
- Finalize and publish the [privacy policy draft](PRIVACY.md), including a real
  contact method, and the [support page draft](SUPPORT.md). Add accessible links
  inside the app as well as the public URLs in App Store Connect.
- Complete App Privacy, the age rating, and encryption/export compliance answers
  based on the shipped app. SSH uses cryptography through its dependencies;
  `ITSAppUsesNonExemptEncryption` has not been guessed or set automatically.
- Verify the shipped software notices under **Settings → Open source licenses**
  and the separate bundled font licenses.
- Capture store screenshots from the final iPhone and iPad build with test hosts
  and no private server information. Complete the physical-device checks listed
  in [development notes](DEVELOPMENT.md).
- Confirm the review contact and supply working SSH review access.

Apple references: [Create an app record](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app),
[upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds),
[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).
