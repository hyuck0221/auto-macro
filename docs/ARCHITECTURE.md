# Architecture

Auto Macro는 한 공급자나 한 사이트의 DOM에 종속되지 않도록 네 계층으로 나뉩니다.

1. `Services/InputRecorder`와 `ScreenRecorder`가 동일한 monotonic clock 기준으로 시연을 수집합니다.
2. `VideoFrameExtractor`가 AI에 보낼 대표 프레임을 준비하고 `AI/MacroGenerationService`가 선택한 로컬·API·CLI 공급자로 요청을 라우팅합니다.
3. AI 출력은 미승인 `draft`로 파싱되고, `MacroValidator`가 AI 응답·저장·로드·실행 경계에서 좌표, 텍스트 크기, 단계 수와 관리 이미지 경로를 검증합니다.
4. 실행 시 `ScreenSampler`가 녹화한 창을 window ID, bundle ID, 제목과 크기로 다시 찾고 현재 프레임을 좌표계로 사용합니다.
5. `MacroRunner`는 각 단계의 `MacroTrigger`를 먼저 만족시킨 후 CGEvent 동작을 실행합니다. 화면 로딩 속도가 달라도 픽셀·영역·다중 배율 이미지 조건이 다음 동작을 동기화합니다.

네트워크 공급자는 앱의 핵심 기능과 분리되어 있습니다. 따라서 API가 실패해도 기존 매크로의 편집과 로컬 실행은 계속 사용할 수 있습니다.

클라우드 요청은 캐시·쿠키가 없는 ephemeral 세션과 동일 호스트 리디렉션만 사용합니다. CLI는 고정된 실경로, 최소 환경, 읽기 제한 옵션, 300초 제한과 2 MiB 출력 한도로 감싸며 실행 전 사용자 확인을 요구합니다.
