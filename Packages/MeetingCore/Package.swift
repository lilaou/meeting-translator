// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "MeetingCore", targets: ["MeetingCore"])],
    targets: [
        .target(name: "MeetingCore"),
        .testTarget(name: "MeetingCoreTests", dependencies: ["MeetingCore"]),
    ],
    swiftLanguageModes: [.v6]
)
