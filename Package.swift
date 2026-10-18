// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZweiCommander",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ZweiCommander", targets: ["ZweiCommander"])],
    targets: [
        .target(name: "CArchive", linkerSettings: [.linkedLibrary("archive.2")]),
        .target(name: "CFileCopy"),
        .target(name: "CommanderCore", dependencies: ["CArchive", "CFileCopy"]),
        .executableTarget(name: "ZweiCommander", dependencies: ["CommanderCore"]),
        .executableTarget(name: "CommanderCoreTests", dependencies: ["CommanderCore", "CArchive"], path: "Tests/CommanderCoreTests")
    ]
)
