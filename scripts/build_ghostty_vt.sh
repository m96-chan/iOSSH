#!/bin/bash
# Builds libghostty-vt as an xcframework (iOS device, iOS simulator, macOS) into
# build/vendor/, where the spike package in spike/GhosttyEngine expects it.
#
# libghostty-vt has no tagged release and its C API is documented as unstable, so the
# commit is pinned here rather than tracking a branch.
#
# Requires Zig (tested with 0.16.0): brew install zig
set -euo pipefail

# Pinned. Moving this is a deliberate act: the C API is documented as unstable.
GHOSTTY_REF="${GHOSTTY_REF:-0c2a290d3a3e2a599be3a43435d778a5896667ee}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${ROOT}/build/ghostty-src"
OUT="${ROOT}/build/ghostty-out"

command -v zig >/dev/null || { echo "Install Zig: brew install zig"; exit 1; }

if [ ! -d "${WORK}/.git" ]; then
    git init -q "${WORK}"
    git -C "${WORK}" remote add origin https://github.com/ghostty-org/ghostty.git
fi
# Fetching the commit rather than cloning a branch, so a pinned SHA works the same way a
# branch name does and the checkout stays shallow either way.
git -C "${WORK}" fetch -q --depth 1 origin "${GHOSTTY_REF}"
git -C "${WORK}" checkout -q FETCH_HEAD

cd "${WORK}"
zig build -Demit-lib-vt=true -Doptimize=ReleaseFast --prefix "${OUT}"

mkdir -p "${ROOT}/build/vendor"
rm -rf "${ROOT}/build/vendor/ghostty-vt.xcframework"
cp -R "${OUT}/lib/ghostty-vt.xcframework" "${ROOT}/build/vendor/"
echo "ghostty-vt.xcframework -> ${ROOT}/build/vendor/ghostty-vt.xcframework"
