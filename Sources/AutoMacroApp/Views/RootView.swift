import SwiftUI

enum AppDestination: String, CaseIterable, Identifiable {
    case dashboard
    case recorder
    case library
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "홈"
        case .recorder: "새 매크로"
        case .library: "내 매크로"
        case .settings: "AI 설정"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .recorder: "record.circle"
        case .library: "rectangle.stack"
        case .settings: "sparkles"
        }
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
                .frame(maxHeight: .infinity)
                .clipped()

            Rectangle()
                .fill(AMTheme.border)
                .frame(width: 1)

            ZStack {
                AMTheme.background.ignoresSafeArea()

                switch model.destination {
                case .dashboard:
                    DashboardView(model: model)
                case .recorder:
                    RecorderView(model: model)
                case .library:
                    MacroLibraryView(model: model)
                case .settings:
                    SettingsView(model: model)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AMTheme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .alert("확인해 주세요", isPresented: errorBinding) {
            Button("확인") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "알 수 없는 오류가 발생했습니다.")
        }
        .sheet(isPresented: macroSheetBinding) {
            if let id = model.presentedMacroID,
               let macro = model.macros.first(where: { $0.id == id }) {
                MacroEditorView(model: model, macro: macro)
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private var macroSheetBinding: Binding<Bool> {
        Binding(
            get: { model.presentedMacroID != nil },
            set: { if !$0 { model.presentedMacroID = nil } }
        )
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                AppMark(size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto Macro")
                        .font(.headline.weight(.bold))
                    Text("Observe · React · Act")
                        .font(.caption2)
                        .foregroundStyle(AMTheme.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 20)

            List(AppDestination.allCases, selection: $model.destination) { destination in
                Label(destination.title, systemImage: destination.systemImage)
                    .font(.body.weight(.medium))
                    .padding(.vertical, 5)
                    .tag(destination)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            providerSummary
                .padding(14)

            updateSummary
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
        }
        .background(Color(red: 0.025, green: 0.04, blue: 0.085))
    }

    private var providerSummary: some View {
        Button {
            model.destination = .settings
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(AMTheme.primarySoft)
                    Image(systemName: "sparkles")
                        .foregroundStyle(AMTheme.primary)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.activeProviderName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(model.activeModelName)
                        .font(.caption2)
                        .foregroundStyle(AMTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Circle()
                    .fill(model.isActiveProviderReady ? AMTheme.success : AMTheme.warning)
                    .frame(width: 7, height: 7)
            }
            .padding(11)
            .background(Color.white.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var updateSummary: some View {
        ZStack {
            Text("v\(model.appVersion)")
                .font(.caption2)
                .foregroundStyle(AMTheme.textSecondary)
            HStack {
                Spacer(minLength: 0)
                if model.availableUpdate != nil {
                    Button(model.updateState == .downloading ? "다운로드 중…" : "업데이트") {
                        model.installAvailableUpdate()
                    }
                    .font(.caption2.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(model.updateState == .downloading)
                }
            }
        }
    }
}
