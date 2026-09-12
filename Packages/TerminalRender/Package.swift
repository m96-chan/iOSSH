// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TerminalRender",
    platforms: [.iOS(.v17)],
    products: [.library(name: "TerminalRender", targets: ["TerminalRender"])],
    dependencies: [.package(path: "../TerminalCore")],
    targets: [
        .target(
            name: "TerminalRender",
            dependencies: ["TerminalCore"],
            resources: [.copy("Shaders"), .copy("Fonts")]
        )
    ]
)
