// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GmailAPI", targets: ["GmailAPI"]),
        .library(name: "MailStore", targets: ["MailStore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
    ],
    targets: [
        .target(name: "GmailAPI"),
        .target(name: "MailStore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "GmailAPITests", dependencies: ["GmailAPI"]),
        .testTarget(name: "MailStoreTests", dependencies: ["MailStore"]),
    ]
)
