// swift-tools-version: 6.0
import PackageDescription

/// A second `TerminalEngine` on libghostty-vt, from the #10 comparison. It is no longer
/// outside the app's build graph: `project.yml` makes this package a dependency of the iOSSH
/// target, so every build of the app and of CI compiles and links it. SwiftTerm is still the
/// engine the Settings picker starts on; this one ships alongside it as a selectable trial.
///
/// The library has no tagged release and an API documented as unstable, so
/// `scripts/build_ghostty_vt.sh` pins a single Ghostty revision and produces the xcframework
/// the binary target below expects. `make bootstrap` runs that script when the xcframework is
/// missing. Because the code ships, its MIT notice is declared in
/// `scripts/generate_third_party_notices.py` — a binary target has no Package.resolved pin.
let package = Package(
    name: "GhosttyEngine",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "GhosttyEngine", targets: ["GhosttyEngine"])],
    dependencies: [.package(path: "../../Packages/TerminalCore")],
    targets: [
        .binaryTarget(name: "GhosttyVt", path: "../../build/vendor/ghostty-vt.xcframework"),
        .target(name: "GhosttyEngine", dependencies: ["GhosttyVt", .product(name: "TerminalCore", package: "TerminalCore")]),
        .testTarget(name: "GhosttyEngineTests", dependencies: ["GhosttyEngine", .product(name: "TerminalCore", package: "TerminalCore")])
    ]
)
