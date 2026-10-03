import CloudSync
import Foundation
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl
import XCTest

@testable import WorkspaceServices

/// Pins the successful activation path of ARCHITECTURE.md "Attachments and
/// transfer": after a dry run, every canonical record is uploaded as an
/// invisible staged member in bounded batches, and one final conditional
/// mutation of the workspace sentinel activates the empty, fresh target. A
/// mirroring client independently re-derives the rolling digest from the
/// delivered members and must observe the same active workspace.
final class ProductionWorkspaceTransferAuthorityCommitCharacterizationTests: XCTestCase {
    func testCSVImportStagesBoundedBatchesAndActivatesTheEmptyTargetOnce() async throws {
        let harness = try await StagedTransferHarness.make()
        let fixture = StagedTransferHarness.siteImports(siteCount: 250)
        let report = try await harness.authority.dryRun(fixture.records, in: harness.namespace)
        let plan = try ImportPlan(
            namespace: harness.namespace, canonicalSHA256: report.canonicalSHA256, recordCounts: [CSVTable.locations.rawValue: fixture.records.count],
            totalRecordCount: fixture.records.count, stagingGeneration: 1, operationID: ObjectID(), dryRunReport: report)
        let expected = try CSVImportActivationReceipt.expected(for: plan)

        let receipt = try await harness.authority.activateStagedCSV(
            records: fixture.records, plan: plan, requiringEmptyWorkspace: true, expectedReceipt: expected)

        XCTAssertEqual(receipt, expected)
        XCTAssertEqual(report.validatedRecordCount, 251, "Each location row is one canonical record.")
        // Session creation, two appends bounded by the batch limit, completion.
        let batchSizes = await harness.transport.memberBatches.map(\.count)
        XCTAssertEqual(batchSizes, [0, CloudStagedTransferLimits.maximumMembersPerBatch, 51, 0])
        let commit = try await assertActivatedOnce(
            harness, memberKeys: Set(([fixture.rootID] + fixture.siteIDs).map(ResourceKey.object)), memberCount: report.validatedRecordCount)
        XCTAssertEqual(commit.transferID, plan.transferID)
    }

    func testArchiveRestoreStagesItsRecordsAndActivatesTheEmptyTargetOnce() async throws {
        let harness = try await StagedTransferHarness.make()
        let fixture = StagedTransferHarness.siteImports(siteCount: 2)
        let archive = try TransferHarness.archive(sourceWorkspaceID: ObjectID(), imports: fixture.records)
        let operationID = ObjectID()
        let expected = try ProductionArchiveRestoreInput.memory(archive).expectedReceipt(target: harness.namespace, operationID: operationID)

        try await harness.authority.dryRun(archive, for: harness.namespace)
        let receipt = try await harness.authority.activateStagedArchive(
            archive: archive, source: archive.manifest.provenance, target: harness.namespace, expectedRootSHA256: archive.rootSHA256,
            operationID: operationID, expectedReceipt: expected)

        XCTAssertEqual(receipt, expected)
        XCTAssertEqual(archive.manifest.recordCounts.values.reduce(0, +), fixture.records.count)
        let batchSizes = await harness.transport.memberBatches.map(\.count)
        XCTAssertEqual(batchSizes, [0, fixture.records.count, 0])
        try await assertActivatedOnce(
            harness, memberKeys: Set(([fixture.rootID] + fixture.siteIDs).map(ResourceKey.object)),
            memberCount: archive.manifest.recordCounts.values.reduce(0, +))
    }

    func testCSVActivationRejectsAnAdministratorDowngradedBeforeAuthorityEntry() async throws {
        let harness = try await StagedTransferHarness.make()
        let fixture = StagedTransferHarness.siteImports(siteCount: 1)
        let report = try await harness.authority.dryRun(fixture.records, in: harness.namespace)
        let plan = try ImportPlan(
            namespace: harness.namespace,
            canonicalSHA256: report.canonicalSHA256,
            recordCounts: [CSVTable.locations.rawValue: fixture.records.count],
            totalRecordCount: fixture.records.count,
            stagingGeneration: 1,
            operationID: ObjectID(),
            dryRunReport: report
        )
        let technician = ServiceFixture.actor(for: harness.session.account, role: .technician)
        await harness.session.actors.setActor(technician)

        await assertThrows(OfficialClientPolicyError.technicianCannotAdminister) {
            try await harness.authority.activateStagedCSV(
                records: fixture.records,
                plan: plan,
                requiringEmptyWorkspace: true,
                expectedReceipt: try CSVImportActivationReceipt.expected(for: plan)
            )
        }
        let accepted = await harness.transport.accepted
        let activations = await harness.server.activations
        XCTAssertTrue(accepted.isEmpty)
        XCTAssertTrue(activations.isEmpty)
    }

    // MARK: Helpers

    /// Asserts that exactly the expected members were staged invisibly, that
    /// one conditional mutation of the empty sentinel activated the target,
    /// and that the observed mirror derives the same active lifecycle.
    @discardableResult
    private func assertActivatedOnce(
        _ harness: StagedTransferHarness, memberKeys: Set<ResourceKey>, memberCount: Int, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> WorkspaceActivationCommit {
        let members = await harness.transport.memberBatches.flatMap { $0 }
        let commit = try await harness.activatedCommit(file: file, line: line)
        XCTAssertEqual(members.count, memberCount, file: file, line: line)
        XCTAssertEqual(Set(members.map(\.resourceKey)), memberKeys, file: file, line: line)
        XCTAssertTrue(members.allSatisfy { $0.visibility == .staged(transferID: commit.transferID) && !$0.isDeleted }, file: file, line: line)

        let sentinelKey = ServiceFixture.sentinelKey(harness.namespace)
        let activations = await harness.server.activations
        let committed = await harness.server.committed
        XCTAssertEqual(activations.count, 1, "Activation must be one final mutation.", file: file, line: line)
        XCTAssertTrue(committed.isEmpty, "Transfer activation is not a work-order mutation.", file: file, line: line)
        let activation = try XCTUnwrap(activations.first, file: file, line: line)
        XCTAssertEqual(activation.saves.map(\.resourceKey), [sentinelKey], file: file, line: line)
        XCTAssertTrue(activation.tombstones.isEmpty, file: file, line: line)
        XCTAssertTrue(
            activation.preconditions.contains(.exactSystemFields(sentinelKey, ServiceFixture.exact(StagedTransferHarness.emptyTag))),
            "Activation must be conditional on the empty sentinel that was checked.", file: file, line: line)

        XCTAssertEqual(commit.memberCount, memberCount, file: file, line: line)
        let sessionKey = try CloudStagedTransferSession(
            transferID: commit.transferID, operationID: activation.operationID, epoch: StagedTransferHarness.emptyEpoch, expectedMemberCount: 0,
            expectedRollingDigest: "unused"
        ).resourceKey
        let session = try CloudDeterministicCoding.decode(
            CloudStagedTransferSession.self, from: try await harness.server.requiredSnapshot(for: sessionKey).payload)
        XCTAssertEqual(session.status, .complete, file: file, line: line)
        XCTAssertEqual(session.epoch, StagedTransferHarness.emptyEpoch, file: file, line: line)
        XCTAssertEqual(session.cursor, memberCount, file: file, line: line)
        XCTAssertEqual(session.rollingDigest, commit.rollingDigest, file: file, line: line)
        let observed = try CloudStagedTransferLifecycle.derive(records: try await harness.observedMirror(sessionKey: sessionKey), namespace: harness.namespace)
        XCTAssertEqual(observed.lifecycle, .active(commit: commit), "The delivered members must reproduce the committed digest.", file: file, line: line)
        let isEmpty = try await harness.authority.workspaceIsEmpty(in: harness.namespace)
        XCTAssertFalse(isEmpty, file: file, line: line)
        return commit
    }
}
