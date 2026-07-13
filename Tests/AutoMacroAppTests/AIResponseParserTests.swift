import Foundation
import Testing
@testable import AutoMacroApp

struct AIResponseParserTests {
    @Test
    func testParsesCodeFence() throws {
        let response = """
        분석 결과입니다.
        ```json
        \(validDocumentJSON)
        ```
        위 매크로는 화면 변화 뒤에 예약 버튼을 누릅니다.
        """

        let document = try AIResponseParser().parse(response)

        #expect(document.name == "예약 자동화")
        #expect(document.status == .ready)
        #expect(document.steps.count == 1)
        #expect(document.steps[0].trigger == .regionChanged(
            region: .init(x: 0.1, y: 0.2, width: 0.5, height: 0.3),
            threshold: 0.12
        ))
    }

    @Test
    func testParsesSurroundingTextAndQuotedBraces() throws {
        let response = "prefix [unfinished note {not valid} explanatory text \(validDocumentJSON) suffix"

        let document = try AIResponseParser().parse(response)

        #expect(document.steps[0].title == "{예약} 버튼 클릭")
        #expect(document.steps[0].action == .click(
            point: .init(x: 0.8, y: 0.7),
            button: .left,
            clickCount: 1
        ))
    }

    @Test
    func testRejectsInvalidJSON() {
        #expect(throws: AIProviderError.self) {
            try AIResponseParser().parse("완료했습니다. {\"message\":\"매크로 없음\"}")
        }
    }

    private var validDocumentJSON: String {
        """
        {
          "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
          "name": "예약 자동화",
          "createdAt": "2026-07-13T01:02:03Z",
          "updatedAt": "2026-07-13T01:02:03Z",
          "source": "screenRecording",
          "status": "ready",
          "steps": [
            {
              "id": "11111111-2222-3333-4444-555555555555",
              "order": 0,
              "title": "{예약} 버튼 클릭",
              "action": {
                "type": "click",
                "point": {"x": 0.8, "y": 0.7},
                "button": "left",
                "clickCount": 1
              },
              "trigger": {
                "type": "regionChanged",
                "region": {"x": 0.1, "y": 0.2, "width": 0.5, "height": 0.3},
                "threshold": 0.12
              },
              "timeout": 15
            }
          ]
        }
        """
    }
}
