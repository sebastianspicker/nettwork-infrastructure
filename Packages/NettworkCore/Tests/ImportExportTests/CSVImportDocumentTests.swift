import Foundation
import XCTest

@testable import ImportExport

final class CSVImportDocumentTests: XCTestCase {
    func testDocumentRejectsEmptyAndDuplicateTables() throws {
        XCTAssertThrowsError(try CSVImportDocument(files: [])) { error in
            XCTAssertEqual(error as? CSVImportDocumentError, .emptyDocument)
        }

        let file = try CSVImportDocument.File(table: .devices, bytes: csv(table: .devices, name: "edge"))
        XCTAssertThrowsError(try CSVImportDocument(files: [file, file])) { error in
            XCTAssertEqual(error as? CSVImportError, .duplicateTable(CSVTable.devices.rawValue))
        }
    }

    func testDocumentRejectsPerFileAndAggregateByteLimits() throws {
        XCTAssertThrowsError(
            try CSVImportDocument.File(
                table: .devices,
                bytes: Data(repeating: 0, count: CSVImportLimits.maximumFileBytes + 1)
            )
        ) { error in
            XCTAssertEqual(error as? CSVImportError, .fileTooLarge)
        }

        let maximumFile = Data(repeating: 0, count: CSVImportLimits.maximumFileBytes)
        let tables = Array(CSVTable.allCases.prefix(5))
        var files = try tables.prefix(4).map { try CSVImportDocument.File(table: $0, bytes: maximumFile) }
        files.append(try CSVImportDocument.File(table: tables[4], bytes: Data([0])))
        XCTAssertThrowsError(try CSVImportDocument(files: files)) { error in
            XCTAssertEqual(error as? CSVImportError, .importTooLarge)
        }
    }

    func testExactFilenameMapperRejectsDirectoriesUnknownNamesAndCaseCollisions() throws {
        XCTAssertEqual(CSVImportDocumentFilenames.filename(for: .deviceTypes), "device_types.csv")
        XCTAssertThrowsError(
            try CSVImportDocumentFilenames.document(from: [
                .init(filename: "devices.csv", bytes: Data(), isDirectory: true)
            ])
        ) { error in
            XCTAssertEqual(error as? CSVImportDocumentSourceError, .directory("devices.csv"))
        }
        XCTAssertThrowsError(
            try CSVImportDocumentFilenames.document(from: [
                .init(filename: "devices.txt", bytes: Data())
            ])
        ) { error in
            XCTAssertEqual(error as? CSVImportDocumentSourceError, .unknownFilename("devices.txt"))
        }
        XCTAssertThrowsError(
            try CSVImportDocumentFilenames.document(from: [
                .init(filename: "Devices.csv", bytes: Data())
            ])
        ) { error in
            XCTAssertEqual(error as? CSVImportDocumentSourceError, .filenameCaseCollision("Devices.csv"))
        }
        XCTAssertThrowsError(
            try CSVImportDocumentFilenames.document(from: [
                .init(filename: "devices.csv", bytes: Data()),
                .init(filename: "devices.csv", bytes: Data()),
            ])
        ) { error in
            XCTAssertEqual(error as? CSVImportDocumentSourceError, .duplicateFilename("devices.csv"))
        }
    }

    func testDocumentSortsTablesBeforeBatchDecoding() throws {
        let document = try CSVImportDocument(files: [
            .init(table: .locations, bytes: csv(table: .locations, name: "Berlin")),
            .init(table: .devices, bytes: csv(table: .devices, name: "edge")),
        ])

        XCTAssertEqual(document.files.map(\.table), [.devices, .locations])
        XCTAssertEqual(
            try document.decodeRecords().map(\.table),
            [CSVTable.devices.rawValue, CSVTable.locations.rawValue]
        )
    }

    func testStreamingParserStopsReadingWhenRowCallbackThrows() {
        struct Stop: Error {}
        var source = CountingCSVSource(
            data: Data("a,b\r\nc,d\r\ne,f\r\n".utf8), chunkSize: 1)
        XCTAssertThrowsError(
            try RFC4180Parser.forEachRow(source: &source) { _ in throw Stop() })
        XCTAssertLessThan(source.bytesRead, source.data.count)
    }

    func testBatchMetadataLimitsAreCheckedBeforeOpeningAnyFile() {
        let template = CSVSchemaV2.templates[.devices]!
        let source = TrackingCSVSource(
            metadata: [
                .init(template: template, declaredByteCount: 1),
                .init(template: template, declaredByteCount: 1),
            ])

        XCTAssertThrowsError(try CSVImportBatchDecoder.records(source: source)) { error in
            XCTAssertEqual(error as? CSVImportError, .duplicateTable(CSVTable.devices.rawValue))
        }
        XCTAssertEqual(source.openCount, 0)
    }

    func testStreamingDecoderEnforcesRowLimitBeforeReadingTrailingRows() {
        let template = CSVSchemaV2.templates[.devices]!
        let first = template.columns.map { $0 == "name" ? "first" : "" }
        let second = template.columns.map { $0 == "name" ? "second" : "" }
        let trailing = template.columns.map { $0 == "name" ? "trailing" : "" }
        var source = CountingCSVSource(
            data: CSVExport.encode(rows: [template.columns, first, second, trailing]),
            chunkSize: 1)

        XCTAssertThrowsError(
            try CSVImportDecoder.records(
                from: &source, template: template, maximumRecords: 1)
        ) { error in
            XCTAssertEqual(
                error as? CSVImportError,
                .tooManyRows(table: CSVTable.devices.rawValue))
        }
        XCTAssertLessThan(source.bytesRead, source.data.count)
    }

    func testAggregateLimitStopsBeforeTrailingRowsAndPreservesImportError() throws {
        let source = AggregateLimitCSVSource()
        XCTAssertThrowsError(try CSVImportBatchDecoder.records(source: source)) { error in
            XCTAssertEqual(error as? CSVImportError, .tooManyRows(table: "import"))
        }
        XCTAssertEqual(source.readers[0].rowsRead, 100_000)
        XCTAssertEqual(source.readers[1].rowsRead, 100_000)
        XCTAssertEqual(source.readers[2].rowsRead, 50_001)
    }

    func testCompatibilityBatchKeepsCustomTemplatesInputOrderAndEmptyInput() throws {
        let templates = [CSVTable.vrfs, .devices].map { CSVTemplate(table: $0, columns: ["custom"]) }
        let files = templates.map { ($0, Data("custom\r\nx\r\n".utf8)) }
        let records = try CSVImportBatchDecoder.records(files: files)
        XCTAssertEqual(records.map(\.table), ["vrfs", "devices"])
        XCTAssertEqual(records.map(\.values), [["custom": "x"], ["custom": "x"]])
        XCTAssertTrue(try CSVImportBatchDecoder.records(files: []).isEmpty)
    }

    private func csv(table: CSVTable, name: String) -> Data {
        let template = CSVSchemaV1.templates[table]!
        let row = template.columns.map { $0 == "name" ? name : "" }
        return CSVExport.encode(rows: [template.columns, row])
    }
}

private struct CountingCSVSource: CSVByteChunkSource, @unchecked Sendable {
    let data: Data
    let chunkSize: Int
    var offset = 0
    var bytesRead: Int { offset }

    mutating func nextChunk() throws -> Data? {
        guard offset < data.count else { return nil }
        let end = min(data.count, offset + chunkSize)
        defer { offset = end }
        return data.subdata(in: offset..<end)
    }
}

private final class TrackingCSVSource: CSVImportSource, @unchecked Sendable {
    let metadata: [CSVImportFileMetadata]
    private(set) var openCount = 0

    init(metadata: [CSVImportFileMetadata]) { self.metadata = metadata }
    func fileMetadata() throws -> [CSVImportFileMetadata] { metadata }
    func openFile(_ file: CSVImportFileMetadata) throws -> AnyCSVByteChunkSource {
        openCount += 1
        return AnyCSVByteChunkSource(DataCSVByteChunkSource(data: Data()))
    }
}

private struct AggregateLimitCSVSource: CSVImportSource {
    let readers = [RowCountingCSVReader(rowCount: 100_000), RowCountingCSVReader(rowCount: 100_000), RowCountingCSVReader(rowCount: 50_002)]
    private let tables: [CSVTable] = [.devices, .locations, .vrfs]

    func fileMetadata() throws -> [CSVImportFileMetadata] {
        zip(tables, readers).map { table, reader in
            CSVImportFileMetadata(template: CSVTemplate(table: table, columns: ["value"]), declaredByteCount: reader.rowCount * 3 + 7)
        }
    }

    func openFile(_ file: CSVImportFileMetadata) throws -> AnyCSVByteChunkSource {
        guard let index = tables.firstIndex(of: file.table) else { throw CSVImportDocumentError.missingSchema(file.table.rawValue) }
        return AnyCSVByteChunkSource(readers[index])
    }
}

/// Serial test source emits one row per chunk so the consumption boundary is observable.
private final class RowCountingCSVReader: CSVByteChunkSource, @unchecked Sendable {
    let rowCount: Int
    private var sentHeader = false
    private(set) var rowsRead = 0

    init(rowCount: Int) { self.rowCount = rowCount }

    func nextChunk() throws -> Data? {
        guard sentHeader else {
            sentHeader = true
            return Data("value\r\n".utf8)
        }
        guard rowsRead < rowCount else { return nil }
        rowsRead += 1
        return Data("x\r\n".utf8)
    }
}
