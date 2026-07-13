import Foundation
import Testing
@testable import AutoMacroApp

@Suite("Update service")
struct UpdateServiceTests {
    @Test("Semantic release versions compare with an optional v prefix")
    func comparesVersions() {
        #expect(UpdateService.isNewer("v0.1.1", than: "0.1.0"))
        #expect(UpdateService.isNewer("v1.0.0", than: "0.99.99"))
        #expect(!UpdateService.isNewer("v0.1.1", than: "0.1.1"))
        #expect(!UpdateService.isNewer("v0.1.0", than: "0.1.1"))
    }

    @Test("A newer GitHub release selects the matching architecture ZIP")
    func selectsArchitectureAsset() throws {
        let json = """
        {
          "tag_name": "v0.1.1",
          "draft": false,
          "prerelease": false,
          "assets": [
            {"name":"AutoMacro-v0.1.1-macos-x86_64.zip","browser_download_url":"https://example.com/intel.zip"},
            {"name":"AutoMacro-v0.1.1-macos-arm64.zip","browser_download_url":"https://example.com/arm.zip"}
          ]
        }
        """

        let update = try UpdateService.updateRelease(
            from: Data(json.utf8),
            currentVersion: "0.1.0",
            architecture: "arm64"
        )

        #expect(update?.version == "v0.1.1")
        #expect(update?.downloadURL.absoluteString == "https://example.com/arm.zip")
    }

    @Test("The current version does not offer itself again")
    func ignoresCurrentRelease() throws {
        let json = """
        {
          "tag_name": "v0.1.1",
          "draft": false,
          "prerelease": false,
          "assets": [
            {"name":"AutoMacro-v0.1.1-macos-arm64.zip","browser_download_url":"https://example.com/arm.zip"}
          ]
        }
        """

        let update = try UpdateService.updateRelease(
            from: Data(json.utf8),
            currentVersion: "0.1.1",
            architecture: "arm64"
        )

        #expect(update == nil)
    }
}
