import AppKit
import Foundation

struct UpdateRelease: Equatable, Sendable {
    let version: String
    let downloadURL: URL
}

enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(UpdateRelease)
    case downloading
}

enum UpdateError: LocalizedError {
    case unsupportedInstallation
    case missingAsset
    case invalidArchive

    var errorDescription: String? {
        switch self {
        case .unsupportedInstallation:
            "업데이트는 설치된 ‘Auto Macro.app’에서만 사용할 수 있습니다. GitHub 릴리스 파일로 다시 설치해 주세요."
        case .missingAsset:
            "현재 Mac에 맞는 업데이트 파일을 찾지 못했습니다."
        case .invalidArchive:
            "다운로드한 업데이트 파일이 올바른 앱 번들이 아닙니다."
        }
    }
}

@MainActor
final class UpdateService {
    private static let repository = "hyuck0221/auto-macro"

    func checkForUpdate(currentVersion: String) async throws -> UpdateRelease? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("AutoMacro-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return nil }
        // A repository without a release is not an update error.
        guard httpResponse.statusCode != 404 else { return nil }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try Self.updateRelease(
            from: data,
            currentVersion: currentVersion,
            architecture: Self.currentArchitecture
        )
    }

    nonisolated static func updateRelease(
        from data: Data,
        currentVersion: String,
        architecture: String
    ) throws -> UpdateRelease? {
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !release.draft, !release.prerelease,
              Self.isNewer(release.tagName, than: currentVersion) else { return nil }

        let expectedName = "AutoMacro-\(release.tagName)-macos-\(architecture).zip"
        let asset = release.assets.first { $0.name == expectedName }
            ?? release.assets.first {
                $0.name.lowercased().hasSuffix("-macos-\(architecture.lowercased()).zip")
            }
        guard let asset else {
            throw UpdateError.missingAsset
        }
        return UpdateRelease(version: release.tagName, downloadURL: asset.browserDownloadURL)
    }

    func downloadAndInstall(_ release: UpdateRelease) async throws {
        let (temporaryURL, response) = try await URLSession.shared.download(from: release.downloadURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoMacro-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        try run("/usr/bin/ditto", arguments: ["-x", "-k", temporaryURL.path, stagingDirectory.path])
        let downloadedApp = stagingDirectory.appendingPathComponent("Auto Macro.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: downloadedApp.appendingPathComponent("Contents/MacOS/AutoMacro").path) else {
            throw UpdateError.invalidArchive
        }
        try verifyUpdateSignatureIfConfigured(downloadedApp)

        let installedApp = Bundle.main.bundleURL
        guard installedApp.pathExtension == "app" else { throw UpdateError.unsupportedInstallation }
        do {
            try scheduleReplacement(of: installedApp, with: downloadedApp)
        } catch {
            try? FileManager.default.removeItem(at: stagingDirectory)
            throw error
        }

        // Leave enough time for the detached replacement helper to start.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    private func scheduleReplacement(of target: URL, with source: URL) throws {
        let helperURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoMacro-update-helper-\(UUID().uuidString).zsh")
        let script = """
        #!/bin/zsh
        set -eu
        sleep 1
        target="$1"
        source="$2"
        rm -rf "$target"
        /usr/bin/ditto "$source" "$target"
        /usr/bin/open "$target"
        rm -rf "${source:h}" "${0}"
        """
        try script.write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)

        let parent = target.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: parent.path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [helperURL.path, target.path, source.path]
            try process.run()
        } else {
            let command = "/bin/zsh \(shellQuoted(helperURL.path)) \(shellQuoted(target.path)) \(shellQuoted(source.path)) >/dev/null 2>&1 &"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \(appleScriptQuoted(command)) with administrator privileges"]
            try process.run()
        }
    }

    private func run(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.invalidArchive }
    }

    private func verifyUpdateSignatureIfConfigured(_ appURL: URL) throws {
        guard let certificateSHA1 = Bundle.main.object(
            forInfoDictionaryKey: "AutoMacroSigningCertificateSHA1"
        ) as? String,
        certificateSHA1.count == 40,
        certificateSHA1.allSatisfy(\.isHexDigit)
        else { return }

        let requirement = "=designated => identifier \"app.automacro.desktop\" and anchor = H\"\(certificateSHA1)\""
        try run("/usr/bin/codesign", arguments: [
            "--verify", "--deep", "--strict", "--requirement", requirement, appURL.path
        ])
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func components(_ value: String) -> [Int] {
            value.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .split(separator: ".")
                .map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let lhs = components(candidate)
        let rhs = components(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
    }

    private func appleScriptQuoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft, prerelease, assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}
