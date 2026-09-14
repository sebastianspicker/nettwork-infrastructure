import SwiftUI

/// Cross-platform seam for concise status and error announcements. Platform
/// composition can inject an alternate adapter without pulling UIKit
/// or AppKit into shared SwiftUI feature code.
@MainActor
protocol AccessibilityStatusAnnouncing {
    func announce(_ message: String)
}

@MainActor
struct AccessibilityStatusAnnouncer: AccessibilityStatusAnnouncing {
    private let handler: @MainActor (String) -> Void

    init(
        handler: @escaping @MainActor (String) -> Void = { message in
            AccessibilityNotification.Announcement(message).post()
        }
    ) {
        self.handler = handler
    }

    func announce(_ message: String) {
        handler(message)
    }
}

/// Gives text-based status a stable identifier and an accessibility value, so
/// it does not depend on an icon or tint to communicate state.
struct AccessibilityStatusModifier: ViewModifier {
    let value: String
    let identifier: String

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Status")
            .accessibilityValue(value)
            .accessibilityIdentifier(identifier)
    }
}

extension View {
    func accessibilityStatus(_ value: String, identifier: String) -> some View {
        modifier(AccessibilityStatusModifier(value: value, identifier: identifier))
    }
}
