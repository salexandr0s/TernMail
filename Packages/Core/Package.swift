// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GmailAPI", targets: ["GmailAPI"]),
    ],
    targets: [
        .target(name: "GmailAPI"),
        .testTarget(name: "GmailAPITests", dependencies: ["GmailAPI"]),
    ]
)
