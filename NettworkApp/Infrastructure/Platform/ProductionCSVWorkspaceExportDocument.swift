import Foundation
import ImportExport
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A directory package containing exactly the published CSV workspace files.
    static let nettworkCSVWorkspace = UTType(exportedAs: "com.example.nettwork.csv-workspace", conformingTo: .package)
}

enum ProductionCSVWorkspaceExportDocumentError: LocalizedError {
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
            throw ProductionCSVWorkspaceExportDocumentError.incompleteTables
        }
        var totalBytes = 0
        var filenames = Set<String>()
        let directory = FileWrapper(directoryWithFileWrappers: [:])
        for file in document.files.sorted(by: { $0.table.rawValue < $1.table.rawValue }) {
            let filename = CSVImportDocumentFilenames.filename(for: file.table)
            guard filenames.insert(filename).inserted else {
                throw ProductionCSVWorkspaceExportDocumentError.duplicateFilename(filename)
            }
            guard file.bytes.count <= CSVImportLimits.maximumFileBytes else {
                throw ProductionCSVWorkspaceExportDocumentError.oversizedFile(filename)
            }
            guard totalBytes <= CSVImportLimits.maximumImportBytes - file.bytes.count else {
                throw ProductionCSVWorkspaceExportDocumentError.oversizedPackage
            }
            totalBytes += file.bytes.count
            let child = FileWrapper(regularFileWithContents: file.bytes)
            child.preferredFilename = filename
            directory.addFileWrapper(child)
        }
        return directory
    }
}
