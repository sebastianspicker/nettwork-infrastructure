import Foundation
import WorkspaceChangeControl

/// Byte producers let file-backed importers feed bounded chunks. The parser
/// does not decode strings until RFC 4180 framing is complete.
public protocol CSVByteChunkSource: Sendable { mutating func nextChunk() throws -> Data? }

public struct DataCSVByteChunkSource: CSVByteChunkSource {
    private let data: Data
    private let chunkSize: Int
    private var offset = 0

    public init(data: Data, chunkSize: Int = 16 * 1024) {
        self.data = data
        self.chunkSize = max(1, chunkSize)
    }

    public mutating func nextChunk() throws -> Data? {
        guard offset < data.count else { return nil }
        let end = min(data.count, offset + chunkSize)
        defer { offset = end }
        return data.subdata(in: offset..<end)
    }
}

/// A small value wrapper lets a reopenable document return file and in-memory
/// producers through one stable interface.
public struct AnyCSVByteChunkSource: CSVByteChunkSource, @unchecked Sendable {
    private final class Box<S: CSVByteChunkSource>: @unchecked Sendable {
        var source: S
        private let lock = NSLock()
        init(_ source: S) { self.source = source }
        func nextChunk() throws -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return try source.nextChunk()
        }
    }

    private let next: @Sendable () throws -> Data?

    public init<S: CSVByteChunkSource>(_ source: S) {
        let box = Box(source)
        next = { try box.nextChunk() }
    }

    public mutating func nextChunk() throws -> Data? { try next() }
}

public enum RFC4180Parser {
    /// Streams decoded rows to a throwing callback. CRLF is the only accepted
    /// line ending and a UTF-8 BOM is accepted only at byte zero.
    public static func forEachRow<S: CSVByteChunkSource>(
        source: inout S,
        maximumBytes: Int = CSVImportLimits.maximumFileBytes,
        _ body: ([String]) throws -> Void
    ) throws {
        var machine = Machine(maximumBytes: maximumBytes)
        while let chunk = try source.nextChunk() {
            try machine.consume(chunk, body)
        }
        try machine.finish(body)
    }

    /// Compatibility wrapper for callers that explicitly need a collected table.
    public static func parse<S: CSVByteChunkSource>(
        source: inout S,
        maximumBytes: Int = CSVImportLimits.maximumFileBytes
    ) throws -> [[String]] {
        var rows: [[String]] = []
        try forEachRow(source: &source, maximumBytes: maximumBytes) { rows.append($0) }
        return rows
    }

    private struct Machine {
        private enum State { case field, quoted, afterQuote }
        private let maximumBytes: Int
        private var preamble = Data()
        private var hasProcessedPreamble = false
        private var state: State = .field
        private var field = Data()
        private var row: [Data] = []
        private var pendingCR = false
        private var pendingQuotedCR = false
        private var inputBytes = 0
        private var rowBytes = 0

        init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

        mutating func consume(_ chunk: Data, _ body: ([String]) throws -> Void) throws {
            guard chunk.count <= maximumBytes - inputBytes else { throw CSVImportError.fileTooLarge }
            inputBytes += chunk.count
            for byte in chunk {
                if !hasProcessedPreamble {
                    preamble.append(byte)
                    if preamble.count == 3 {
                        hasProcessedPreamble = true
                        if preamble != Data([0xEF, 0xBB, 0xBF]) {
                            for pending in preamble { try consumeFramedByte(pending, body) }
                        }
                        preamble.removeAll(keepingCapacity: true)
                    }
                } else {
                    try consumeFramedByte(byte, body)
                }
            }
        }

        mutating func finish(_ body: ([String]) throws -> Void) throws {
            if !hasProcessedPreamble {
                hasProcessedPreamble = true
                for byte in preamble { try consumeFramedByte(byte, body) }
                preamble.removeAll(keepingCapacity: false)
            }
            guard !pendingCR, !pendingQuotedCR else { throw CSVImportError.bareCarriageReturn }
            guard state != .quoted else { throw CSVImportError.unterminatedQuotedField }
            if state == .afterQuote || !field.isEmpty || !row.isEmpty {
                try endField()
                try emitRow(body)
            }
        }

        private mutating func consumeFramedByte(_ byte: UInt8, _ body: ([String]) throws -> Void) throws {
            guard byte != 0 else { throw CSVImportError.nulByte }
            guard rowBytes < CSVImportLimits.maximumRowBytes else { throw CSVImportError.rowTooLarge }
            rowBytes += 1
            if try consumePendingQuotedCarriageReturn(byte) { return }
            if try consumePendingCarriageReturn(byte, body) { return }
            switch state {
            case .field: try consumeFieldByte(byte)
            case .quoted: try consumeQuotedByte(byte)
            case .afterQuote: try consumeAfterQuoteByte(byte)
            }
        }

        private mutating func consumePendingQuotedCarriageReturn(_ byte: UInt8) throws -> Bool {
            guard pendingQuotedCR else { return false }
            guard byte == 0x0A else { throw CSVImportError.bareCarriageReturn }
            pendingQuotedCR = false
            try appendToField(0x0D)
            try appendToField(0x0A)
            return true
        }

        private mutating func consumePendingCarriageReturn(
            _ byte: UInt8,
            _ body: ([String]) throws -> Void
        ) throws -> Bool {
            guard pendingCR else { return false }
            guard byte == 0x0A else { throw CSVImportError.bareCarriageReturn }
            pendingCR = false
            try endField()
            try emitRow(body)
            return true
        }

        private mutating func consumeFieldByte(_ byte: UInt8) throws {
            switch byte {
            case 0x22:
                guard field.isEmpty else { throw CSVImportError.invalidQuotePlacement }
                state = .quoted
            case 0x2C: try endField()
            case 0x0D: pendingCR = true
            case 0x0A: throw CSVImportError.bareLineFeed
            default: try appendToField(byte)
            }
        }

        private mutating func consumeQuotedByte(_ byte: UInt8) throws {
            if byte == 0x22 {
                state = .afterQuote
            } else if byte == 0x0D {
                pendingQuotedCR = true
            } else if byte == 0x0A {
                throw CSVImportError.bareLineFeed
            } else {
                try appendToField(byte)
            }
        }

        private mutating func consumeAfterQuoteByte(_ byte: UInt8) throws {
            switch byte {
            case 0x22:
                try appendToField(byte)
                state = .quoted
            case 0x2C:
                try endField()
                state = .field
            case 0x0D:
                pendingCR = true
                state = .field
            case 0x0A: throw CSVImportError.bareLineFeed
            default: throw CSVImportError.invalidQuotePlacement
            }
        }

        private mutating func appendToField(_ byte: UInt8) throws {
            guard field.count < CSVImportLimits.maximumCellBytes else { throw CSVImportError.cellTooLarge }
            field.append(byte)
        }

        private mutating func endField() throws {
            guard row.count < CSVImportLimits.maximumColumns else { throw CSVImportError.tooManyColumns }
            guard String(data: field, encoding: .utf8) != nil else { throw CSVImportError.malformedUTF8 }
            row.append(field)
            field.removeAll(keepingCapacity: true)
        }

        private mutating func emitRow(_ body: ([String]) throws -> Void) throws {
            let decoded = try row.map { bytes -> String in
                guard let value = String(data: bytes, encoding: .utf8) else { throw CSVImportError.malformedUTF8 }
                return value
            }
            try body(decoded)
            row.removeAll(keepingCapacity: true)
            rowBytes = 0
        }
    }
}

public enum CSVImportDecoder {
    public static func records<S: CSVByteChunkSource>(
        from source: inout S,
        template: CSVTemplate,
        maximumBytes: Int = CSVImportLimits.maximumFileBytes,
        maximumRecords: Int = CSVImportLimits.maximumRowsPerTable
    ) throws -> [ImportRecord] {
        guard maximumRecords >= 0 else { throw CSVImportError.tooManyRows(table: template.table.rawValue) }
        var header: [String]?
        var records: [ImportRecord] = []
        try RFC4180Parser.forEachRow(source: &source, maximumBytes: maximumBytes) { row in
            guard let columns = header else {
                try template.validates(header: row)
                header = row
                return
            }
            guard row.count == columns.count else {
                throw CSVImportError.rowColumnCount(expected: columns.count, actual: row.count)
            }
            guard records.count < maximumRecords else {
                throw CSVImportError.tooManyRows(table: template.table.rawValue)
            }
            records.append(
                ImportRecord(
                    table: template.table.rawValue,
                    values: Dictionary(uniqueKeysWithValues: zip(columns, row.map(CSVExport.decodedCell)))))
        }
        if header == nil { try template.validates(header: []) }
        return records
    }
}
