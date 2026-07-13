import SwiftUI

struct MacroLibraryView: View {
    @ObservedObject var model: AppModel
    @State private var searchText = ""

    private var filteredMacros: [MacroDocument] {
        guard !searchText.isEmpty else { return model.macros }
        return model.macros.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AMTheme.border)

            if filteredMacros.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 11) {
                        ForEach(filteredMacros) { macro in
                            libraryCard(macro)
                        }
                    }
                    .frame(maxWidth: 1000)
                    .padding(28)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("내 매크로").font(.title2.weight(.bold))
                Text("녹화에서 만든 자동화 흐름을 관리합니다")
                    .font(.caption).foregroundStyle(AMTheme.textSecondary)
            }
            Spacer()
            TextField("매크로 검색", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 230)
            Button {
                model.destination = .recorder
            } label: {
                Label("새 매크로", systemImage: "plus")
            }
            .buttonStyle(PrimaryActionButtonStyle())
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 17)
    }

    private func libraryCard(_ macro: MacroDocument) -> some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(macro.status.uiColor.opacity(0.12))
                Image(systemName: macro.source == .uploadedVideo ? "film.fill" : "bolt.horizontal.circle.fill")
                    .font(.title3).foregroundStyle(macro.status.uiColor)
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(macro.name).font(.headline)
                    StatusPill(text: macro.status.uiTitle, color: macro.status.uiColor)
                }
                HStack(spacing: 9) {
                    Label(macro.source.uiTitle, systemImage: "square.and.arrow.down")
                    Text("·")
                    Label("\(macro.steps.count)단계", systemImage: "list.number")
                    Text("·")
                    Label("조건 \(macro.steps.filter { $0.trigger.isConditional }.count)개", systemImage: "eye")
                }
                .font(.caption).foregroundStyle(AMTheme.textSecondary)
            }
            Spacer()
            Text(macro.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption).foregroundStyle(AMTheme.textSecondary)
            Button {
                model.run(macro)
            } label: {
                Label("실행", systemImage: "play.fill")
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .disabled(!model.permissions.accessibility || model.runningMacroID != nil || macro.status == .draft)
            Button {
                model.presentedMacroID = macro.id
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AMTheme.primary)
            .accessibilityLabel("\(macro.name) 편집")
        }
        .surfaceCard(padding: 16)
        .contextMenu {
            Button("실행") { model.run(macro) }
                .disabled(macro.status == .draft)
            Button("편집") { model.presentedMacroID = macro.id }
            Divider()
            Button("삭제", role: .destructive) { model.delete(macro) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            Spacer()
            ZStack {
                Circle().fill(AMTheme.primarySoft).frame(width: 76, height: 76)
                Image(systemName: searchText.isEmpty ? "rectangle.stack.badge.plus" : "magnifyingglass")
                    .font(.system(size: 30)).foregroundStyle(AMTheme.primary)
            }
            Text(searchText.isEmpty ? "저장된 매크로가 없습니다" : "검색 결과가 없습니다")
                .font(.title3.weight(.semibold))
            Text(searchText.isEmpty ? "시연을 녹화하거나 기존 영상을 가져와 시작하세요." : "다른 검색어를 입력해 보세요.")
                .font(.subheadline).foregroundStyle(AMTheme.textSecondary)
            if searchText.isEmpty {
                Button("새 매크로 만들기") { model.destination = .recorder }
                    .buttonStyle(PrimaryActionButtonStyle())
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
