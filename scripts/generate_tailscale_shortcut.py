#!/usr/bin/env python3
"""Generate the reviewable source for Import Tailscale Hosts; never query devices.

Generate and sign on macOS with:
  python3 scripts/generate_tailscale_shortcut.py --sign

Action/property serialization was checked against macOS 26.5 WorkflowKit and
Tailscale 1.102.3's App Intents metadata. The generated workflow targets iOS.
"""

from pathlib import Path
import argparse
import plistlib
import subprocess
import tempfile
import uuid


NAME = "Import Tailscale Hosts"
TAILSCALE_BUNDLE = "io.tailscale.ipn.ios"
APP_BUNDLE = "io.github.m96-chan.iossh"
NAMESPACE = uuid.UUID("4de1b0ad-e411-4b91-91e3-0b9a94e0489f")


def identifier(name):
    return str(uuid.uuid5(NAMESPACE, name)).upper()


def action(action_id, name, **parameters):
    return {
        "WFWorkflowActionIdentifier": action_id,
        "WFWorkflowActionParameters": {"UUID": identifier(name), **parameters},
    }


def output(name, display_name):
    return {
        "Type": "ActionOutput",
        "OutputUUID": identifier(name),
        "OutputName": display_name,
    }


def attachment(value):
    return {"Value": value, "WFSerializationType": "WFTextTokenAttachment"}


def text_tokens(values, separator="\n"):
    # Every token and separator here occupies one UTF-16 code unit.
    return {
        "Value": {
            "string": separator.join("\ufffc" for _ in values),
            "attachmentsByRange": {
                "{%d, 1}" % (i * (1 + len(separator))): value
                for i, value in enumerate(values)
            },
        },
        "WFSerializationType": "WFTextTokenString",
    }


def device_property(name):
    return {
        "Type": "Variable",
        "VariableName": "Repeat Item",
        "Aggrandizements": [{
            "Type": "WFPropertyVariableAggrandizement",
            "PropertyName": name,
            "PropertyUserInfo": {
                "WFLinkEntityContentPropertyUserInfoPropertyIdentifier": name,
            },
        }],
    }


def app_descriptor(bundle, intent, name):
    return {
        "ActionRequiresAppInstallation": True,
        "AppIntentIdentifier": intent,
        "BundleIdentifier": bundle,
        "Name": name,
    }


def workflow():
    repeat_group = identifier("repeat-group")
    return {
        "WFWorkflowName": NAME,
        "WFWorkflowClientRelease": "17.0",
        "WFWorkflowClientVersion": "2306.0.3",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowIcon": {
            "WFWorkflowIconStartColor": 4282601983,
            "WFWorkflowIconGlyphNumber": 59795,
        },
        "WFWorkflowTypes": [],
        "WFWorkflowInputContentItemClasses": [],
        "WFWorkflowImportQuestions": [],
        "WFWorkflowActions": [
            action("is.workflow.actions.comment", "comment", WFCommentActionText=(
                "Requires Tailscale and iOSSH on this iPhone or iPad. "
                "Find Devices uses your current Tailscale account. "
                "For each device, prefer MagicDNS Address, then IPv4 Address, "
                "then IPv6 Address. iOSSH shows the results for you to select "
                "and register; this shortcut does not connect to SSH servers."
            )),
            action(
                TAILSCALE_BUNDLE + ".DeviceAppEntity", "find",
                AppIntentDescriptor=app_descriptor(
                    TAILSCALE_BUNDLE, "DeviceAppEntity", "Tailscale"
                ),
                WFContentItemLimitEnabled=False,
            ),
            action(
                "is.workflow.actions.repeat.each", "repeat-start",
                GroupingIdentifier=repeat_group,
                WFControlFlowMode=0,
                WFInput=attachment(output("find", "Devices")),
            ),
            action(
                "is.workflow.actions.gettext", "addresses",
                WFTextActionText=text_tokens([
                    device_property("magicDNSAddress"),
                    device_property("ipv4Address"),
                    device_property("ipv6Address"),
                ]),
            ),
            action(
                "is.workflow.actions.text.replace", "preferred-address",
                # Keep the first nonempty address; all missing yields empty text.
                # Avoid Get First Item, which would fail on an empty result list.
                WFReplaceTextFind=r"^\s*(\S*)[\s\S]*$",
                WFReplaceTextReplace="$1",
                WFReplaceTextRegularExpression=True,
                WFReplaceTextCaseSensitive=True,
                WFInput=text_tokens([output("addresses", "Text")]),
            ),
            action(
                "is.workflow.actions.repeat.each", "repeat-end",
                GroupingIdentifier=repeat_group,
                WFControlFlowMode=2,
            ),
            action(
                APP_BUNDLE + ".ReviewTailscaleHostsIntent", "review",
                AppIntentDescriptor=app_descriptor(
                    APP_BUNDLE, "ReviewTailscaleHostsIntent", "iOSSH"
                ),
                hostnames=attachment(output("repeat-end", "Repeat Results")),
            ),
        ],
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sign", action="store_true", help="Sign for sharing using macOS shortcuts sign")
    options = parser.parse_args()
    destination = Path(__file__).resolve().parents[1] / "shortcuts" / (NAME + ".source.plist")
    destination.parent.mkdir(parents=True, exist_ok=True)
    source = plistlib.dumps(workflow(), fmt=plistlib.FMT_XML, sort_keys=False)
    destination.write_bytes(source)
    print(destination)
    if options.sign:
        # The CLI rejects .plist input even when its contents are a valid workflow.
        with tempfile.TemporaryDirectory(prefix="iossh-shortcut-") as directory:
            unsigned = Path(directory) / (NAME + ".shortcut")
            unsigned.write_bytes(source)
            signed = destination.with_name(NAME + ".shortcut")
            subprocess.run([
                "shortcuts", "sign", "--mode", "anyone",
                "--input", str(unsigned), "--output", str(signed),
            ], check=True)
            signed.chmod(0o644)
            print(signed)
