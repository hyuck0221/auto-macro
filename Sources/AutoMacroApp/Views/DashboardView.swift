import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: AppModel

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                hero
                metrics
                recent
            }
            .frame(maxWidth: 1120, alignment: .leading)
            .padding(32)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("좋은 오후예요")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AMTheme.primary)
                    .textCase(.uppercase)
                Text("반복은 Auto Macro에게 맡기세요")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
            }
            Spacer()
            HStack(spacing: 8) {
                PermissionBadge(title: "화면", granted: model.permissions.screenRecording)
                PermissionBadge(title: "입력", granted: model.permissions.inputMonitoring)
                PermissionBadge(title: "실행", granted: model.permissions.accessibility)
            }
        }
    }

    private var hero: some View {
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.06, green: 0.19, blue: 0.22), Color(red: 0.04, green: 0.07, blue: 0.14)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(AMTheme.primary.opacity(0.18))
                }

            Circle()
                .fill(AMTheme.primary.opacity(0.07))
                .frame(width: 280)
                .blur(radius: 2)
                .offset(x: 62, y: -20)

            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.system(size: 124, weight: .ultraLight))
                .foregroundStyle(AMTheme.primary.opacity(0.16))
                .padding(.trailing, 62)

            HStack {
                VStack(alignment: .leading, spacing: 15) {
                    StatusPill(text: "AI-ADAPTIVE", color: AMTheme.primary, systemImage: "sparkle")
                    Text("보는 순간,\n다음 동작을 실행합니다.")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("화면 변화와 입력 타이밍을 함께 학습해\n접속 속도가 달라도 흐름을 놓치지 않습니다.")
                        .font(.body)
                        .foregroundStyle(AMTheme.textSecondary)
                        .lineSpacing(4)
                    HStack(spacing: 10) {
                        Button {
                            model.destination = .recorder
                        } label: {
                            Label("새 녹화 시작", systemImage: "record.circle.fill")
                        }
                        .buttonStyle(PrimaryActionButtonStyle())

                        Button {
                            model.importVideo()
                        } label: {
                            Label("영상 가져오기", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(SecondaryActionButtonStyle())
                    }
                }
                Spacer()
            }
            .padding(30)
        }
        .frame(minHeight: 290)
    }

    private var metrics: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            MetricCard(
                title: "저장된 매크로",
                value: "\(model.macros.count)",
                detail: "준비된 자동화",
                symbol: "rectangle.stack.fill",
                color: AMTheme.primary
            )
            MetricCard(
                title: "조건형 단계",
                value: "\(model.conditionalStepCount)",
                detail: "화면을 보고 실행",
                symbol: "eye.fill",
                color: Color(red: 0.42, green: 0.70, blue: 1.0)
            )
            MetricCard(
                title: "AI 상태",
                value: model.isActiveProviderReady ? "준비됨" : "설정 필요",
                detail: model.activeProviderName,
                symbol: "sparkles",
                color: model.isActiveProviderReady ? AMTheme.success : AMTheme.warning
            )
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(
                title: "최근 매크로",
                subtitle: "가장 최근에 편집한 흐름",
                trailingTitle: "전체 보기",
                trailingAction: { model.destination = .library }
            )

            if model.macros.isEmpty {
                EmptyMacroCard { model.destination = .recorder }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.macros.prefix(4).enumerated()), id: \.element.id) { index, macro in
                        MacroRow(macro: macro) {
                            model.presentedMacroID = macro.id
                        }
                        if index < min(model.macros.count, 4) - 1 {
                            Divider().overlay(AMTheme.border).padding(.leading, 54)
                        }
                    }
                }
                .surfaceCard(padding: 5)
            }
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(color.opacity(0.13))
                Image(systemName: symbol).font(.title3).foregroundStyle(color)
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(AMTheme.textSecondary)
                Text(value).font(.title3.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
                Text(detail).font(.caption2).foregroundStyle(AMTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .surfaceCard(padding: 16)
    }
}

struct MacroRow: View {
    let macro: MacroDocument
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(AMTheme.primarySoft)
                    Image(systemName: "bolt.horizontal.circle.fill").foregroundStyle(AMTheme.primary)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(macro.name).font(.body.weight(.semibold)).foregroundStyle(.white)
                    Text("\(macro.steps.count)단계 · \(macro.updatedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(AMTheme.textSecondary)
                }
                Spacer()
                StatusPill(text: macro.status.uiTitle, color: macro.status.uiColor)
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.white.opacity(0.3))
            }
            .padding(11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct EmptyMacroCard: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wand.and.stars.inverse")
                .font(.system(size: 32))
                .foregroundStyle(AMTheme.primary)
            Text("첫 번째 흐름을 보여주세요").font(.headline)
            Text("녹화를 시작하면 화면과 입력을 함께 분석해\n조건형 매크로를 자동으로 만듭니다.")
                .font(.subheadline).foregroundStyle(AMTheme.textSecondary).multilineTextAlignment(.center)
            Button("새 매크로 만들기", action: action).buttonStyle(PrimaryActionButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .surfaceCard()
    }
}
