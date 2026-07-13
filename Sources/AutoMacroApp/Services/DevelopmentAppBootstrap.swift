import AppKit
import Darwin
import Foundation

final class AutoMacroAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        do {
            guard try DevelopmentAppBootstrap.relaunchIfNeeded() else { return }
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            fputs("Auto Macro development bundle bootstrap failed: \(error)\n", stderr)
        }
    }
}

/// `swift run` normally launches a bare Mach-O executable. TCC privacy grants
/// are tied to that changing build artifact, so every rebuild can look like a
/// different app to macOS. In development we copy the current executable into
/// a consistently identified, ad-hoc-signed app bundle and relaunch it once.
enum DevelopmentAppBootstrap {
    private static let bundleIdentifier = "app.automacro.desktop.development"
    private static let appName = "Auto Macro Development.app"

    static func relaunchIfNeeded() throws -> Bool {
        guard Bundle.main.bundleURL.pathExtension.lowercased() != "app" else { return false }

        let fileManager = FileManager.default
        let applicationsDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        let installedApp = applicationsDirectory.appendingPathComponent(appName, isDirectory: true)
        let stagingApp = applicationsDirectory
            .appendingPathComponent(".AutoMacro-Development-\(UUID().uuidString).app", isDirectory: true)
        let executableDirectory = stagingApp.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let resourcesDirectory = stagingApp.appendingPathComponent("Contents/Resources", isDirectory: true)
        defer { try? fileManager.removeItem(at: stagingApp) }

        try fileManager.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resourcesDirectory, withIntermediateDirectories: true)

        let sourceExecutable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let targetExecutable = executableDirectory.appendingPathComponent("AutoMacro")
        try fileManager.copyItem(at: sourceExecutable, to: targetExecutable)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: targetExecutable.path)

        if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns") {
            try fileManager.copyItem(
                at: iconURL,
                to: resourcesDirectory.appendingPathComponent("AppIcon.icns")
            )
        }
        let version = developmentVersion()
        let info: [String: Any] = [
            "CFBundleDevelopmentRegion": "ko",
            "CFBundleDisplayName": "Auto Macro (Development)",
            "CFBundleExecutable": "AutoMacro",
            "CFBundleIconFile": "AppIcon",
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "Auto Macro Development",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0",
            "NSHighResolutionCapable": true,
            "NSInputMonitoringUsageDescription": "사용자가 기록을 시작한 동안 키보드와 마우스 동작을 함께 기록하여 정확한 매크로를 만듭니다.",
            "NSScreenCaptureUsageDescription": "선택한 화면의 변화를 기록하고 화면 조건을 인식하기 위해 화면 기록 권한이 필요합니다."
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: stagingApp.appendingPathComponent("Contents/Info.plist"), options: .atomic)

        let signingIdentity = ProcessInfo.processInfo.environment["AUTO_MACRO_CODESIGN_IDENTITY"] ?? "-"
        let selfSignedCertificateSHA1 = ProcessInfo.processInfo.environment[
            "AUTO_MACRO_SELF_SIGNED_CERT_SHA1"
        ]
        var signingArguments = ["--force", "--deep", "--sign", signingIdentity]
        if signingIdentity == "-" {
            signingArguments += [
                "--requirements", "=designated => identifier \"\(bundleIdentifier)\""
            ]
        } else if let selfSignedCertificateSHA1, !selfSignedCertificateSHA1.isEmpty {
            signingArguments += [
                "--options", "runtime",
                "--timestamp=none",
                "--requirements",
                "=designated => identifier \"\(bundleIdentifier)\" and anchor = H\"\(selfSignedCertificateSHA1)\""
            ]
        } else {
            signingArguments += ["--options", "runtime", "--timestamp"]
        }
        signingArguments.append(stagingApp.path)
        try run("/usr/bin/codesign", arguments: signingArguments)

        if fileManager.fileExists(atPath: installedApp.path) {
            try fileManager.removeItem(at: installedApp)
        }
        try fileManager.moveItem(at: stagingApp, to: installedApp)
        try run("/usr/bin/open", arguments: ["-n", installedApp.path])
        return true
    }

    private static func run(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad)
        }
    }

    private static func developmentVersion() -> String {
        if let environmentVersion = ProcessInfo.processInfo.environment["AUTO_MACRO_VERSION"] {
            return environmentVersion.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["describe", "--tags", "--abbrev=0"]
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "0.0.0-dev" }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let value = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        else { return "0.0.0-dev" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }
}
