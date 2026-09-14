import Foundation
import WorkspaceChangeControl

public struct CSVImportFileMetadata: Hashable, Sendable {
    public let template: CSVTemplate
    public let declaredByteCount: Int

    public init(template: CSVTemplate, declaredByteCount: Int) {
        self.template = template
        self.declaredByteCount = declaredByteCount
    }

    public var table: CSVTable { template.table }
}

/// A document exposes metadata without opening payload files, then supplies a
/// fresh reader for each dry-run or activation pass.
public protocol CSVImportSource: Sendable {
    func fileMetadata() throws -> [CSVImportFileMetadata]
    func openFile(_ file: CSVImportFileMetadata) throws -> AnyCSVByteChunkSource
}

public protocol CSVImportSourceAccessLifetime: AnyObject, Sendable {
    func close()
}

public enum CSVImportBatchDecoder {
    public static func records(files: [(CSVTemplate, Data)]) throws -> [ImportRecord] {
        guard !files.isEmpty else { return [] }
        return try records(source: InMemoryCSVImportSource(files: files))
    }

    public static func records(source: any CSVImportSource) throws -> [ImportRecord] {
        let files = try validatedMetadata(source.fileMetadata())
        var imported: [ImportRecord] = []
        var actualBytes = 0
        for file in files {
            let input = try source.openFile(file)
            var budgeted = ActualByteBudgetSource(base: input, aggregateBytes: actualBytes)
            let remainingRows = CSVImportLimits.maximumRowsTotal - imported.count
            let records: [ImportRecord]
            do {
                records = try CSVImportDecoder.records(
                    from: &budgeted, template: file.template,
                    maximumRecords: min(CSVImportLimits.maximumRowsPerTable, remainingRows))
            } catch CSVImportError.tooManyRows(_) where remainingRows < CSVImportLimits.maximumRowsPerTable {
                throw CSVImportError.tooManyRows(table: "import")
            }
            actualBytes = budgeted.aggregateBytes
            guard records.count <= CSVImportLimits.maximumRowsTotal - imported.count else {
                throw CSVImportError.tooManyRows(table: "import")
            }
            imported.append(contentsOf: records)
        }
        return imported
    }

    private static func validatedMetadata(_ supplied: [CSVImportFileMetadata]) throws -> [CSVImportFileMetadata] {
        guard !supplied.isEmpty else { throw CSVImportDocumentError.emptyDocument }
        var tables = Set<CSVTable>()
        var totalBytes = 0
        for file in supplied {
            guard CSVSchemaV2.templates[file.table] != nil else {
                throw CSVImportDocumentError.missingSchema(file.table.rawValue)
            }
            guard tables.insert(file.table).inserted else {
                throw CSVImportError.duplicateTable(file.table.rawValue)
            }
            guard file.declaredByteCount >= 0,
                file.declaredByteCount <= CSVImportLimits.maximumFileBytes
            else { throw CSVImportError.fileTooLarge }
            guard file.declaredByteCount <= CSVImportLimits.maximumImportBytes - totalBytes else {
                throw CSVImportError.importTooLarge
            }
            totalBytes += file.declaredByteCount
        }
        return supplied
    }
}

private struct InMemoryCSVImportSource: CSVImportSource {
    private let dataByTable: [CSVTable: Data]
    private let metadata: [CSVImportFileMetadata]

    init(files: [(CSVTemplate, Data)]) throws {
        var values: [CSVTable: Data] = [:]
        var metadata: [CSVImportFileMetadata] = []
        for (template, data) in files {
            guard values.updateValue(data, forKey: template.table) == nil else {
                throw CSVImportError.duplicateTable(template.table.rawValue)
            }
            metadata.append(.init(template: template, declaredByteCount: data.count))
        }
        dataByTable = values
        self.metadata = metadata
    }

    func fileMetadata() throws -> [CSVImportFileMetadata] { metadata }

    func openFile(_ file: CSVImportFileMetadata) throws -> AnyCSVByteChunkSource {
        guard let data = dataByTable[file.table], data.count == file.declaredByteCount else {
            throw CSVImportError.fileTooLarge
        }
        return AnyCSVByteChunkSource(DataCSVByteChunkSource(data: data))
    }
}

private struct ActualByteBudgetSource: CSVByteChunkSource {
    private var base: AnyCSVByteChunkSource
    private(set) var aggregateBytes: Int
    private var fileBytes = 0

    init(base: AnyCSVByteChunkSource, aggregateBytes: Int) {
        self.base = base
        self.aggregateBytes = aggregateBytes
    }

    mutating func nextChunk() throws -> Data? {
        guard let chunk = try base.nextChunk() else { return nil }
        guard chunk.count <= CSVImportLimits.maximumFileBytes - fileBytes else {
            throw CSVImportError.fileTooLarge
        }
        guard chunk.count <= CSVImportLimits.maximumImportBytes - aggregateBytes else {
            throw CSVImportError.importTooLarge
        }
        fileBytes += chunk.count
        aggregateBytes += chunk.count
        return chunk
    }
}
