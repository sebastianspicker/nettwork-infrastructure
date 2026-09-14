import SwiftUI

/// Shared layout and typography values for the infrastructure workbench.
///
/// These values intentionally mirror the compact operational layout without
/// fixing text to a point size. Native text styles continue to respond to the
/// user's Dynamic Type setting.
enum NettworkSpacing {
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let standard: CGFloat = 12
    static let medium: CGFloat = 16
    static let large: CGFloat = 24
    static let xLarge: CGFloat = 32

    #if os(macOS)
        static let minimumControlSize: CGFloat = 28
    #else
        static let minimumControlSize: CGFloat = 44
    #endif
}

enum NettworkDensity: Sendable {
    case compact
    case standard
    case spacious

    var itemSpacing: CGFloat {
        switch self {
        case .compact: NettworkSpacing.small
        case .standard: NettworkSpacing.standard
        case .spacious: NettworkSpacing.medium
        }
    }

    var panePadding: CGFloat {
        switch self {
        case .compact: NettworkSpacing.standard
        case .standard: NettworkSpacing.medium
        case .spacious: NettworkSpacing.large
        }
    }
}

enum NettworkTypography {
    static let metric = Font.title3.weight(.semibold).monospacedDigit()
    static let metricDetail = Font.subheadline.monospacedDigit()
    static let identifier = Font.system(.body, design: .monospaced)
    static let compactIdentifier = Font.system(.footnote, design: .monospaced)
    static let inspectorLabel = Font.caption.weight(.medium)
}

enum NettworkPaneStyle: Sendable {
    case workspace
    case inspector
    case elevated

    var cornerRadius: CGFloat {
        switch self {
        case .workspace, .inspector: 0
        case .elevated: 11
        }
    }
}

/// A restrained pane treatment for work areas and inspectors.
///
/// Use this for a single task surface, rather than as a generic card wrapper.
struct NettworkPane<Content: View>: View {
    private let style: NettworkPaneStyle
    private let density: NettworkDensity
    private let content: Content

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(
        style: NettworkPaneStyle = .workspace,
        density: NettworkDensity = .standard,
        @ViewBuilder content: () -> Content
    ) {
        self.style = style
        self.density = density
        self.content = content()
    }

    var body: some View {
        content
            .padding(density.panePadding)
            .background(Color.nettworkSurface, in: RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(borderOpacity), lineWidth: 1)
            }
    }

    private var borderOpacity: Double {
        colorSchemeContrast == .increased ? 0.32 : 0.12
    }
}

extension View {
    /// Keeps custom control labels comfortably tappable without changing their
    /// visual alignment inside a larger control.
    func nettworkMinimumControlTarget() -> some View {
        frame(minWidth: NettworkSpacing.minimumControlSize, minHeight: NettworkSpacing.minimumControlSize)
    }
}
