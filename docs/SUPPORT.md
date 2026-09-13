# iOSSH Support

English | [日本語](SUPPORT.jp.md)

> Publication draft. Set this page's public URL before using it as the App Store
> Support URL. The URL has not yet been provided.

iOSSH is an SSH terminal for iPhone and iPad.

## Contact

Developer: Yusuke Harada

Support email: [me+iossh@m96-chan.dev](mailto:me+iossh@m96-chan.dev).

For a bug report, include your device model, iOS/iPadOS version, iOSSH version,
and the steps that led to the problem. If you attach terminal output or a
screenshot, remove passwords, private keys, and private server information.

## Connection help

The server must be reachable from your device and allow SSH access. Check its
hostname or IP address, SSH port, username, and authentication method. iOSSH
currently supports passwords, OpenSSH Ed25519 keys, and unencrypted ECDSA PEM
keys. RSA and keyboard-interactive authentication are not supported.

For Tailscale SSH, connect the Tailscale app to your tailnet first. Enable
Tailscale SSH on the server and allow access in the tailnet policy. Device import
uses the official Tailscale Shortcuts action; follow the
[shortcut setup instructions](../shortcuts/README.md).

If an SSH connection stays alive while the app is in the background, returning
resumes the same shell. A lost connection requires a new shell. A remote
multiplexer can preserve shell work across a lost connection.

## Fonts and appearance

Open **Settings** to change the theme, text size, or font. Japanese text and
prompt symbols are supported by the bundled HackGen Console NF and Noto Sans
CJK JP fonts. You can import additional monospaced TTF/OTF files from Files.

Read the [privacy policy](PRIVACY.md) for data storage, service interactions,
and deletion controls.
