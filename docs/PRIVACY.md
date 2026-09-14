# iOSSH Privacy Policy

[日本語](PRIVACY.jp.md)

Last updated: September 13, 2026

## About iOSSH

iOSSH is an SSH terminal app for iPhone and iPad. It does not require an iOSSH account. There is no built-in service that uploads your saved hosts, SSH credentials, or terminal contents to the developer. The app connects to servers you choose and uses the system and third-party services described below when you use those features.

## Information stored or processed on your device

| Information | Purpose and storage |
| --- | --- |
| Saved hosts | The host name or IP address, display name, port, SSH username, authentication method, terminal type, creation date, and an app-generated record identifier are stored in the app's local database so you can reconnect. |
| Saved credentials | Passwords, private keys, and private-key passphrases that you choose to save are stored in iOS Keychain. They are separate from the host database, require the currently enrolled Face ID or Touch ID for access, and are configured not to synchronize through iCloud Keychain or migrate to another device. Credentials entered for a connection are also processed in memory. |
| Trusted server keys | After you approve a server's host key, the app stores its hostname, port, key algorithm, and public key locally to recognize the server and detect key changes. |
| Terminal contents | Input, output, scrollback, terminal titles, and received terminal images are processed in memory. The app does not save a terminal transcript to disk. A disconnected tab can retain its output; hiding a tab or locking the screen does not clear it. |
| Tailscale import results | Hostnames and IP addresses received from Shortcuts, the derived display names, and import status/error messages are held in memory for review. Only hosts you select and save are added to the host database. |
| Fonts | Font files you select through Files are copied into the app's storage with their font names and library identifiers. Bundled and imported fonts are rendered locally. |
| Preferences | Font selection, font size, and color theme are saved in local app preferences. |

Face ID and Touch ID are handled by iOS. iOSSH receives an authentication result, not your face or fingerprint data. Changing enrolled biometrics or removing your device passcode can make saved credentials unavailable.

## SSH connections and remote servers

When you connect, your chosen SSH server receives the connection's network address, SSH username, authentication exchange, terminal configuration, and the input you send, including pasted text. The app receives the server's terminal output. Hostname lookup uses your device's configured network and DNS services, which may include Tailscale.

SSH encrypts the session traffic. With password authentication, the password is sent to the selected server within the encrypted session. With private-key authentication, signing happens locally; the authentication exchange sends the public key and signature, not the private key or its passphrase.

The server operator and the programs you run there control remote logs, shell history, files, and any onward transmission. Disconnecting or deleting a host in iOSSH does not delete information stored on a remote server.

## Tailscale, Shortcuts, and websites

Tailscale features use the Tailscale app and account you have configured separately. iOSSH does not ask for a Tailscale API token or store your Tailscale account password.

When you choose **Fetch Devices**, iOSSH opens Apple's Shortcuts app to run **Import Tailscale Hosts**. The supplied shortcut uses Tailscale's **Find Devices** action and passes device hostnames or IP addresses back to iOSSH for review. Tailscale and Shortcuts handle the device results during this operation. Saving or sharing the supplied shortcut file exports the workflow definition, which contains no device list or credentials.

For Tailscale SSH, access is checked using your existing Tailscale connection. If a server requests web approval, the app displays its message. Choosing the sign-in action opens the Tailscale HTTPS page in a system browser view; Tailscale and any identity provider involved handle that web sign-in. Opening the documentation link also contacts the linked website.

These services have their own privacy practices. See the [Tailscale Privacy Policy](https://tailscale.com/privacy-policy) and [Apple Privacy Policy](https://www.apple.com/legal/privacy/en-ww/). Your server or tailnet administrator may apply additional logging and access policies.

## Clipboard, Files, and system services

Copy places selected terminal text on the system clipboard. Paste reads clipboard text when you request a paste and sends it to the selected session. The app does not automatically upload clipboard contents to the developer. Clipboard sharing, including Apple's Universal Clipboard, follows your system settings.

Importing a font reads the file you select. A Files provider, such as a cloud-storage service, may download that file as part of your selection. Removing the imported font from iOSSH removes the app's copy, not the original file in that provider.

The app does not provide app-level iCloud or CloudKit synchronization. Ordinary app data, including host settings, trusted server keys, preferences, and imported fonts, may be included in device backups according to your iOS and backup settings. System backups and Files providers have their own retention and deletion controls.

## Analytics and diagnostics

The app has no advertising, cross-app tracking, developer analytics SDK, or automatic crash-report upload feature. It does not configure an external telemetry service. iOS and its system frameworks may produce diagnostics under Apple's policies and your device's analytics-sharing settings; this is separate from an iOSSH-operated reporting service.

For App Store apps, Apple may make crash information and usage statistics available to the developer according to your sharing choices. You can manage **Share With App Developers** in iOS **Settings → Privacy & Security → Analytics & Improvements**. See [Apple's App Analytics & Privacy notice](https://www.apple.com/uk/legal/privacy/data/en/app-analytics/).

## Retention and your controls

- Delete a saved host in the host list to remove its database entry and associated saved Keychain credential. This does not close an already-open session; close that session separately to stop the connection and discard its retained terminal contents.
- Trusted server keys are stored independently and remain after deleting a saved host. The current app has no individual host-key deletion control.
- Remove imported fonts in **Settings**. You can also change the appearance preferences there.
- Terminal buffers and unsaved import results are kept in memory, rather than a persistent session or import history. They are discarded when their owning session/state is released or the app process ends. A remote server may retain its own history.
- Deleting the app through iOS removes its app-container data. Offloading the app preserves documents and data. Do not rely on uninstalling to erase Keychain credentials; delete saved hosts first if you want their credentials removed. Backups, clipboard copies, exported shortcut files, and information held by other apps or servers are managed separately.
- You can stop using the Tailscale import feature and remove its shortcut in Shortcuts. Manage Tailscale permissions and account data in Tailscale, and app permissions such as Local Network and Face ID in iOS Settings.

## Privacy contact

Developer: **Yusuke Harada**.

Privacy contact: [me+iossh@m96-chan.dev](mailto:me+iossh@m96-chan.dev).

Use that contact for questions or requests about this policy. Information stored only on your device or your chosen server is not available to the developer through iOSSH; the controls above and the relevant service administrator govern that information.

## Changes

Updates to this policy will show a revised date above. The policy for a release should describe that release's actual behavior.
