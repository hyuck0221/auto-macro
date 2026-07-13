# Auto Macro

Auto Macro는 사용자가 직접 시연한 화면·마우스·키보드 흐름을 기록하고, AI가 이를 화면 변화 조건이 포함된 재사용 가능한 매크로로 바꾸는 macOS 앱입니다.

## 핵심 기능

- ScreenCaptureKit 기반 화면 녹화와 CGEvent 기반 입력 이벤트 동시 기록
- 포인터 이동·클릭 방식·스크롤, 키보드 조합키·모든 키, 화면 변화 분석을 녹화마다 선택
- 녹화 후 타임라인에서 자유 프롬프트로 입력값·순서·타이밍·화면 조건을 AI 재편집하고 이전 버전으로 되돌리기
- 기존 동영상 업로드 및 중요 프레임 추출
- 고정 시간뿐 아니라 픽셀 색상, 화면 영역 변화, 슬라이딩 기준 이미지 탐색을 기다리는 조건 실행
- 창 ID·앱 번들·제목을 이용한 실행 대상 재탐색과 현재 창 좌표 보정
- Ollama 설치·서버·로컬 Vision 모델 자동 검색
- Google Gemini, Anthropic Claude, OpenAI API 키 기반 자동 설정
- 설치된 Antigravity, Claude Code, Codex CLI 자동 감지와 Agent별 모델 선택
- URL·Header·Body JSON과 `{{video}}` 등의 값을 조합하는 기타 외부 API
- API 키와 외부 API 설정은 macOS Keychain에만 저장
- AI 결과 검토 승인, 단계별 타임아웃, 포커스 이탈 중단, Esc 즉시 중단을 제공하는 안전 재생

## 실행

개발 실행:

```bash
swift run AutoMacro
```

앱 번들 만들기:

```bash
./Scripts/package-app.sh
open "dist/Auto Macro.app"
```

테스트:

```bash
./Scripts/run-tests.sh
```

첫 실행 시 macOS의 **화면 및 시스템 오디오 녹음**, **입력 모니터링**, **손쉬운 사용** 권한이 필요합니다. 권한을 변경한 뒤에는 앱을 다시 실행해야 할 수 있습니다.

영상을 가져오기 전에 녹화 스튜디오 상단에서 실제 실행할 화면이나 앱 창을 선택하세요. 가져온 영상은 그 대상의 정규화 좌표계에 연결되며, 편집 화면에서도 대상을 다시 지정할 수 있습니다. AI가 만든 결과는 항상 초안으로 열리고 **검토 완료·저장** 전에는 실행되지 않습니다.

## 개인정보와 안전

녹화 데이터와 Ollama 분석은 기본적으로 Mac 안에 보관됩니다. Gemini, Claude, ChatGPT, 사용자가 설정한 기타 API 또는 CLI를 선택하면 분석에 필요한 이벤트 정보와 대표 화면 프레임이 해당 공급자로 전달됩니다. 새 매크로 화면에서 조합키만 기록하거나 모든 키를 기록하거나 키보드를 완전히 끌 수 있습니다. 모든 키 모드에서도 macOS Secure Input이 켜진 동안에는 문자값을 저장하지 않습니다. CLI 분석은 매번 전송 확인을 받고 제한된 환경·출력 크기·실행 시간으로 실행됩니다.

Auto Macro는 사용자 본인이 조작 권한을 가진 앱과 서비스에서 반복 작업을 돕기 위한 도구입니다. 대상 서비스의 이용약관, 대기열, CAPTCHA, 구매 제한 또는 접근 통제를 우회하는 용도로 사용하지 마세요.

`package-app.sh`는 Apple Developer 계정 없이 사용할 수 있는 ad-hoc 서명 번들을 만듭니다.

## 릴리스와 자동 업데이트

`v0.1.0`처럼 `v`로 시작하는 태그를 push하면 GitHub Actions가 Apple Silicon(`arm64`)과 Intel(`x86_64`)용 ZIP·DMG를 GitHub Release에 올립니다. 앱은 시작 시 `hyuck0221/auto-macro`의 최신 안정 릴리스를 확인하고, 맞는 아키텍처 ZIP을 내려받아 앱을 교체한 뒤 다시 실행합니다.

Apple Developer ID가 필요하지 않으며 GitHub Secrets도 설정할 필요가 없습니다. 다만 Apple이 발급한 Developer ID/notarization이 없으므로, 처음 설치할 때 macOS가 확인되지 않은 개발자 경고를 표시할 수 있습니다. 이 경우 Finder에서 앱을 control-클릭한 뒤 **열기**를 한 번 선택하면 됩니다. 이후 인앱 업데이트는 동일한 방식으로 자동 설치·재시작됩니다.

배포 번들은 Apple 계정 없이도 권한을 업데이트 간에 유지할 수 있도록 고정된 번들 ID(`app.automacro.desktop`) 기반의 ad-hoc 지정 요구사항으로 서명됩니다. 이 변경 전 릴리스에서 권한을 부여했다면, 이 버전으로 업데이트한 뒤에만 화면 기록·입력 모니터링·손쉬운 사용 권한을 한 번 다시 허용해 주세요.
