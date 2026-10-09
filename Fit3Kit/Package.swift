// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Fit3Kit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Fit3Kit", targets: ["Fit3Kit"]),
    ],
    targets: [
        // Pure protocol code (no CoreBluetooth) so it can be tested on the Mac.
        .target(name: "Fit3Kit"),
        // `swift run Fit3KitChecks` — plain executable so it works without full Xcode/XCTest.
        .executableTarget(name: "Fit3KitChecks", dependencies: ["Fit3Kit"]),
    ]
)
