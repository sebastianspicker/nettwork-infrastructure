import SwiftUI

extension View {
    /// An OK alert shown while `message` is non-nil; closing it calls `dismiss`.
    func errorAlert(_ title: String, message: String?, dismiss: @escaping () -> Void) -> some View {
        alert(title, isPresented: Binding(get: { message != nil }, set: { if !$0 { dismiss() } })) {
            Button("OK", role: .cancel, action: dismiss)
        } message: {
            Text(message ?? "")
        }
    }
}
