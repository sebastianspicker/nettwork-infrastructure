import SwiftUI

struct InspectorPropertyRow<Value: View>: View {
    private let title: LocalizedStringKey
    private let valueFont: Font
    private let value: Value

    init(_ title: LocalizedStringKey, valueFont: Font = .callout, @ViewBuilder value: () -> Value) {
        self.title = title
        self.valueFont = valueFont
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NettworkSpacing.standard) {
            Text(title)
                .font(NettworkTypography.inspectorLabel)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            value
                .font(valueFont)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, NettworkSpacing.small)
        .frame(minHeight: NettworkSpacing.minimumControlSize, alignment: .leading)
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }
}

extension InspectorPropertyRow where Value == Text {
    init(_ title: LocalizedStringKey, value: String, isIdentifier: Bool = false) {
        self.init(title, valueFont: isIdentifier ? NettworkTypography.compactIdentifier : .callout) { Text(value) }
    }
}

enum NettworkNoticeStyle: Sendable {
    case information
    case success
    case warning
    case critical

    var role: NettworkStatusRole {
        switch self {
        case .information: .information
        case .success: .ready
        case .warning: .offline
        case .critical: .conflict
        }
    }
}

/// A concise, non-modal operational notice. It pairs semantic color with a
/// symbol and visible text so the outcome is not conveyed by color alone.
struct NettworkNotice: View {
    private let title: LocalizedStringKey
    private let message: String
    private let style: NettworkNoticeStyle

    init(_ title: LocalizedStringKey, message: String, style: NettworkNoticeStyle = .information) {
        self.title = title
        self.message = message
        self.style = style
    }

    var body: some View {
        HStack(alignment: .top, spacing: NettworkSpacing.standard) {
            Image(systemName: style.role.symbolName)
                .font(.body.weight(.semibold))
                .foregroundStyle(style.role.color)
                .frame(width: NettworkSpacing.minimumControlSize, height: NettworkSpacing.minimumControlSize)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: NettworkSpacing.xSmall) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, NettworkSpacing.standard)
        }
        .padding(.trailing, NettworkSpacing.standard)
        .background(style.role.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct NettworkEmptyState: View {
    private let title: LocalizedStringKey
    private let systemImage: String
    private let message: String

    init(_ title: LocalizedStringKey, systemImage: String, message: String) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
    }

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
            .accessibilityElement(children: .combine)
    }
}

struct NettworkLoadingState: View {
    private let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        ProgressView(title)
            .controlSize(.regular)
            .padding(NettworkSpacing.large)
            .accessibilityElement(children: .combine)
    }
}
