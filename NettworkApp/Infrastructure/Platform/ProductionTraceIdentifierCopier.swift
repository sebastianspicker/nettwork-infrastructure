import Foundation

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

/// Copies only an opaque identifier. Mutable names, addresses, credentials,
/// and topology context never cross this platform boundary.
struct ProductionTraceIdentifierCopier: TraceIdentifierCopying {
    func copy(identifier: String) async {
        guard UUID(uuidString: identifier) != nil else { return }
        await MainActor.run {
            #if os(iOS)
                UIPasteboard.general.string = identifier
            #elseif os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(identifier, forType: .string)
            #endif
        }
    }
}
