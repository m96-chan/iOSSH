// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TerminalCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "TerminalCore", targets: ["TerminalCore"])],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")
    ],
    targets: [
        .target(name: "TerminalCore", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]),
        .testTarget(name: "TerminalCoreTests", dependencies: ["TerminalCore"])
    ],
    swiftLanguageModes: [.v6]
)
