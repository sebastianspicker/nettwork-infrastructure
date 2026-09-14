import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import ImportExport

extension ImportExportSecurityTests {
    func testArchivePathPolicyRejectsTraversalAbsoluteCollisionAndLinks() throws {
        XCTAssertThrowsError(try ArchivePathPolicy.normalized("../manifest.json"))
        XCTAssertThrowsError(try ArchivePathPolicy.normalized("/manifest.json"))
        XCTAssertThrowsError(try ArchivePathPolicy.normalized("assets\\photo"))
        XCTAssertThrowsError(try ArchivePathPolicy.normalized(String(repeating: "a", count: ArchiveSafetyLimits.maximumPathUTF8Bytes + 1)))
        XCTAssertThrowsError(
            try ArchivePathPolicy.normalized(Array(repeating: "asset", count: ArchiveSafetyLimits.maximumPathComponents + 1).joined(separator: "/")))
        XCTAssertFalse(ArchivePathPolicy.isAllowed("assets/photo", kind: .symbolicLink))
        XCTAssertEqual(ArchivePathPolicy.collisionKey("assets/A\u{0308}.png"), ArchivePathPolicy.collisionKey("assets/ä.png"))
    }

    func testArchiveManifestRecordCountsRejectUnknownAndOverflowingValues() {
        XCTAssertThrowsError(try ArchiveManifestRecordCounts.total(["unknown": 1]))
        XCTAssertThrowsError(
            try ArchiveManifestRecordCounts.total([
                WorkspaceTransferRecordType.device.rawValue: Int.max,
                WorkspaceTransferRecordType.port.rawValue: 1,
            ]))
    }

    func testArchiveVerifierAcceptsStreamedMarkerAndRejectsTampering() async throws {
        let account = fixtureAccount()
        let context = fixtureContext(account: account, action: .exportArchive)
        let export = AuthorizedArchiveExportService(source: FixtureArchiveExportSource(account: account), currentContext: FixtureCurrentContext(context))
        let document = try await export.makeDocument(context: context, createdAt: .distantPast)
        XCTAssertEqual(document.manifest.assets.count, 1)
        XCTAssertEqual(document.manifest.assets.first?.id, FixtureArchiveExportSource.workspaceAssetID)
        XCTAssertEqual(document.manifest.assets.first?.stableID, ArchiveAsset.stableID(for: "assets/photo.bin"))
        XCTAssertEqual(document.manifest.assets.first?.relativePath, "assets/photo.bin")
        XCTAssertEqual(document.manifest.assets.first?.contentType, "application/octet-stream")
        let valid = FixtureArchiveSource(entries: document.entries)
        XCTAssertEqual(try ArchiveVerifier().verify(source: valid).rootSHA256, document.manifest.rootSHA256)
        var corruptEntries = document.entries
        corruptEntries[ArchiveLayout.recordsPath] = Data("tampered\n".utf8)
        XCTAssertThrowsError(try ArchiveVerifier().verify(source: FixtureArchiveSource(entries: corruptEntries)))
    }

    /// Provenance is committed through the completion marker, which remains
    /// outside its own digest material.
    func testArchiveVerifierRejectsProvenanceOnlyManifestTamper() async throws {
        let account = fixtureAccount()
        let context = fixtureContext(account: account, action: .exportArchive)
        let document = try await AuthorizedArchiveExportService(
            source: FixtureArchiveExportSource(account: account),
            currentContext: FixtureCurrentContext(context)
        ).makeDocument(context: context, createdAt: .distantPast)
        let altered = ArchiveManifest(
            schemaVersion: document.manifest.schemaVersion,
            workspaceID: document.manifest.workspaceID,
            createdAt: document.manifest.createdAt,
            recordCounts: document.manifest.recordCounts,
            assets: document.manifest.assets,
            auditRecordCount: document.manifest.auditRecordCount,
            provenance: ArchiveSourceProvenance(
                workspaceID: document.manifest.provenance.workspaceID,
                containerIdentifier: "iCloud.forged",
                zoneName: document.manifest.provenance.zoneName,
                zoneOwnerRecordName: document.manifest.provenance.zoneOwnerRecordName
            ),
            compatibility: document.manifest.compatibility,
            recordsSHA256: document.manifest.recordsSHA256,
            auditSHA256: document.manifest.auditSHA256,
            auditHeadSHA256: document.manifest.auditHeadSHA256,
            rootSHA256: document.manifest.rootSHA256
        )
        var tampered = document.entries
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        tampered[ArchiveLayout.manifestPath] = try encoder.encode(altered)
        XCTAssertThrowsError(try ArchiveVerifier().verify(source: FixtureArchiveSource(entries: tampered)))
    }

    /// Restore receipts bind the verified archive root and manifest.
    func testArchiveRestoreRejectsScopeMatchingReceiptWithWrongIntentOrAuditEvent() async throws {
        for mismatch in ReceiptMismatchKind.allCases {
            let sourceAccount = fixtureAccount()
            let exportContext = fixtureContext(account: sourceAccount, action: .exportArchive)
            let document = try await AuthorizedArchiveExportService(
                source: FixtureArchiveExportSource(account: sourceAccount),
                currentContext: FixtureCurrentContext(exportContext)
            ).makeDocument(context: exportContext, createdAt: .distantPast)
            let targetAccount = fixtureAccount()
            let restoreContext = fixtureContext(account: targetAccount, action: .restoreArchive)
            let store = RecordingArchiveRestoreStore(account: targetAccount, receiptMismatch: mismatch)
            let service = AuthorizedArchiveRestoreService(store: store, currentContext: FixtureCurrentContext(restoreContext))
            let preview = try ArchiveVerifier().verifyForRestore(
                source: FixtureArchiveSource(entries: document.entries),
                authorization: restoreContext
            )
            let expected = try ArchiveRestoreActivationReceipt.expected(
                for: preview.archive,
                target: targetAccount.namespace,
                operationID: restoreContext.operationID
            )

            do {
                _ = try await service.restore(
                    source: FixtureArchiveSource(entries: document.entries),
                    approval: preview.approval,
                    context: restoreContext
                )
                XCTFail("expected receipt mismatch")
            } catch {
                XCTAssertEqual(error as? ImportPlanError, .activationReceiptMismatch)
            }
            assertScopeMatchingReceiptMismatch(store.returnedReceipt, expected: expected, kind: mismatch)
            XCTAssertEqual(store.discardCount, 0)
        }
    }

    func testArchiveRestoreApprovalRejectsPostReviewSubstitutionBeforeStaging() async throws {
        let sourceAccount = fixtureAccount()
        let exportContext = fixtureContext(account: sourceAccount, action: .exportArchive)
        let reviewedDocument = try await AuthorizedArchiveExportService(
            source: FixtureArchiveExportSource(account: sourceAccount),
            currentContext: FixtureCurrentContext(exportContext)
        ).makeDocument(context: exportContext, createdAt: .distantPast)
        let replacementAccount = fixtureAccount()
        let replacementContext = fixtureContext(account: replacementAccount, action: .exportArchive)
        let replacementDocument = try await AuthorizedArchiveExportService(
            source: FixtureArchiveExportSource(account: replacementAccount),
            currentContext: FixtureCurrentContext(replacementContext)
        ).makeDocument(context: replacementContext, createdAt: .distantPast)
        let targetAccount = fixtureAccount()
        let restoreContext = fixtureContext(account: targetAccount, action: .restoreArchive)
        let source = MutableFixtureArchiveSource(entries: reviewedDocument.entries)
        let preview = try ArchiveVerifier().verifyForRestore(source: source, authorization: restoreContext)
        let store = RecordingArchiveRestoreStore(account: targetAccount, receiptMismatch: nil)
        let service = AuthorizedArchiveRestoreService(store: store, currentContext: FixtureCurrentContext(restoreContext))

        source.replace(entries: replacementDocument.entries)

        do {
            _ = try await service.restore(source: source, approval: preview.approval, context: restoreContext)
            XCTFail("expected approval mismatch")
        } catch {
            XCTAssertEqual(error as? ArchiveValidationError, .approvalMismatch)
        }
        XCTAssertEqual(store.stagingCount, 0)
    }

    /// The file-backed adapter independently validates intent and audit identity.
    func testFileBackedArchiveRestoreRejectsScopeMatchingReceiptWithWrongIntentOrAuditEvent() async throws {
        for mismatch in ReceiptMismatchKind.allCases {
            let sourceAccount = fixtureAccount()
            let exportContext = fixtureContext(account: sourceAccount, action: .exportArchive)
            let document = try await AuthorizedArchiveExportService(
                source: FixtureArchiveExportSource(account: sourceAccount),
                currentContext: FixtureCurrentContext(exportContext)
            ).makeDocument(context: exportContext, createdAt: .distantPast)
            let archive = try ArchiveVerifier().verify(source: FixtureArchiveSource(entries: document.entries))
            let targetAccount = fixtureAccount()
            let operationID = ObjectID()
            let expected = try ArchiveRestoreActivationReceipt.expected(
                for: archive,
                target: targetAccount.namespace,
                operationID: operationID
            )
            let authority = RecordingArchiveRestoreActivationAuthority(account: targetAccount, receiptMismatch: mismatch)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = FileBackedArchiveRestoreStore(root: root, authority: authority)
            let staging = try await store.createRestoreStaging(
                source: archive.manifest.provenance,
                target: targetAccount.namespace,
                operationID: operationID
            )
            try await store.stage(archive, in: staging)

            do {
                _ = try await store.activateRestore(
                    staging,
                    expectedFreshTarget: targetAccount.namespace,
                    operationID: operationID,
                    expectedReceipt: expected
                )
                XCTFail("expected receipt mismatch")
            } catch {
                XCTAssertEqual(error as? FileBackedStagingError, .activationReceiptMismatch)
            }
            assertScopeMatchingReceiptMismatch(authority.returnedReceipt, expected: expected, kind: mismatch)
        }
    }

    func testArchiveAuditChainRejectsReorderingAndEventTampering() throws {
        let chain = try ArchiveAuditChain.encode(events: [Data("first".utf8), Data("second".utf8)])
        XCTAssertEqual(try ArchiveAuditChain.verify(chain.jsonl).headSHA256, chain.headSHA256)

        let lines = chain.jsonl.split(separator: 0x0A, omittingEmptySubsequences: true)
        var reordered = Data()
        for line in lines.reversed() {
            reordered.append(contentsOf: line)
            reordered.append(0x0A)
        }
        XCTAssertThrowsError(try ArchiveAuditChain.verify(reordered))

        var tampered = chain.jsonl
        tampered[tampered.startIndex] ^= 0x01
        XCTAssertThrowsError(try ArchiveAuditChain.verify(tampered))
    }

    func testVerifierRejectsUnknownPathAndExpansionMetadataBeforeReading() {
        let source = FixtureArchiveSource(
            metadata: [
                ArchiveEntryMetadata(path: "manifest.json", kind: .regularFile, uncompressedSize: 1, compressedSize: 1),
                ArchiveEntryMetadata(path: "evil", kind: .regularFile, uncompressedSize: 1, compressedSize: 1),
            ], bodies: [:])
        XCTAssertThrowsError(try ArchiveVerifier().verify(source: source))
        let bomb = FixtureArchiveSource(
            metadata: [ArchiveEntryMetadata(path: "manifest.json", kind: .regularFile, uncompressedSize: 101, compressedSize: 1)], bodies: [:])
        XCTAssertThrowsError(try ArchiveVerifier().verify(source: bomb))
    }
}
