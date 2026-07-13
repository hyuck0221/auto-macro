import AppKit
import ApplicationServices
import CoreGraphics

public enum AutomationPermission: String, CaseIterable, Sendable {
    case screenRecording
    case accessibility
    case inputMonitoring
    case eventPosting
}

public enum AutomationPermissionStatus: String, Sendable {
    case authorized
    case notGranted

    public var isAuthorized: Bool { self == .authorized }
}

public struct PermissionSnapshot: Sendable, Equatable {
    public let screenRecording: AutomationPermissionStatus
    public let accessibility: AutomationPermissionStatus
    public let inputMonitoring: AutomationPermissionStatus
    public let eventPosting: AutomationPermissionStatus

    public var canRecord: Bool {
        screenRecording.isAuthorized &&
            accessibility.isAuthorized &&
            inputMonitoring.isAuthorized
    }

    public var canRunMacros: Bool {
        accessibility.isAuthorized && eventPosting.isAuthorized
    }
}

/// Thin wrapper around macOS privacy APIs. macOS does not expose whether a
/// privacy prompt has never been shown, so a missing grant is intentionally
/// reported as `notGranted` rather than guessing between denied/undetermined.
public final class PermissionService: Sendable {
    public init() {}

    public func status(for permission: AutomationPermission) -> AutomationPermissionStatus {
        let authorized: Bool
        switch permission {
        case .screenRecording:
            authorized = CGPreflightScreenCaptureAccess()
        case .accessibility:
            authorized = AXIsProcessTrusted()
        case .inputMonitoring:
            authorized = CGPreflightListenEventAccess()
        case .eventPosting:
            authorized = CGPreflightPostEventAccess()
        }
        return authorized ? .authorized : .notGranted
    }

    public func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            screenRecording: status(for: .screenRecording),
            accessibility: status(for: .accessibility),
            inputMonitoring: status(for: .inputMonitoring),
            eventPosting: status(for: .eventPosting)
        )
    }

    @discardableResult
    public func request(_ permission: AutomationPermission) -> AutomationPermissionStatus {
        switch permission {
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .accessibility:
            // The imported global is not concurrency-safe under Swift 6. Its
            // documented CFString value is stable and avoids shared mutable state.
            let options = ["AXTrustedCheckOptionPrompt": true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        case .eventPosting:
            _ = CGRequestPostEventAccess()
        }
        return status(for: permission)
    }

    @MainActor
    @discardableResult
    public func openSystemSettings(for permission: AutomationPermission) -> Bool {
        let anchor: String
        switch permission {
        case .screenRecording:
            anchor = "Privacy_ScreenCapture"
        case .accessibility, .eventPosting:
            anchor = "Privacy_Accessibility"
        case .inputMonitoring:
            anchor = "Privacy_ListenEvent"
        }

        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }
}
