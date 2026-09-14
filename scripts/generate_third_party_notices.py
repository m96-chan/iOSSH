#!/usr/bin/env python3
"""Generate the application's notices from its resolved dependency revisions.

Usage:
  python3 scripts/generate_third_party_notices.py --checkouts PATH
  python3 scripts/generate_third_party_notices.py --checkouts PATH --check

PATH is Xcode's SourcePackages/checkouts directory. This performs no network
requests. The few upstream licenses omitted from those checkouts are preserved
in third_party_licenses, with their source revisions and hashes below.

libghostty-vt is linked as a binary target rather than a resolved package, so it
never appears in Package.resolved and has to be declared here instead; its
revision is read from scripts/build_ghostty_vt.sh so the pin lives in one place.

When dependencies change, review PACKAGES / EXCLUDED against iOSSH.LinkFileList
and review bundled C sources. Unknown dependencies and changed upstream inputs
fail generation instead of silently omitting their notices.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "App/Resources/ThirdPartyNotices.txt"
RESOLVED = ROOT / "iOSSH.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

# Library dependencies linked into iOSSH, including the runtime-library
# exceptions on Atomics and Collections. CLI/example/test-only targets are not
# included just because their packages occur in Package.resolved.
PACKAGES = {
    "bigint": "BigInt",
    "citadel": "Citadel",
    "swift-asn1": "swift-asn1",
    "swift-atomics": "swift-atomics",
    "swift-collections": "swift-collections",
    "swift-crypto": "swift-crypto",
    "swift-log": "swift-log",
    "swift-nio": "swift-nio",
    "swift-nio-ssh": "swift-nio-ssh",
    "swiftterm": "SwiftTerm",
}
EXCLUDED = {
    "swift-argument-parser",  # SwiftTerm's termcast executable only.
    "swift-system",  # NIOFS / _NIOFileSystem; iOSSH uses neither target.
}

# libghostty-vt ships in every build: project.yml makes GhosttyEngine a
# dependency of the iOSSH target and its manifest links the xcframework that
# GHOSTTY_BUILD_SCRIPT produces. A .binaryTarget has no Package.resolved pin, so the
# notice is declared here. GHOSTTY_LICENSE_REVISION records which revision the
# preserved LICENSE text was taken from; generation fails when the build
# script's GHOSTTY_REF moves past it, so the pin cannot leave this stale.
GHOSTTY_REPOSITORY = "https://github.com/ghostty-org/ghostty"
GHOSTTY_BUILD_SCRIPT = ROOT / "scripts/build_ghostty_vt.sh"
GHOSTTY_LICENSE_REVISION = "0c2a290d3a3e2a599be3a43435d778a5896667ee"
GHOSTTY_LICENSE_SHA256 = "386211873e5b7a02f663ae4d7adf96285999f91608f8f9f31fecfd0f4095e6f1"

BORINGSSL_REVISION = "0226f30467f540a3f62ef48d453f93927da199b6"
USHET_REVISION = "c09e0acafd86720efe42dc15c63e0cc228244c32"
UPSTREAM_LICENSES = [
    (
        "uSHET cpp_magic.h (used by SwiftNIO CNIOAtomics)",
        "uSHET-LICENSE.txt",
        f"https://raw.githubusercontent.com/18sg/uSHET/{USHET_REVISION}/LICENSE",
        "62a279b6a64b37680b691436c3ac1c0f6e8eeb81d8ad0a05c1dfc68f2c9ca28a",
    ),
    (
        "BoringSSL (used by Swift Crypto)",
        "BoringSSL-LICENSE.txt",
        f"https://raw.githubusercontent.com/google/boringssl/{BORINGSSL_REVISION}/LICENSE",
        "827c8d8fc207c2392794eef9e00fe246f9f61fdcc132556c275be3dd8c3cd97f",
    ),
    (
        "fiat-crypto (included in BoringSSL)",
        "fiat-crypto-LICENSE.txt",
        f"https://raw.githubusercontent.com/google/boringssl/{BORINGSSL_REVISION}/third_party/fiat/LICENSE",
        "9eacbcb81be660840c714a560a9d65ba07913db98dd4baf969f78dd499fdd60f",
    ),
]


def git(checkout, *arguments):
    return subprocess.run(
        ["git", "-C", str(checkout), *arguments],
        check=True, capture_output=True, text=True, encoding="utf-8",
    ).stdout


def section(title, source, contents):
    body = "\n".join(line.rstrip() for line in contents.strip().splitlines())
    return f"{'=' * 72}\n{title}\nSource: {source}\n\n{body}\n"


def copyright_comment(source):
    """Preserve the complete copyright/permission block, excluding C code."""
    blocks = [block for block in re.findall(r"/\*(.*?)\*/", source, re.DOTALL)
              if "Copyright" in block and
              ("Redistribution" in block or "Permission to use" in block)]
    if len(blocks) != 1:
        raise ValueError("C license header changed; review the upstream notice")
    return "\n".join(re.sub(r"^\s*\* ?", "", line) for line in blocks[0].splitlines()).strip()


def preserved_license(filename, expected_hash):
    """Read a license text kept in third_party_licenses, rejecting local edits."""
    data = (ROOT / "scripts/third_party_licenses" / filename).read_bytes()
    if hashlib.sha256(data).hexdigest() != expected_hash:
        raise ValueError(f"Preserved upstream license changed: {filename}")
    return data.decode("utf-8")


def ghostty_revision():
    """The libghostty-vt commit the app links, as pinned by the build script."""
    script = GHOSTTY_BUILD_SCRIPT.read_text(encoding="utf-8")
    pinned = re.search(r'^GHOSTTY_REF="\$\{GHOSTTY_REF:-([0-9a-f]{40})\}"', script, re.MULTILINE)
    if pinned is None:
        raise ValueError("Cannot read GHOSTTY_REF from scripts/build_ghostty_vt.sh")
    if pinned[1] != GHOSTTY_LICENSE_REVISION:
        raise ValueError(
            f"GHOSTTY_REF is now {pinned[1]}; refetch scripts/third_party_licenses/"
            "ghostty-LICENSE.txt from that revision and update GHOSTTY_LICENSE_REVISION"
        )
    return pinned[1]


def ghostty_section():
    """Notice for the binary target, which Package.resolved cannot describe."""
    manifest = (ROOT / "spike/GhosttyEngine/Package.swift").read_text(encoding="utf-8")
    project = (ROOT / "project.yml").read_text(encoding="utf-8")
    if "ghostty-vt.xcframework" not in manifest or "GhosttyEngine" not in project:
        raise ValueError("The app no longer links libghostty-vt; drop its declared notice")
    revision = ghostty_revision()
    return section(
        "libghostty-vt — LICENSE",
        f"{GHOSTTY_REPOSITORY}/blob/{revision}/LICENSE",
        preserved_license("ghostty-LICENSE.txt", GHOSTTY_LICENSE_SHA256),
    )


def generate(checkouts):
    pins = {pin["identity"]: pin for pin in json.loads(RESOLVED.read_text())["pins"]}
    unknown = pins.keys() - PACKAGES.keys() - EXCLUDED
    missing = PACKAGES.keys() - pins.keys()
    if unknown or missing:
        raise ValueError(f"Review the library dependency list: unknown={sorted(unknown)}, missing={sorted(missing)}")

    def read(identity, path):
        # Read the pinned Git object, not potentially edited working files.
        return git(checkouts / PACKAGES[identity], "show", f"{pins[identity]['state']['revision']}:{path}")

    def source_url(identity, path):
        pin = pins[identity]
        return f"{pin['location'].removesuffix('.git')}/blob/{pin['state']['revision']}/{path}"

    result = ["Open source software used by iOSSH\n\n"
              "The following notices apply to the libraries included in iOSSH.\n"
              "Bundled font licenses are available separately under Font licenses.\n"]
    libraries = {}
    for identity, directory in PACKAGES.items():
        pin = pins[identity]
        filenames = git(checkouts / directory, "ls-tree", "--name-only", pin["state"]["revision"]).splitlines()
        licenses = sorted(name for name in filenames if name.upper().startswith(("LICENSE", "NOTICE")))
        if not any(name.upper().startswith("LICENSE") for name in licenses):
            raise ValueError(f"No root license found for {identity}")
        libraries[identity] = [section(
            f"{directory} {pin['state']['version']} — {filename}",
            source_url(identity, filename), read(identity, filename),
        ) for filename in licenses]
    # libghostty-vt is a linked library like the others, so it belongs in the
    # same alphabetical run even though it arrives as a binary target.
    libraries["ghostty"] = [ghostty_section()]
    for identity in sorted(libraries):
        result.extend(libraries[identity])

    for filename in ["blf.c", "blf.h", "bcrypt.c"]:
        path = f"Sources/CCitadelBcrypt/{filename}"
        result.append(section(
            f"Citadel — {filename}", source_url("citadel", path),
            copyright_comment(read("citadel", path)),
        ))

    # These upstream licenses are not copied by the Swift packages' vendoring
    # scripts. Check the references before reusing our preserved text.
    cpp_magic = read("swift-nio", "Sources/CNIOAtomics/src/cpp_magic.h")
    if f"/{USHET_REVISION}/lib/cpp_magic.h" not in cpp_magic:
        raise ValueError("SwiftNIO's cpp_magic.h source changed; review the uSHET license")
    crypto_manifest = read("swift-crypto", "Package.swift")
    revision = re.search(r"BoringSSL Commit: ([0-9a-f]{40})", crypto_manifest)
    if revision is None or revision[1] != BORINGSSL_REVISION:
        raise ValueError("Swift Crypto's BoringSSL revision changed; refresh its upstream licenses")
    for title, filename, url, expected_hash in UPSTREAM_LICENSES:
        contents = preserved_license(filename, expected_hash)
        if filename == "uSHET-LICENSE.txt":
            # jsmn appears in the upstream aggregate license, but iOSSH only
            # includes cpp_magic.h, not that JSON parser.
            contents = contents.split("jsmn Library", 1)[0]
        result.append(section(title, url, contents))
    return "\n".join(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkouts", type=Path, required=True)
    parser.add_argument("--check", action="store_true", help="fail if the committed notices need regeneration")
    args = parser.parse_args()
    try:
        notices = generate(args.checkouts)
        if args.check:
            if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != notices:
                raise ValueError("ThirdPartyNotices.txt is out of date; rerun without --check")
            print("Third-party notices match the resolved dependencies.")
        else:
            OUTPUT.parent.mkdir(parents=True, exist_ok=True)
            OUTPUT.write_text(notices, encoding="utf-8")
            print(f"Wrote {OUTPUT.relative_to(ROOT)}")
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Cannot generate third-party notices: {error}\n")


if __name__ == "__main__":
    main()
