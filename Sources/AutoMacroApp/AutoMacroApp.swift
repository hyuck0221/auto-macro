import SwiftUI

@main
struct AutoMacroApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 1_080, minHeight: 700)
        }
        .defaultSize(width: 1_240, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("새 매크로 녹화") {
                    model.destination = .recorder
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            CommandMenu("매크로") {
                Button("현재 실행 중단") { model.stopMacro() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(model.runningMacroID == nil)
                Divider()
                Button("영상 가져오기…") { model.importVideo() }
                    .keyboardShortcut("o", modifiers: [.command])
            }
        }

        Settings {
            SettingsView(model: model)
                .frame(minWidth: 900, minHeight: 620)
                .background(AMTheme.background)
                .preferredColorScheme(.dark)
        }
    }
}
