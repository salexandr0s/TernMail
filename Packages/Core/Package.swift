// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GmailAPI", targets: ["GmailAPI"]),
        .library(name: "MailStore", targets: ["MailStore"]),
        .library(name: "MessageContent", targets: ["MessageContent"]),
        .library(name: "SyncEngine", targets: ["SyncEngine"]),
        .library(name: "TernAI", targets: ["TernAI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
        .package(url: "https://github.com/scinfu/SwiftSoup", exact: "2.14.3"),
    ],
    targets: [
        .target(name: "GmailAPI"),
        .target(name: "TernAI"),
        .target(name: "IMAPIdle", dependencies: ["GmailAPI"]),
        .target(name: "MailStore", dependencies: [.product(name: "GRDB", package: "GRDB.swift"), "GmailAPI", "MessageContent"]),
        .target(name: "MessageContent", dependencies: ["GmailAPI", "SwiftSoup"]),
        .target(name: "SyncEngine", dependencies: ["GmailAPI", "MailStore", "MessageContent"]),
        .testTarget(name: "GmailAPITests", dependencies: ["GmailAPI"]),
        .testTarget(name: "TernAITests", dependencies: ["TernAI"]),
        .testTarget(name: "IMAPIdleTests", dependencies: ["IMAPIdle"]),
        .testTarget(name: "MailStoreTests", dependencies: ["MailStore", "GmailAPI", "MessageContent"]),
        .testTarget(name: "MessageContentTests", dependencies: ["MessageContent"]),
        .testTarget(name: "SyncEngineTests", dependencies: ["SyncEngine", "GmailAPI", "MailStore"]),
    ]
)
