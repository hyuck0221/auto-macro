import SwiftUI

enum AMTheme {
    static let background = Color(red: 0.035, green: 0.055, blue: 0.11)
    static let surface = Color.white.opacity(0.065)
    static let raisedSurface = Color.white.opacity(0.095)
    static let border = Color.white.opacity(0.10)
    static let primary = Color(red: 0.28, green: 0.91, blue: 0.77)
    static let primarySoft = primary.opacity(0.14)
    static let coral = Color(red: 1.0, green: 0.47, blue: 0.34)
    static let textSecondary = Color.white.opacity(0.62)
    static let success = Color(red: 0.35, green: 0.86, blue: 0.58)
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.28)

    static let cornerRadius: CGFloat = 18
    static let smallCornerRadius: CGFloat = 11
}

struct SurfaceCard: ViewModifier {
    var padding: CGFloat = 20
    var elevated = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(elevated ? AMTheme.raisedSurface : AMTheme.surface)
            .overlay {
                RoundedRectangle(cornerRadius: AMTheme.cornerRadius, style: .continuous)
                    .stroke(AMTheme.border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: AMTheme.cornerRadius, style: .continuous))
    }
}

extension View {
    func surfaceCard(padding: CGFloat = 20, elevated: Bool = false) -> some View {
        modifier(SurfaceCard(padding: padding, elevated: elevated))
    }
}

struct AppMark: View {
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [AMTheme.primary, Color(red: 0.1, green: 0.65, blue: 0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.system(size: size * 0.47, weight: .bold))
                .foregroundStyle(AMTheme.background)
        }
        .frame(width: size, height: size)
        .shadow(color: AMTheme.primary.opacity(0.25), radius: 12, y: 4)
        .accessibilityHidden(true)
    }
}

struct StatusPill: View {
    let text: String
    var color: Color = AMTheme.primary
    var systemImage: String?

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
}

struct SectionHeading: View {
    let title: String
    var subtitle: String?
    var trailingTitle: String?
    var trailingAction: (() -> Void)?

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(AMTheme.textSecondary)
                }
            }
            Spacer()
            if let trailingTitle, let trailingAction {
                Button(trailingTitle, action: trailingAction)
                    .buttonStyle(.plain)
                    .foregroundStyle(AMTheme.primary)
                    .font(.subheadline.weight(.semibold))
            }
        }
    }
}

struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(AMTheme.background)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(AMTheme.primary.opacity(configuration.isPressed ? 0.76 : 1))
            .clipShape(RoundedRectangle(cornerRadius: AMTheme.smallCornerRadius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct SecondaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(Color.white.opacity(configuration.isPressed ? 0.06 : 0.10))
            .overlay {
                RoundedRectangle(cornerRadius: AMTheme.smallCornerRadius, style: .continuous)
                    .stroke(AMTheme.border)
            }
            .clipShape(RoundedRectangle(cornerRadius: AMTheme.smallCornerRadius, style: .continuous))
    }
}

struct PermissionBadge: View {
    let title: String
    let granted: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? AMTheme.success : AMTheme.warning)
            Text(title)
                .foregroundStyle(.white.opacity(0.85))
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.06))
        .clipShape(Capsule())
    }
}
