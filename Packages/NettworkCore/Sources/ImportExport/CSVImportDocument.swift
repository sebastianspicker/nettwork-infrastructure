import Foundation
import NetworkModel
import WorkspaceChangeControl

/// A bounded, schema-owned collection of CSV files selected for one import.
/// Each table is represented at most once and decoding always follows the
/// lexical order of the published table names.
public struct CSVImportDocument: Hashable, Sendable, CSVImportSource {
    public struct File: Hashable, Sendable {
        public let table: CSVTable
        public let bytes: Data

        public init(table: CSVTable, bytes: Data) throws {
            guard bytes.count <= CSVImportLimits.maximumFileBytes else {
                throw CSVImportError.fileTooLarge
            }
            self.table = table
            self.bytes = bytes
        }
    }

    public let files: [File]

    public init(files: [File]) throws {
        guard !files.isEmpty else { throw CSVImportDocumentError.emptyDocument }

        var tables = Set<CSVTable>()
        var totalBytes = 0
        for file in files {
            guard CSVSchemaV2.templates[file.table] != nil else {
                throw CSVImportDocumentError.missingSchema(file.table.rawValue)
            }
            guard tables.insert(file.table).inserted else {
                throw CSVImportError.duplicateTable(file.table.rawValue)
            }
            guard file.bytes.count <= CSVImportLimits.maximumFileBytes else {
                throw CSVImportError.fileTooLarge
            }
            guard totalBytes <= CSVImportLimits.maximumImportBytes - file.bytes.count else {
                throw CSVImportError.importTooLarge
            }
            totalBytes += file.bytes.count
        }

        self.files = files.sorted { $0.table.rawValue < $1.table.rawValue }
    }

    /// Decodes in deterministic table order through the shared bounded batch decoder.
    public func decodeRecords() throws -> [ImportRecord] {
        try CSVImportBatchDecoder.records(source: self)
    }

    public func fileMetadata() throws -> [CSVImportFileMetadata] {
        try files.map { file in
            guard let template = CSVSchemaV2.templates[file.table] else {
                throw CSVImportDocumentError.missingSchema(file.table.rawValue)
            }
            return CSVImportFileMetadata(template: template, declaredByteCount: file.bytes.count)
        }
    }

    public func openFile(_ metadata: CSVImportFileMetadata) throws -> AnyCSVByteChunkSource {
        guard let file = files.first(where: { $0.table == metadata.table }),
            file.bytes.count == metadata.declaredByteCount
        else { throw CSVImportError.fileTooLarge }
        return AnyCSVByteChunkSource(DataCSVByteChunkSource(data: file.bytes))
    }
}

public enum CSVImportDocumentError: Error, Equatable, Sendable {
    case emptyDocument
    case missingSchema(String)
}

/// A platform document picker must expose only basename entries from its
/// selected directory. Path aliases and alternate file names are not accepted.
public struct CSVImportDocumentEntry: Hashable, Sendable {
    public let filename: String
    public let bytes: Data
    public let isDirectory: Bool

    public init(filename: String, bytes: Data, isDirectory: Bool = false) {
        self.filename = filename
        self.bytes = bytes
        self.isDirectory = isDirectory
    }
}

public enum CSVImportDocumentSourceError: Error, Equatable, Sendable {
    case directory(String)
    case pathComponent(String)
    case duplicateFilename(String)
    case filenameCaseCollision(String)
    case unknownFilename(String)
}

/// Maps the only accepted on-disk names: `<CSVTable.rawValue>.csv`.
public enum CSVImportDocumentFilenames {
    public static func filename(for table: CSVTable) -> String {
        table.rawValue + ".csv"
    }

    public static func document(from entries: [CSVImportDocumentEntry]) throws -> CSVImportDocument {
        try validate(entries)
        return try CSVImportDocument(files: entries.map(file))
    }

    private static func validate(_ entries: [CSVImportDocumentEntry]) throws {
        var filenames = Set<String>()
        var foldedFilenames = Set<String>()
        for entry in entries {
            guard !entry.isDirectory else {
                throw CSVImportDocumentSourceError.directory(entry.filename)
            }
            guard isBasename(entry.filename) else {
                throw CSVImportDocumentSourceError.pathComponent(entry.filename)
            }
            guard filenames.insert(entry.filename).inserted else {
                throw CSVImportDocumentSourceError.duplicateFilename(entry.filename)
            }
            guard foldedFilenames.insert(entry.filename.lowercased()).inserted else {
                throw CSVImportDocumentSourceError.filenameCaseCollision(entry.filename)
            }
        }
    }

    private static func file(_ entry: CSVImportDocumentEntry) throws -> CSVImportDocument.File {
        guard let table = CSVTable.allCases.first(where: { filename(for: $0) == entry.filename }) else {
            if CSVTable.allCases.contains(where: { filename(for: $0).caseInsensitiveCompare(entry.filename) == .orderedSame }) {
                throw CSVImportDocumentSourceError.filenameCaseCollision(entry.filename)
            }
            throw CSVImportDocumentSourceError.unknownFilename(entry.filename)
        }
        return try CSVImportDocument.File(table: table, bytes: entry.bytes)
    }

    private static func isBasename(_ filename: String) -> Bool {
        !filename.isEmpty && !filename.contains("/") && !filename.contains("\\")
    }
}
