// swift-tools-version: 6.0
import Foundation
import PackageDescription

let commandLineToolsTestingPath = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let commandLineToolsTestingLibraryPath = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
let needsCommandLineToolsTestingPath = FileManager.default.fileExists(
    atPath: commandLineToolsTestingPath + "/Testing.framework"
)
let testingSwiftSettings: [SwiftSetting] = needsCommandLineToolsTestingPath
    ? [.unsafeFlags(["-F", commandLineToolsTestingPath])]
    : []
let testingLinkerSettings: [LinkerSetting] = needsCommandLineToolsTestingPath
    ? [.unsafeFlags([
        "-F", commandLineToolsTestingPath,
        "-framework", "Testing",
        "-Xlinker", "-rpath",
        "-Xlinker", commandLineToolsTestingPath,
        "-Xlinker", "-rpath",
        "-Xlinker", commandLineToolsTestingLibraryPath
    ])]
    : []

let package = Package(
    name: "AutoMacro",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AutoMacro", targets: ["AutoMacroApp"])
    ],
    targets: [
        .executableTarget(
            name: "AutoMacroApp",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "AutoMacroAppTests",
            dependencies: ["AutoMacroApp"],
            swiftSettings: testingSwiftSettings,
            linkerSettings: testingLinkerSettings
        )
    ]
)
