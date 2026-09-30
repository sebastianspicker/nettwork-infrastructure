import Foundation
import ImportExport
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A directory package. The visible filename is supplied by the export UI
    /// with the `.nettworkarchive` extension.
    static let nettworkArchive = UTType(exportedAs: "com.example.nettwork.archive", conformingTo: .package)

    /// A directory package containing exactly the published CSV workspace files.
    static let nettworkCSVWorkspace = UTType(exportedAs: "com.example.nettwork.csv-workspace", conformingTo: .package)
}

enum TransferDocumentError: LocalizedError {
    case invalidPackage
    case invalidExportDocument

    var errorDescription: String? {
        switch self {
        case .invalidPackage:
            "The selected item is not a .nettworkarchive directory package."
        case .invalidExportDocument:
            "The verified archive could not be represented as a directory package."
        }
    }
}

enum CSVWorkspaceDocumentError: LocalizedError {
    case incompleteTables
    case oversizedFile(String)
    case oversizedPackage
    case duplicateFilename(String)

    var errorDescription: String? {
        switch self {
        case .incompleteTables: "The CSV workspace export does not contain every published table."
        case .oversizedFile(let filename): "The CSV export file is too large: \(filename)."
        case .oversizedPackage: "The CSV workspace export exceeds the package size limit."
        case .duplicateFilename(let filename): "The CSV workspace export contains a duplicate filename: \(filename)."
        }
    }
}

/// A FileDocument writer for the already-verified core export document. It
/// creates only package directories required to hold the document's entries;
/// it never expands an external archive or synthesizes another payload.
struct NettworkArchiveDocument: FileDocument, @unchecked Sendable {
    static var readableContentTypes: [UTType] { [.nettworkArchive] }
    static var writableContentTypes: [UTType] { [.nettworkArchive] }

    private let package: FileWrapper

    init(exportDocument: ArchiveExportDocument) throws {
        package = try Self.packageWrapper(for: exportDocument.entries)
    }

    init(configuration: ReadConfiguration) throws {
        guard configuration.file.isDirectory else {
            throw TransferDocumentError.invalidPackage
        }
        package = configuration.file
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        package
    }

    private static func packageWrapper(for entries: [String: Data]) throws -> FileWrapper {
        guard entries.count <= ArchiveSafetyLimits.maximumEntries else {
            throw ArchiveValidationError.archiveTooLarge
        }

        let root = FileWrapper(directoryWithFileWrappers: [:])
        var collisionKeys = Set<String>()
        var totalBytes = 0

        for (rawPath, bytes) in entries.sorted(by: { $0.key < $1.key }) {
            let path = try ArchivePathPolicy.normalized(rawPath)
            guard ArchivePathPolicy.isAllowed(path, kind: .regularFile),
                collisionKeys.insert(ArchivePathPolicy.collisionKey(path)).inserted,
                bytes.count <= ArchiveSafetyLimits.maximumEntryBytes,
                totalBytes <= ArchiveSafetyLimits.maximumExpandedBytes - bytes.count
            else {
                throw TransferDocumentError.invalidExportDocument
            }
            totalBytes += bytes.count
            try addFile(bytes, at: path, to: root)
        }

        return root
    }

    private static func addFile(_ bytes: Data, at path: String, to root: FileWrapper) throws {
        let components = path.split(separator: "/").map(String.init)
        guard let filename = components.last else {
            throw TransferDocumentError.invalidExportDocument
        }

        var directory = root
        for component in components.dropLast() {
            if let existing = directory.fileWrappers?[component] {
                guard existing.isDirectory else {
                    throw TransferDocumentError.invalidExportDocument
                }
                directory = existing
                continue
            }

            let child = FileWrapper(directoryWithFileWrappers: [:])
            child.preferredFilename = component
            directory.addFileWrapper(child)
            directory = child
        }

        guard directory.fileWrappers?[filename] == nil else {
            throw TransferDocumentError.invalidExportDocument
        }
        let file = FileWrapper(regularFileWithContents: bytes)
        file.preferredFilename = filename
        directory.addFileWrapper(file)
    }
}

/// Writes the already-encoded core files without changing their filenames or
/// bytes. This is deliberately a package so a save/share destination receives
/// every schema table as canonical `<CSVTable>.csv` entries.
struct NettworkCSVWorkspaceDocument: FileDocument, @unchecked Sendable {
    static var readableContentTypes: [UTType] { [.nettworkCSVWorkspace] }
    static var writableContentTypes: [UTType] { [.nettworkCSVWorkspace] }

    private let package: FileWrapper

    init(exportDocument: CSVWorkspaceExportDocument) throws {
        package = try Self.packageWrapper(for: exportDocument)
    }

    init(configuration: ReadConfiguration) throws {
        package = configuration.file
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { package }

    private static func packageWrapper(for document: CSVWorkspaceExportDocument) throws -> FileWrapper {
        guard Set(document.files.map(\.table)) == Set(CSVTable.allCases) else {
            throw CSVWorkspaceDocumentError.incompleteTables
        }
        var totalBytes = 0
        var filenames = Set<String>()
        let directory = FileWrapper(directoryWithFileWrappers: [:])
        for file in document.files.sorted(by: { $0.table.rawValue < $1.table.rawValue }) {
            let filename = CSVImportDocumentFilenames.filename(for: file.table)
            guard filenames.insert(filename).inserted else {
                throw CSVWorkspaceDocumentError.duplicateFilename(filename)
            }
            guard file.bytes.count <= CSVImportLimits.maximumFileBytes else {
                throw CSVWorkspaceDocumentError.oversizedFile(filename)
            }
            guard totalBytes <= CSVImportLimits.maximumImportBytes - file.bytes.count else {
                throw CSVWorkspaceDocumentError.oversizedPackage
            }
            totalBytes += file.bytes.count
            let child = FileWrapper(regularFileWithContents: file.bytes)
            child.preferredFilename = filename
            directory.addFileWrapper(child)
        }
        return directory
    }
}
