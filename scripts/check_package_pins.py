#!/usr/bin/env python3
"""Fail when the Xcode workspace and the local packages pin different versions.

Usage:
  python3 scripts/check_package_pins.py

`make test` resolves through each local package's own Package.resolved, while
`make build`, `make test-ui` and any archive resolve through the workspace's
copy. Nothing makes SwiftPM reconcile the two, so a dependency bump applied to
one side alone leaves CI testing a different dependency graph than the one the
app links -- which is how #25 shipped swift-nio-ssh 0.3.7's tests against an
app built on 0.3.6. This compares every shared pin and performs no network
requests, so it is cheap enough to run before anything else in CI.
"""

import json
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parent.parent
WORKSPACE = ROOT / "iOSSH.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

# Build products and SwiftPM's own scratch directories hold resolved files that
# are copies of these, not sources of truth, so only the checked-in ones count.
IGNORED_DIRECTORIES = {".build", ".git", "build"}


def resolved_files():
    for path in sorted(ROOT.rglob("Package.resolved")):
        if path == WORKSPACE:
            continue
        if IGNORED_DIRECTORIES.intersection(path.relative_to(ROOT).parts):
            continue
        yield path


def pins(path):
    """Map each pinned dependency to the identity of the commit it resolves to.

    Version and revision are both compared: a moved tag changes the revision
    while leaving the version alone, and a branch pin has no version at all.
    """
    document = json.loads(path.read_text(encoding="utf-8"))
    return {
        pin["identity"]: (pin["state"].get("version"), pin["state"].get("revision"))
        for pin in document["pins"]
    }


def main():
    workspace = pins(WORKSPACE)
    disagreements = []
    for path in resolved_files():
        for identity, state in sorted(pins(path).items()):
            # A pin the workspace has never heard of is the same failure one step earlier: a
            # dependency added to a local package without refreshing the workspace resolves for
            # `make test` and is missing from the app's graph until someone notices.
            if workspace.get(identity) != state:
                disagreements.append((path.relative_to(ROOT), identity, state, workspace.get(identity)))

    def describe(state):
        if state is None:
            return "nothing"
        version, revision = state
        return f"{version or 'unversioned'} ({(revision or '?')[:12]})"

    for path, identity, package_state, workspace_state in disagreements:
        print(f"{identity}: {path} pins {describe(package_state)}, "
              f"workspace pins {describe(workspace_state)}", file=sys.stderr)
    if disagreements:
        print("\nRefresh the workspace with:\n"
              "  xcodebuild -resolvePackageDependencies -project iOSSH.xcodeproj -scheme iOSSH",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
