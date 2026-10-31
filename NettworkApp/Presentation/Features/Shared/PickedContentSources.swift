import ContentSafety
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum PickedContentError: LocalizedError {
    case noSelection
    case unreadablePhoto
    case unsupportedPhotoType
    case photoTooLarge

    var errorDescription: String? {
        switch self {
        case .noSelection: "Select a file to continue."
        case .unreadablePhoto: "The selected photo could not be loaded."
        case .unsupportedPhotoType: "Only JPEG, PNG, HEIC, or HEIF photos can be used as evidence."
        case .photoTooLarge: "The selected photo is too large."
        }
    }
}

/// Platform-built opaque sources for content the user picks in-app. Feature
/// code receives only opaque sources; the picked URL stays inside `file`.
struct PickedContentSources {
    let file: (URL) throws -> any OpaqueContentSource
    let data: (Data, ContentType) -> any OpaqueContentSource

    /// The types a file picker offers; mirrors what each purpose accepts.
    static func pickerTypes(for purpose: ContentPurpose) -> [UTType] {
        let images: [UTType] = [.jpeg, .png, .heic, .heif]
        return purpose == .floorPlan ? [.pdf] + images : images
    }

    /// Opens the first picked URL. A dismissed picker yields nil, not an error.
    static func openSelection(
        _ selection: Result<[URL], Error>,
        open: (URL) throws -> any OpaqueContentSource
    ) throws -> (any OpaqueContentSource)? {
        let urls: [URL]
        do {
            urls = try selection.get()
        } catch let error as CocoaError where error.code == .userCancelled {
            return nil
        }
        guard let url = urls.first else { throw PickedContentError.noSelection }
        return try open(url)
    }

    /// Builds a source for loaded photo bytes, rejecting oversized or non-image
    /// data before it reaches the content-safety service.
    func photoSource(data photoData: Data, types: [UTType]) throws -> any OpaqueContentSource {
        guard photoData.count <= ContentSafetyService.maximumRawImageBytes else { throw PickedContentError.photoTooLarge }
        let type = types.lazy.compactMap { ContentType(utType: $0) }.first { $0.isImage }
        guard let type else { throw PickedContentError.unsupportedPhotoType }
        return data(photoData, type)
    }

    @MainActor func photoSource(_ item: PhotosPickerItem) async throws -> any OpaqueContentSource {
        guard let loaded = try await item.loadTransferable(type: Data.self) else { throw PickedContentError.unreadablePhoto }
        return try photoSource(data: loaded, types: item.supportedContentTypes)
    }
}
