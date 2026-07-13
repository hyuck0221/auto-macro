import Foundation
import Testing
@testable import AutoMacroApp

struct MacroModelsTests {
    @Test
    func testDocumentRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let document = MacroDocument(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Reservation",
            createdAt: date,
            updatedAt: date,
            source: .uploadedVideo,
            status: .ready,
            steps: [
                MacroStep(
                    order: 0,
                    title: "Choose date",
                    action: .click(point: .init(x: 0.42, y: 0.67), button: .left, clickCount: 1),
                    trigger: .pixelColor(
                        point: .init(x: 0.42, y: 0.67),
                        color: .init(red: 0.1, green: 0.3, blue: 0.9),
                        tolerance: 0.04
                    ),
                    timeout: 8
                ),
                MacroStep(
                    order: 1,
                    title: "Confirm",
                    action: .shortcut(key: "return", modifiers: [.command]),
                    trigger: .regionChanged(
                        region: .init(x: 0.3, y: 0.4, width: 0.5, height: 0.2),
                        threshold: 0.12
                    )
                )
            ],
            recordingURL: URL(fileURLWithPath: "/tmp/reservation.mov"),
            thumbnailPath: "/tmp/reservation.png",
            captureTarget: CaptureTargetDescriptor(
                kind: .window,
                targetID: 42,
                displayID: 1,
                title: "Reservation — Calendar",
                frame: ScreenRect(x: 120, y: 80, width: 1_280, height: 900)
            )
        )

        let data = try MacroStore.makeEncoder().encode(document)
        let decoded = try MacroStore.makeDecoder().decode(MacroDocument.self, from: data)

        #expect(decoded == document)
    }

    @Test
    func testEveryTriggerVariantRoundTrips() throws {
        let triggers: [MacroTrigger] = [
            .immediate,
            .delay(seconds: 0.25),
            .pixelColor(
                point: .init(x: 0.2, y: 0.3),
                color: .init(red: 1, green: 0.5, blue: 0, alpha: 0.8),
                tolerance: 0.03
            ),
            .regionChanged(
                region: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                threshold: 0.2
            ),
            .imageAppears(referencePath: "/tmp/button.png", region: nil, confidence: 0.95)
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for trigger in triggers {
            let data = try encoder.encode(trigger)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["type"] is String)
            #expect(try decoder.decode(MacroTrigger.self, from: data) == trigger)
        }
    }

    @Test
    @MainActor
    func testMacroStorePersistsAndReloads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("macros.json")
        let store = MacroStore(storageURL: fileURL, seedSamples: false)
        let document = MacroDocument(
            name: "Saved macro",
            status: .ready,
            steps: [MacroStep(order: 0, title: "Wait", action: .wait(seconds: 0), timeout: 1)]
        )

        try store.upsert(document)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        let reloaded = MacroStore(storageURL: fileURL, seedSamples: false)
        #expect(reloaded.documents.map(\.id) == [document.id])

        try reloaded.delete(id: document.id)
        #expect(reloaded.documents.isEmpty)
    }

    @Test
    @MainActor
    func testMacroStoreSeedsSample() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("macros.json")

        let store = MacroStore(storageURL: fileURL)

        #expect(store.documents.count == 1)
        #expect(store.documents.first?.status == .ready)
        #expect(store.documents.first?.steps.isEmpty == false)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test
    func testValidatorRejectsUnsafeCoordinates() {
        let document = MacroDocument(
            name: "Unsafe",
            status: .ready,
            steps: [
                MacroStep(
                    order: 0,
                    title: "Outside",
                    action: .click(point: .init(x: 1.2, y: 0.5), button: .left, clickCount: 1),
                    timeout: 5
                )
            ]
        )

        #expect(throws: MacroValidationError.self) {
            try MacroValidator.validate(document, allowEmptyDraft: false)
        }
    }

    @Test
    @MainActor
    func testStoreRejectsExecutableEmptyMacro() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MacroStore(
            storageURL: directory.appendingPathComponent("macros.json"),
            seedSamples: false
        )

        #expect(throws: MacroStoreError.self) {
            try store.upsert(MacroDocument(name: "Empty", status: .ready))
        }
    }

    @Test
    @MainActor
    func testMacroStoreExposesDecodingErrors() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("macros.json")
        try Data("not-json".utf8).write(to: fileURL, options: .atomic)

        let store = MacroStore(storageURL: fileURL, seedSamples: false)

        guard case .decodingFailed? = store.lastError else {
            Issue.record("Expected a decoding error")
            return
        }
        #expect(store.documents.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }
}
