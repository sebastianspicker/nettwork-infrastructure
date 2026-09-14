import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import ImportExport

extension ImportExportSecurityTests {
    func testParserAcceptsBOMQuotedCRLFAndChunkBoundaries() throws {
        var source = DataCSVByteChunkSource(data: Data("\u{FEFF}name,note\r\nrouter,\"a, \"\"quoted\"\" note\"\r\n".utf8), chunkSize: 1)
        XCTAssertEqual(try RFC4180Parser.parse(source: &source), [["name", "note"], ["router", "a, \"quoted\" note"]])
    }

    func testParserRejectsNULBareCRBareLFAndInvalidUTF8() {
        XCTAssertThrowsError(try parse("name\0\r\n"))
        XCTAssertThrowsError(try parse("name\rvalue"))
        XCTAssertThrowsError(try parse("name\nvalue"))
        XCTAssertThrowsError(try parse("\"quoted\rvalue\""))
        var invalid = DataCSVByteChunkSource(data: Data([0x6E, 0x61, 0x6D, 0x65, 0x0D, 0x0A, 0xC3, 0x28]))
        XCTAssertThrowsError(try RFC4180Parser.parse(source: &invalid))
    }

    func testDecoderRequiresExactVersionedHeaderAndBoundsRows() throws {
        let template = CSVTemplate(table: .devices, columns: ["name", "model"])
        var good = DataCSVByteChunkSource(data: Data("name,model\r\nedge,XR\r\n".utf8))
        XCTAssertEqual(try CSVImportDecoder.records(from: &good, template: template).first?.values["model"], "XR")
        var reordered = DataCSVByteChunkSource(data: Data("model,name\r\nXR,edge\r\n".utf8))
        XCTAssertThrowsError(try CSVImportDecoder.records(from: &reordered, template: template))
        XCTAssertNoThrow(try CSVTemplate(table: .devices, version: 2, columns: ["name"]).validates(header: ["name"]))
        XCTAssertThrowsError(try CSVTemplate(table: .devices, version: 3, columns: ["name"]).validates(header: ["name"]))
        XCTAssertEqual(CSVSchemaV1.templates.count, CSVTable.allCases.count)
        XCTAssertEqual(CSVSchemaV2.templates.count, CSVTable.allCases.count)
    }

    func testExporterUsesRFC4180CRLFAndNeutralizesAfterControls() {
        let output = String(decoding: CSVExport.encode(rows: [["\u{0001}=SUM(A1:A2)", "a,\"b\""]]), as: UTF8.self)
        XCTAssertEqual(output, "'\u{0001}=SUM(A1:A2),\"a,\"\"b\"\"\"\r\n")
        XCTAssertEqual(CSVExport.escapedCell(" text"), " text")
        XCTAssertEqual(CSVExport.decodedCell(CSVExport.escapedCell("=SUM(A1:A2)")), "=SUM(A1:A2)")
        XCTAssertEqual(CSVExport.decodedCell(CSVExport.escapedCell("'literal")), "'literal")
    }

    func testCanonicalDigestDoesNotDependOnRecordIDsOrDictionaryOrder() {
        let first = ImportRecord(table: "devices", values: ["name": "edge", "model": "XR"])
        let second = ImportRecord(table: "devices", values: ["model": "XR", "name": "edge"])
        XCTAssertEqual(CanonicalImportDigest.digest(records: [first]), CanonicalImportDigest.digest(records: [second]))
    }

    func testImportPlanRequiresCountsAndStagesBeforeSingleActivation() async throws {
        let account = fixtureAccount()
        let store = RecordingImportStore(account: account)
        let context = fixtureContext(account: account, action: .importCSV)
        let service = AuthorizedCSVImportService(store: store, currentContext: FixtureCurrentContext(context))
        let records = [deviceRecord(name: "edge")]
        let plan = try await service.makePlan(records: records, context: context, stagingGeneration: 7)
        let receipt = try await service.execute(plan: plan, records: records, context: context)
        XCTAssertEqual(store.stagedCount, 1)
        XCTAssertEqual(store.activationCount, 1)
        XCTAssertEqual(store.discardCount, 0)
        XCTAssertEqual(receipt.operationID, context.operationID)
        XCTAssertEqual(receipt.workspaceZone, account.namespace.workspaceZone)
        XCTAssertTrue(plan.expectedEmptyWorkspace)
        XCTAssertEqual(plan.stagingGeneration, 7)
    }

    /// A final CAS conflict leaves staging invisible but retryable.
    func testImportActivationConflictRetainsRetryableInvisibleStaging() async throws {
        let account = fixtureAccount()
        let store = RecordingImportStore(account: account, activationResult: false)
        let context = fixtureContext(account: account, action: .importCSV)
        let service = AuthorizedCSVImportService(store: store, currentContext: FixtureCurrentContext(context))
        let records = [deviceRecord(name: "edge")]
        let plan = try await service.makePlan(records: records, context: context, stagingGeneration: 1)
        do {
            _ = try await service.execute(plan: plan, records: records, context: context)
            XCTFail("expected CAS conflict")
        } catch { XCTAssertEqual(store.discardCount, 0) }
        XCTAssertEqual(store.activationCount, 1)
    }

    /// Matching operation and workspace identities do not authorize a
    /// different intent or audit event.
    func testCSVServiceRejectsScopeMatchingReceiptWithWrongIntentOrAuditEvent() async throws {
        for mismatch in ReceiptMismatchKind.allCases {
            let account = fixtureAccount()
            let context = fixtureContext(account: account, action: .importCSV)
            let store = RecordingImportStore(account: account, receiptMismatch: mismatch)
            let service = AuthorizedCSVImportService(store: store, currentContext: FixtureCurrentContext(context))
            let records = [deviceRecord(name: "edge")]
            let plan = try await service.makePlan(records: records, context: context, stagingGeneration: 11)
            let expected = try CSVImportActivationReceipt.expected(for: plan)

            do {
                _ = try await service.execute(plan: plan, records: records, context: context)
                XCTFail("expected receipt mismatch")
            } catch {
                XCTAssertEqual(error as? ImportPlanError, .activationReceiptMismatch)
            }
            assertScopeMatchingReceiptMismatch(store.returnedReceipt, expected: expected, kind: mismatch)
            XCTAssertEqual(store.discardCount, 0)
        }
    }

    /// A post-verification mutation is rejected before activation.
    func testFileBackedCSVActivationRejectsPostStageMutationWithoutPartialActivation() async throws {
        let account = fixtureAccount()
        let authority = RecordingCSVActivationAuthority(account: account)
        let root = temporaryStagingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try fileBackedRequest(account: account, stagingGeneration: 9)
        let records = request.records
        let plan = request.plan
        let store = FileBackedCSVImportStagingStore(root: root, authority: authority)
        let staging = try await store.createStaging(for: plan)
        try await store.stage(records, in: staging)
        let payloadURL = root.appendingPathComponent(staging.id.description, isDirectory: true).appendingPathComponent("records.json")
        var tampered = try Data(contentsOf: payloadURL)
        tampered[tampered.startIndex] ^= 0x01
        try tampered.write(to: payloadURL, options: .atomic)

        do {
            _ = try await store.activate(
                staging,
                plan: plan,
                requiringEmptyWorkspace: true,
                expectedReceipt: try CSVImportActivationReceipt.expected(for: plan)
            )
            XCTFail("expected staged payload mismatch")
        } catch {}
        XCTAssertEqual(authority.activationCount, 0)
    }

    /// The file-backed adapter validates the authority receipt independently.
    func testFileBackedCSVRejectsScopeMatchingReceiptWithWrongIntentOrAuditEvent() async throws {
        for mismatch in ReceiptMismatchKind.allCases {
            let account = fixtureAccount()
            let authority = RecordingCSVActivationAuthority(account: account, receiptMismatch: mismatch)
            let root = temporaryStagingRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let request = try fileBackedRequest(account: account, stagingGeneration: 12)
            let records = request.records
            let plan = request.plan
            let expected = try CSVImportActivationReceipt.expected(for: plan)
            let store = FileBackedCSVImportStagingStore(root: root, authority: authority)
            let staging = try await store.createStaging(for: plan)
            try await store.stage(records, in: staging)

            do {
                _ = try await store.activate(staging, plan: plan, requiringEmptyWorkspace: true, expectedReceipt: expected)
                XCTFail("expected receipt mismatch")
            } catch {
                XCTAssertEqual(error as? FileBackedStagingError, .activationReceiptMismatch)
            }
            assertScopeMatchingReceiptMismatch(authority.returnedReceipt, expected: expected, kind: mismatch)
        }
    }

    private func parse(_ value: String) throws -> [[String]] {
        var source = DataCSVByteChunkSource(data: Data(value.utf8))
        return try RFC4180Parser.parse(source: &source)
    }

    private func temporaryStagingRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func fileBackedRequest(account: AccountContext, stagingGeneration: Int) throws -> FileBackedRequest {
        let records = [deviceRecord(name: "edge")]
        let context = fixtureContext(account: account, action: .importCSV)
        let digest = CanonicalImportDigest.digest(records: records)
        let plan = try ImportPlan(
            namespace: account.namespace, canonicalSHA256: digest, recordCounts: [CSVTable.devices.rawValue: 1], totalRecordCount: 1,
            stagingGeneration: UInt64(stagingGeneration), operationID: context.operationID,
            dryRunReport: ImportDryRunReport(canonicalSHA256: digest, validatorVersion: 1, validatedRecordCount: 1))
        return FileBackedRequest(records: records, context: context, plan: plan)
    }
}

private struct FileBackedRequest {
    let records: [ImportRecord]
    let context: AuthorizedOperationContext
    let plan: ImportPlan
}
