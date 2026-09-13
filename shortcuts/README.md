# Import Tailscale Hosts

[Import Tailscale Hosts.shortcut](Import%20Tailscale%20Hosts.shortcut) is the signed
workflow bundled with iOSSH for iPhone and iPad. Install Tailscale and connect to
your tailnet, then add the shortcut once:

1. In iOSSH, open **Import from Tailscale** → **Set Up Shortcut**.
2. Tap **Save Shortcut File**, choose **Save to Files**, and save the file.
3. Open the saved `.shortcut` file in Files, then tap **Add Shortcut**.
4. Keep its name **Import Tailscale Hosts**. Return to iOSSH and tap **Fetch Devices**.

Allow access when Shortcuts asks to pass Tailscale results to iOSSH. You can also
open the linked `.shortcut` file above and add it directly.

For manual setup, expand **Create Manually** in **Set Up Shortcut**. Create a
shortcut named **Import Tailscale Hosts** with **Tailscale → Find Devices** and
**iOSSH → Review Tailscale Hosts**. Bind **Hostnames** to the **MagicDNS Address**
property of the Devices result; **IPv4 Address** or **IPv6 Address** can be used
instead. Leave Find Devices unfiltered. The bundled workflow additionally
chooses a fallback address for each device automatically.

The workflow uses Tailscale's official **Find Devices** action without filters or
a result limit. It chooses each device's **MagicDNS Address**, then **IPv4
Address**, then **IPv6 Address**, and passes the addresses to iOSSH's **Review
Tailscale Hosts** action. Review and select hosts inside iOSSH before saving.
Device discovery does not establish whether a device runs SSH or permits your
connection. The file contains no API token, credentials, or device list.

The signed file and [XML source](Import%20Tailscale%20Hosts.source.plist) are
generated with:

```sh
python3 scripts/generate_tailscale_shortcut.py --sign
```

Run this from the repository root on a Mac. Omit `--sign` to regenerate just the
reviewable XML. Signing uses Apple's `shortcuts sign --mode anyone`; its input
must have the `.shortcut` extension, so the script creates a temporary copy.
The script never runs the workflow or requests devices.
`project.yml` bundles the signed file from this directory directly; a second
copy under `App/Resources` is unnecessary.

Serialization was checked against macOS 26.5 and Tailscale 1.102.3 action
metadata; the workflow targets the iOS bundle `io.tailscale.ipn.ios`. The final
action's bundle, intent identifier, `hostnames` string-array parameter, and
`openAppWhenRun` behavior match the built iOSSH App Intents metadata. The signing,
XML structure, and address fallback were checked locally. End-to-end discovery
and import, including an empty device result, must also be checked on an iPhone
or iPad with both apps installed.

References: [Tailscale Shortcuts actions](https://tailscale.com/docs/features/mac-ios-shortcuts),
[Apple Shortcuts command line](https://support.apple.com/guide/shortcuts-mac/run-shortcuts-from-the-command-line-apd455c82f02/mac).
