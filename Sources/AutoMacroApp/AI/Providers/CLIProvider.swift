import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct DetectedCLI: Identifiable, Hashable, Sendable {
    let kind: AIProviderKind
    let executableURL: URL

    var id: AIProviderKind { kind }
    var displayName: String { kind.displayName }
}

enum CLIExecutableDetector {
    static func detectedAgents(environment: [String: String] = ProcessInfo.processInfo.environment) -> [DetectedCLI] {
        let configurations: [(AIProviderKind, [String])] = [
            (.antigravityCLI, ["antigravity", "agy"]),
            (.claudeCLI, ["claude"]),
            (.codexCLI, ["codex"])
        ]
        return configurations.compactMap { kind, names in
            names.lazy.compactMap { find(named: $0, environment: environment) }.first.map {
                DetectedCLI(kind: kind, executableURL: $0)
            }
        }
    }

    static func find(
        named executableName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard !executableName.isEmpty, !executableName.contains("/") else { return nil }
        var directories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        directories.append(contentsOf: [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            homeDirectory.appendingPathComponent(".local/bin", isDirectory: true).path,
            homeDirectory.appendingPathComponent("bin", isDirectory: true).path
        ])

        var seen = Set<String>()
        for directory in directories where seen.insert(directory).inserted {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(executableName, isDirectory: false)
                .standardizedFileURL
            if let trustedURL = trustedExecutableURL(at: url) {
                return trustedURL
            }
        }

        if executableName == "ollama" {
            let applicationExecutables = [
                "/Applications/Ollama.app/Contents/Resources/ollama",
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications/Ollama.app/Contents/Resources/ollama")
                    .path
            ]
            for path in applicationExecutables {
                if let trustedURL = trustedExecutableURL(at: URL(fileURLWithPath: path)) {
                    return trustedURL
                }
            }
        }
        return nil
    }

    /// Resolves a candidate once so a later symlink replacement cannot redirect execution.
    /// Group/world-writable executable files and untrusted writable parent directories are rejected.
    static func trustedExecutableURL(at candidate: URL) -> URL? {
        let fileManager = FileManager.default
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard fileManager.isExecutableFile(atPath: resolved.path),
              let attributes = try? fileManager.attributesOfItem(atPath: resolved.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              hasSafeWritePermissions(attributes),
              hasSafeParentDirectories(for: resolved, fileManager: fileManager) else {
            return nil
        }
        return resolved
    }

    static func trustedSearchDirectory(_ directory: String) -> String? {
        let fileManager = FileManager.default
        let resolved = URL(fileURLWithPath: directory, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard let attributes = try? fileManager.attributesOfItem(atPath: resolved.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              hasSafeSearchDirectoryPermissions(attributes) else {
            return nil
        }
        return resolved.path
    }

    private static func hasSafeParentDirectories(for executable: URL, fileManager: FileManager) -> Bool {
        let directory = executable.deletingLastPathComponent()
        guard let attributes = try? fileManager.attributesOfItem(atPath: directory.path),
              attributes[.type] as? FileAttributeType == .typeDirectory else { return false }
        return hasSafeSearchDirectoryPermissions(attributes)
    }

    private static func hasSafeWritePermissions(_ attributes: [FileAttributeKey: Any]) -> Bool {
        guard let permissions = attributes[.posixPermissions] as? NSNumber else { return false }
        return permissions.intValue & 0o022 == 0
    }

    private static func hasSafeSearchDirectoryPermissions(_ attributes: [FileAttributeKey: Any]) -> Bool {
        guard let permissions = attributes[.posixPermissions] as? NSNumber,
              let owner = attributes[.ownerAccountID] as? NSNumber else { return false }
        let mode = permissions.intValue
        guard mode & 0o002 == 0 else { return false }
        return mode & 0o020 == 0 || owner.uint32Value == geteuid()
    }
}

struct CLIProvider: AIProvider {
    let kind: AIProviderKind
    let executableURL: URL

    init(kind: AIProviderKind, executableURL: URL? = nil) throws {
        guard kind == .antigravityCLI || kind == .claudeCLI || kind == .codexCLI else {
            throw AIProviderError.invalidRequest("\(kind.displayName)은 CLI 공급자가 아닙니다.")
        }
        let candidateNames: [String]
        switch kind {
        case .antigravityCLI: candidateNames = ["antigravity", "agy"]
        case .claudeCLI: candidateNames = ["claude"]
        case .codexCLI: candidateNames = ["codex"]
        default: candidateNames = []
        }
        let suppliedExecutable = executableURL.flatMap(CLIExecutableDetector.trustedExecutableURL)
        guard let resolved = suppliedExecutable
            ?? candidateNames.lazy.compactMap({ CLIExecutableDetector.find(named: $0) }).first else {
            throw AIProviderError.commandNotFound(candidateNames.first ?? kind.displayName)
        }
        self.kind = kind
        self.executableURL = resolved
    }

    func availableModels() async throws -> [AIModelDescriptor] {
        let defaultModel = AIModelDescriptor(
            id: "agent-default",
            displayName: "Agent 기본 모델",
            supportsVision: true
        )
        switch kind {
        case .antigravityCLI:
            let output = try await CLIProcessRunner.run(
                executableURL: executableURL,
                arguments: ["models"],
                standardInput: Data(),
                workingDirectory: FileManager.default.temporaryDirectory,
                displayName: "Antigravity 모델 조회",
                timeout: .seconds(15)
            )
            let models = output.split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { AIModelDescriptor(id: $0, displayName: $0, supportsVision: true) }
            return Self.uniqueModels([defaultModel] + models)

        case .claudeCLI:
            // Claude Code exposes model aliases through --model but has no list command.
            return [
                defaultModel,
                AIModelDescriptor(id: "sonnet", displayName: "Sonnet (latest)", supportsVision: true),
                AIModelDescriptor(id: "opus", displayName: "Opus (latest)", supportsVision: true),
                AIModelDescriptor(id: "haiku", displayName: "Haiku (latest)", supportsVision: true)
            ]

        case .codexCLI:
            let output: String
            do {
                output = try await CLIProcessRunner.run(
                    executableURL: executableURL,
                    arguments: ["debug", "models"],
                    standardInput: Data(),
                    workingDirectory: FileManager.default.temporaryDirectory,
                    displayName: "Codex 모델 조회",
                    timeout: .seconds(15)
                )
            } catch {
                output = try await CLIProcessRunner.run(
                    executableURL: executableURL,
                    arguments: ["debug", "models", "--bundled"],
                    standardInput: Data(),
                    workingDirectory: FileManager.default.temporaryDirectory,
                    displayName: "Codex 내장 모델 조회",
                    timeout: .seconds(15)
                )
            }
            guard let data = output.data(using: .utf8),
                  let catalog = try? JSONDecoder().decode(CodexModelCatalog.self, from: data) else {
                throw AIProviderError.invalidResponse("Codex 모델 목록 형식이 올바르지 않습니다.")
            }
            let models = catalog.models
                .filter { $0.visibility == "list" }
                .sorted { ($0.priority ?? 0) > ($1.priority ?? 0) }
                .map {
                    AIModelDescriptor(
                        id: $0.slug,
                        displayName: $0.displayName ?? $0.slug,
                        supportsVision: $0.inputModalities?.contains("image")
                    )
                }
            return Self.uniqueModels([defaultModel] + models)

        default:
            return [defaultModel]
        }
    }

    func generateResponse(for request: AIAnalysisRequest, model: String?) async throws -> String {
        let frameDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoMacro-AI-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: frameDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw AIProviderError.invalidRequest("임시 키프레임 디렉터리를 만들지 못했습니다.")
        }
        defer { try? FileManager.default.removeItem(at: frameDirectory) }

        let imageURLs = try writeKeyframes(request.keyframes, to: frameDirectory)
        let imageList = imageURLs.enumerated().map { index, url in
            "- frame \(index + 1) at \(String(format: "%.3f", request.keyframes[index].timestamp))s: \(url.path)"
        }.joined(separator: "\n")
        let prompt: String
        if request.isRevision {
            prompt = """
            \(request.prompt)

            This is a timeline-only revision. No recording video or screen frame is provided.
            Do not modify files or run commands. Return only the complete revised MacroDocument JSON.
            """
        } else {
            prompt = """
            \(request.prompt)

            The keyframe image files are available locally. Read each image before producing the macro:
            \(imageList.isEmpty ? "(no keyframes)" : imageList)
            Do not modify files or run commands. Return only the requested MacroDocument JSON.
            """
        }
        let arguments = commandArguments(imageURLs: imageURLs, model: model)
        return try await CLIProcessRunner.run(
            executableURL: executableURL,
            arguments: arguments,
            standardInput: Data(prompt.utf8),
            workingDirectory: frameDirectory,
            displayName: kind.displayName
        )
    }

    func commandArguments(imageURLs: [URL], model: String?) -> [String] {
        let selectedModel = model.flatMap { value in
            value.isEmpty || value == "agent-default" ? nil : value
        }
        switch kind {
        case .antigravityCLI:
            var arguments = ["-p"]
            if let selectedModel { arguments.append(contentsOf: ["--model", selectedModel]) }
            return arguments
        case .claudeCLI:
            var arguments = [
                "-p", "--output-format", "text", "--tools", imageURLs.isEmpty ? "" : "Read",
                "--permission-mode", "dontAsk", "--no-session-persistence",
                "--disable-slash-commands", "--no-chrome", "--strict-mcp-config",
                "--mcp-config", "{}", "--setting-sources", ""
            ]
            if let selectedModel { arguments.append(contentsOf: ["--model", selectedModel]) }
            if let frameDirectory = imageURLs.first?.deletingLastPathComponent().path {
                arguments.append(contentsOf: [
                    "--allowedTools", "Read(\(frameDirectory)/**)",
                    "--disallowedTools", "Bash,Edit,Write,WebFetch,WebSearch,NotebookEdit"
                ])
            }
            return arguments
        case .codexCLI:
            var arguments = [
                "exec", "--skip-git-repo-check", "--sandbox", "read-only", "--color", "never",
                "--ephemeral", "--ignore-user-config", "--ignore-rules", "--strict-config",
                "-c", "shell_environment_policy.inherit=none"
            ]
            if let selectedModel { arguments.append(contentsOf: ["--model", selectedModel]) }
            for imageURL in imageURLs {
                arguments.append(contentsOf: ["--image", imageURL.path])
            }
            arguments.append("-")
            return arguments
        default:
            return []
        }
    }

    private func writeKeyframes(_ keyframes: [AIKeyframe], to directory: URL) throws -> [URL] {
        try keyframes.enumerated().map { index, keyframe in
            let url = directory.appendingPathComponent(
                String(format: "frame-%04d.%@", index + 1, Self.fileExtension(for: keyframe.mimeType)),
                isDirectory: false
            )
            do {
                try keyframe.data.write(to: url, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                return url
            } catch {
                throw AIProviderError.invalidRequest("키프레임 이미지를 임시 저장하지 못했습니다.")
            }
        }
    }

    private static func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/png": "png"
        case "image/webp": "webp"
        case "image/heic", "image/heif": "heic"
        default: "jpg"
        }
    }

    private static func uniqueModels(_ models: [AIModelDescriptor]) -> [AIModelDescriptor] {
        var seen = Set<String>()
        return models.filter { seen.insert($0.id).inserted }
    }
}

private struct CodexModelCatalog: Decodable {
    let models: [CodexCatalogModel]
}

private struct CodexCatalogModel: Decodable {
    let slug: String
    let displayName: String?
    let visibility: String?
    let priority: Int?
    let inputModalities: [String]?

    private enum CodingKeys: String, CodingKey {
        case slug, visibility, priority
        case displayName = "display_name"
        case inputModalities = "input_modalities"
    }
}

private enum CLIProcessRunner {
    static func run(
        executableURL: URL,
        arguments: [String],
        standardInput: Data,
        workingDirectory: URL,
        displayName: String,
        timeout: Duration = .seconds(300),
        outputLimit: Int = 2 * 1_024 * 1_024
    ) async throws -> String {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = sanitizedEnvironment(for: executableURL)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw AIProviderError.commandFailed(
                command: displayName,
                exitCode: -1,
                message: error.localizedDescription
            )
        }

        let managedProcess = ManagedProcess(process)
        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        let outputTask = Task.detached(priority: .userInitiated) {
            readCapped(
                from: outputHandle,
                limit: outputLimit,
                managedProcess: managedProcess
            )
        }
        let errorTask = Task.detached(priority: .utility) {
            readCapped(
                from: errorHandle,
                limit: outputLimit,
                managedProcess: managedProcess
            )
        }

        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
            try inputPipe.fileHandleForWriting.close()
        } catch {
            managedProcess.requestTermination()
            _ = await outputTask.value
            _ = await errorTask.value
            throw AIProviderError.commandFailed(
                command: displayName,
                exitCode: -1,
                message: "프롬프트를 CLI에 전달하지 못했습니다."
            )
        }

        let completedBeforeTimeout: Bool
        do {
            completedBeforeTimeout = try await withTaskCancellationHandler {
                try await waitForExit(managedProcess, timeout: timeout)
            } onCancel: {
                managedProcess.requestTermination()
            }
        } catch {
            managedProcess.requestTermination()
            _ = await outputTask.value
            _ = await errorTask.value
            throw error
        }

        let capturedOutput = await outputTask.value
        let capturedError = await errorTask.value
        guard completedBeforeTimeout else {
            throw AIProviderError.commandFailed(
                command: displayName,
                exitCode: -1,
                message: "CLI 응답 제한 시간을 초과해 실행을 종료했습니다."
            )
        }
        guard !capturedOutput.exceededLimit, !capturedError.exceededLimit else {
            throw AIProviderError.commandFailed(
                command: displayName,
                exitCode: process.terminationStatus,
                message: "CLI 출력이 허용 크기(스트림당 2 MiB)를 초과해 실행을 종료했습니다."
            )
        }
        if let readError = capturedOutput.readError ?? capturedError.readError {
            throw AIProviderError.commandFailed(
                command: displayName,
                exitCode: process.terminationStatus,
                message: "CLI 출력을 읽지 못했습니다: \(readError)"
            )
        }

        let output = String(data: capturedOutput.data, encoding: .utf8) ?? ""
        let standardError = String(data: capturedError.data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = standardError.isEmpty ? output : standardError
            throw classifyFailure(
                detail,
                displayName: displayName,
                exitCode: process.terminationStatus
            )
        }
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.invalidResponse(
                standardError.isEmpty ? "CLI가 빈 응답을 반환했습니다." : standardError.prefixDescription(1_000)
            )
        }
        return output
    }

    private static func waitForExit(
        _ managedProcess: ManagedProcess,
        timeout: Duration
    ) async throws -> Bool {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                managedProcess.waitUntilExit()
                return true
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return false
            }

            guard let completedBeforeTimeout = try await group.next() else {
                managedProcess.requestTermination()
                return false
            }
            if !completedBeforeTimeout {
                managedProcess.requestTermination()
            }
            group.cancelAll()
            return completedBeforeTimeout
        }
    }

    private static func readCapped(
        from handle: FileHandle,
        limit: Int,
        managedProcess: ManagedProcess
    ) -> CapturedStream {
        var data = Data()
        data.reserveCapacity(min(limit, 64 * 1_024))
        var exceededLimit = false

        do {
            while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                let remaining = max(0, limit - data.count)
                if remaining > 0 {
                    data.append(chunk.prefix(remaining))
                }
                if chunk.count > remaining {
                    exceededLimit = true
                    managedProcess.requestTermination()
                }
            }
            return CapturedStream(data: data, exceededLimit: exceededLimit, readError: nil)
        } catch {
            return CapturedStream(
                data: data,
                exceededLimit: exceededLimit,
                readError: error.localizedDescription
            )
        }
    }

    private static func sanitizedEnvironment(for executableURL: URL) -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR", "SHELL"] {
            if let value = source[key], !value.isEmpty {
                environment[key] = value
            }
        }

        var pathDirectories = [
            executableURL.deletingLastPathComponent().path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ]
        pathDirectories.append(contentsOf: (source["PATH"] ?? "").split(separator: ":").map(String.init))
        var seen = Set<String>()
        let safePath = pathDirectories.compactMap(CLIExecutableDetector.trustedSearchDirectory)
            .filter { seen.insert($0).inserted }
        environment["PATH"] = safePath.joined(separator: ":")

        return environment
    }

    private static func classifyFailure(
        _ detail: String,
        displayName: String,
        exitCode: Int32
    ) -> AIProviderError {
        let message = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = message.lowercased()
        if ["not logged in", "login required", "unauthorized", "authentication", "invalid api key"]
            .contains(where: lowercased.contains) {
            return .authenticationFailed(displayName)
        }
        if ["rate limit", "quota exceeded", "too many requests"]
            .contains(where: lowercased.contains) {
            return .rateLimited(displayName)
        }
        if ["network", "connection refused", "could not resolve", "timed out", "offline"]
            .contains(where: lowercased.contains) {
            return .networkUnavailable(message.prefixDescription(1_000))
        }
        if ["permission denied", "access denied", "forbidden"]
            .contains(where: lowercased.contains) {
            return .permissionDenied(displayName)
        }
        return .commandFailed(
            command: displayName,
            exitCode: exitCode,
            message: message.prefixDescription(1_000)
        )
    }
}

private struct CapturedStream: Sendable {
    let data: Data
    let exceededLimit: Bool
    let readError: String?
}

private final class ManagedProcess: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var terminationRequested = false

    init(_ process: Process) {
        self.process = process
    }

    func waitUntilExit() {
        process.waitUntilExit()
    }

    func requestTermination() {
        lock.lock()
        guard !terminationRequested else {
            lock.unlock()
            return
        }
        terminationRequested = true
        let processIdentifier = process.processIdentifier
        let shouldTerminate = process.isRunning
        if shouldTerminate {
            process.terminate()
        }
        lock.unlock()

        guard shouldTerminate else { return }
        Task.detached(priority: .utility) { [self] in
            try? await Task.sleep(for: .seconds(2))
            guard process.isRunning else { return }
#if canImport(Darwin)
            Darwin.kill(processIdentifier, SIGKILL)
#else
            process.terminate()
#endif
        }
    }
}

private extension String {
    func prefixDescription(_ maximumLength: Int) -> String {
        count <= maximumLength ? self : String(prefix(maximumLength)) + "…"
    }
}
