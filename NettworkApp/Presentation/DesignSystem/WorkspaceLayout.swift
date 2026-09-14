import SwiftUI

/// Shared title treatment for a task surface. It remains readable at large text sizes.
struct NettworkPageHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String

    init(_ title: String, subtitle: String, systemImage: String) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .top, spacing: NettworkSpacing.medium) {
            Image(systemName: systemImage)
                .font(.title2.weight(.medium))
                .foregroundStyle(Color.nettworkAccent)
                .frame(width: 44, height: 44)
                .background(Color.nettworkAccent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NettworkSpacing.small) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, NettworkSpacing.small)
    }
}

struct NettworkDetailSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: NettworkSpacing.medium) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(NettworkSpacing.large)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
    }
}
