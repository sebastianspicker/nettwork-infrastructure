import Foundation

/// A document is handed to the platform archive writer one entry at a time.
/// This core module never asks an archive library to extract or write a tree.
public struct ArchiveExportDocument: Sendable {
    public let manifest: ArchiveManifest
    public let completionMarker: ArchiveCompletionMarker
    public let entries: [String: Data]
}
