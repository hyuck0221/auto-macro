import Foundation
import Testing
@testable import AutoMacroApp

struct SecurityBoundaryTests {
    @Test
    func cliDetectorResolvesTrustedExecutable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let executable = directory.appendingPathComponent("auto-macro-test-agent")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let detected = CLIExecutableDetector.find(
            named: executable.lastPathComponent,
            environment: ["PATH": directory.path]
        )

        #expect(detected == executable.resolvingSymlinksInPath().standardizedFileURL)
    }

    @Test
    func cliDetectorRejectsWorldWritableExecutable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let executable = directory.appendingPathComponent("auto-macro-unsafe-agent")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: executable.path)

        #expect(CLIExecutableDetector.find(
            named: executable.lastPathComponent,
            environment: ["PATH": directory.path]
        ) == nil)
    }

    @Test
    func parserRejectsOversizedResponse() {
        let response = String(repeating: "x", count: 2 * 1_024 * 1_024 + 1)
        #expect(throws: AIProviderError.self) {
            try AIResponseParser().parse(response)
        }
    }

    @Test
    func selectedCLIModelIsForwardedAsASeparateProcessArgument() throws {
        let executable = try makeTrustedTestExecutable(body: "exit 0")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        for kind in [AIProviderKind.antigravityCLI, .claudeCLI, .codexCLI] {
            let provider = try CLIProvider(kind: kind, executableURL: executable)
            let arguments = provider.commandArguments(imageURLs: [], model: "vision-model")
            #expect(arguments.contains("--model"))
            #expect(arguments.contains("vision-model"))

            let defaultArguments = provider.commandArguments(imageURLs: [], model: "agent-default")
            #expect(!defaultArguments.contains("--model"))
            #expect(!defaultArguments.contains("agent-default"))
        }
    }

    @Test
    func antigravityModelListIsLoadedFromInstalledAgent() async throws {
        let executable = try makeTrustedTestExecutable(body: """
        printf 'Gemini Vision High\\nClaude Vision Thinking\\n'
        """)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let provider = try CLIProvider(kind: .antigravityCLI, executableURL: executable)

        let models = try await provider.availableModels()

        #expect(models.map(\.id) == ["agent-default", "Gemini Vision High", "Claude Vision Thinking"])
    }

    @Test
    func screenChangeToggleControlsConditionalTriggerGuidance() {
        let enabled = AIAnalysisRequest(
            macroName: "enabled",
            eventJSON: "[]",
            keyframes: [],
            screenChangeDetectionEnabled: true
        )
        let disabled = AIAnalysisRequest(
            macroName: "disabled",
            eventJSON: "[]",
            keyframes: [],
            screenChangeDetectionEnabled: false
        )

        #expect(enabled.systemPrompt.contains("Prefer pixelColor or regionChanged"))
        #expect(disabled.systemPrompt.contains("Do not create pixelColor, regionChanged, or imageAppears"))
        #expect(!disabled.systemPrompt.contains("Prefer pixelColor or regionChanged"))
    }

    private func makeTrustedTestExecutable(body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let executable = directory.appendingPathComponent("auto-macro-test-agent")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }
}
