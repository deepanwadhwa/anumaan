// swift-tools-version:5.9
import PackageDescription

// Pure-Swift navigation core for the Anumaan iOS app. No UIKit/CoreMotion here so
// it compiles and tests from the command line (`swift test`) on any platform.
// The iOS app target depends on this and feeds it CoreMotion-derived data.
let package = Package(
    name: "AnumaanCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AnumaanCore", targets: ["AnumaanCore"]),
    ],
    dependencies: [
        // Pure-Swift PNG decoder — no ImageIO/CoreGraphics, runs on macOS/Linux/Windows.
        .package(url: "https://github.com/tayloraswift/swift-png.git", from: "4.4.0"),
    ],
    targets: [
        .target(name: "AnumaanCore"),
        .executableTarget(name: "AnumaanSelfTest", dependencies: ["AnumaanCore"]),
        // Offline recovery simulator — platform-agnostic CLI, no Apple frameworks.
        // Runs on macOS, Linux, and Windows. The Python web app calls this binary.
        .executableTarget(name: "AnumaanSim", dependencies: [
            "AnumaanCore",
            .product(name: "PNG", package: "swift-png"),
        ]),
        .testTarget(name: "AnumaanCoreTests", dependencies: ["AnumaanCore"]),
    ]
)
