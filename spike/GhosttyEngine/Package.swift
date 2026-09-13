// swift-tools-version: 6.0
import PackageDescription

/// Spike for #10: a second `TerminalEngine` on libghostty-vt, kept outside the app's build
/// graph. The library it links has no tagged release and an API documented as unstable, so
/// nothing here is built by the app or by CI until the comparison justifies adopting it.
///
/// Run `scripts/build_ghostty_vt.sh` first; it produces the xcframework this expects.
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
