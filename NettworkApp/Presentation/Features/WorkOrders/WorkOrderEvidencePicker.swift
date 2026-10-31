import ContentSafety
import PhotosUI
import SwiftUI

/// Offers a photo or a file as evidence when the organization supplies no
/// evidence source. One file importer and one photo picker serve the screen.
struct WorkOrderEvidencePicker: ViewModifier {
    @Binding var isChoosing: Bool
    let onFile: (Result<[URL], Error>) -> Void
    let onPhoto: (PhotosPickerItem) -> Void
    @State private var isPickingPhoto = false
    @State private var isPickingFile = false
    @State private var photo: PhotosPickerItem?

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Choose evidence", isPresented: $isChoosing, titleVisibility: .visible) {
                Button("Photo library") { isPickingPhoto = true }
                    .accessibilityIdentifier("work-order.evidence.photo")
                Button("File") { isPickingFile = true }
                    .accessibilityIdentifier("work-order.evidence.file")
                Button("Cancel", role: .cancel) {}
            }
            .photosPicker(isPresented: $isPickingPhoto, selection: $photo, matching: .images)
            .fileImporter(
                isPresented: $isPickingFile,
                allowedContentTypes: PickedContentSources.pickerTypes(for: .evidence),
                allowsMultipleSelection: false,
                onCompletion: onFile
            )
            .onChange(of: photo) { _, item in
                guard let item else { return }
                photo = nil
                onPhoto(item)
            }
    }
}
