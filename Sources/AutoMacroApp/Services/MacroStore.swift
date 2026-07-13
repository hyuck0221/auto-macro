import Combine
import Foundation

public enum MacroStoreError: Error, LocalizedError, Sendable, Equatable {
    case directoryCreationFailed(String)
    case readFailed(String)
    case decodingFailed(String)
    case encodingFailed(String)
    case writeFailed(String)
    case validationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .directoryCreationFailed(message):
            "매크로 저장 폴더를 만들 수 없습니다: \(message)"
        case let .readFailed(message):
            "저장된 매크로를 읽을 수 없습니다: \(message)"
        case let .decodingFailed(message):
            "저장된 매크로 형식이 올바르지 않습니다: \(message)"
        case let .encodingFailed(message):
            "매크로를 JSON으로 변환할 수 없습니다: \(message)"
        case let .writeFailed(message):
            "매크로를 저장할 수 없습니다: \(message)"
        case let .validationFailed(message):
            "매크로 안전 검증에 실패했습니다: \(message)"
        }
    }
}

@MainActor
public final class MacroStore: ObservableObject {
    @Published public private(set) var documents: [MacroDocument] = []
    @Published public private(set) var lastError: MacroStoreError?

    public let storageURL: URL

    private let fileManager: FileManager

    public init(
        storageURL: URL? = nil,
        fileManager: FileManager = .default,
        seedSamples: Bool = true
    ) {
        self.fileManager = fileManager
        self.storageURL = storageURL ?? Self.defaultStorageURL(fileManager: fileManager)

        do {
            try load()
            if seedSamples {
                try seedSampleIfNeeded()
            }
        } catch {
            // `load` and `seedSampleIfNeeded` publish a user-facing error.
        }
    }

    public func load() throws {
        clearError()
        guard fileManager.fileExists(atPath: storageURL.path) else {
            documents = []
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: storageURL)
        } catch {
            throw publish(.readFailed(error.localizedDescription))
        }

        do {
            let decoded = try Self.makeDecoder().decode([MacroDocument].self, from: data)
            try decoded.forEach { try MacroValidator.validate($0) }
            documents = decoded.sorted(by: Self.mostRecentlyUpdatedFirst)
        } catch {
            throw publish(.decodingFailed(error.localizedDescription))
        }
    }

    public func save() throws {
        clearError()
        try persist(documents)
    }

    public func upsert(_ document: MacroDocument) throws {
        clearError()
        do {
            try MacroValidator.validate(document)
        } catch {
            throw publish(.validationFailed(error.localizedDescription))
        }
        var updatedDocuments = documents

        if let index = updatedDocuments.firstIndex(where: { $0.id == document.id }) {
            updatedDocuments[index] = document
        } else {
            updatedDocuments.append(document)
        }

        updatedDocuments.sort(by: Self.mostRecentlyUpdatedFirst)
        try persist(updatedDocuments)
        documents = updatedDocuments
    }

    public func delete(id: MacroDocument.ID) throws {
        clearError()
        let updatedDocuments = documents.filter { $0.id != id }
        guard updatedDocuments.count != documents.count else { return }
        try persist(updatedDocuments)
        documents = updatedDocuments
    }

    public func replaceAll(with newDocuments: [MacroDocument]) throws {
        clearError()
        do {
            try newDocuments.forEach { try MacroValidator.validate($0) }
        } catch {
            throw publish(.validationFailed(error.localizedDescription))
        }
        let sortedDocuments = newDocuments.sorted(by: Self.mostRecentlyUpdatedFirst)
        try persist(sortedDocuments)
        documents = sortedDocuments
    }

    public func seedSampleIfNeeded() throws {
        guard documents.isEmpty else { return }
        try upsert(Self.sampleDocument())
    }

    public func clearError() {
        lastError = nil
    }

    nonisolated public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    nonisolated public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func defaultStorageURL(fileManager: FileManager) -> URL {
        let applicationSupportURL = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory

        return applicationSupportURL
            .appendingPathComponent("AutoMacro", isDirectory: true)
            .appendingPathComponent("macros.json", isDirectory: false)
    }

    private static func mostRecentlyUpdatedFirst(_ lhs: MacroDocument, _ rhs: MacroDocument) -> Bool {
        if lhs.updatedAt == rhs.updatedAt {
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return lhs.updatedAt > rhs.updatedAt
    }

    private static func sampleDocument() -> MacroDocument {
        let now = Date()
        return MacroDocument(
            name: "예약 매크로 예시",
            createdAt: now,
            updatedAt: now,
            source: .screenRecording,
            status: .ready,
            steps: [
                MacroStep(
                    order: 0,
                    title: "예약 영역이 준비될 때까지 기다리기",
                    action: .click(
                        point: .init(x: 0.82, y: 0.86),
                        button: .left,
                        clickCount: 1
                    ),
                    trigger: .regionChanged(
                        region: .init(x: 0.65, y: 0.72, width: 0.3, height: 0.22),
                        threshold: 0.08
                    ),
                    timeout: 15
                )
            ]
        )
    }

    private func persist(_ documents: [MacroDocument]) throws {
        let directoryURL = storageURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            throw publish(.directoryCreationFailed(error.localizedDescription))
        }

        let data: Data
        do {
            data = try Self.makeEncoder().encode(documents)
        } catch {
            throw publish(.encodingFailed(error.localizedDescription))
        }

        do {
            try data.write(to: storageURL, options: .atomic)
        } catch {
            throw publish(.writeFailed(error.localizedDescription))
        }
    }

    @discardableResult
    private func publish(_ error: MacroStoreError) -> MacroStoreError {
        lastError = error
        return error
    }
}
