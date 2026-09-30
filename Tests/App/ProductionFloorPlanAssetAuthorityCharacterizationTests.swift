import CloudSync
import ContentSafety
import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import Nettwork

/// Pins the floor-plan asset authorities: only a sanitized JPEG floor-plan
/// descriptor for the configured floor and account is accepted, the live
/// session is revalidated before delegation, and the atomic binding rejects
/// an invalid request before it claims the private staging lease.
@MainActor
final class ProductionFloorPlanAssetAuthorityCharacterizationTests: XCTestCase {
    private let floorID = HierarchyFixture().floor.id

    func testValidRequestIsDelegatedToTheAtomicBinding() async throws {
        let session = try await SessionHarness.make(role: .technician)
        let binding = RecordingFloorPlanBinding()
        let authority = ProductionFloorPlanAssetAuthority(
            account: session.account, floorID: floorID, sessionAuthorizer: session.authorizer, atomicBinding: binding)
        let request = FloorPlanAssetBindingRequest(workOrderID: ObjectID(), floorID: floorID, descriptor: descriptor(for: session.account))

        let receipt = try await authority.bindOrReplace(request, authorization: session.operationContext(.createAttachment))

        let requests = await binding.requests
        XCTAssertEqual(requests, [request])
        XCTAssertEqual(receipt, try RecordingFloorPlanBinding.receipt(for: session.namespace))
    }

    func testDescriptorsForAnotherFloorPurposeOrAccountAreRejected() async throws {
        let session = try await SessionHarness.make()
        let binding = RecordingFloorPlanBinding()
        let authority = ProductionFloorPlanAssetAuthority(
            account: session.account, floorID: floorID, sessionAuthorizer: session.authorizer, atomicBinding: binding)
        let foreignAccount = ServiceFixture.account(ServiceFixture.namespace(owner: "other-owner"))
        let requests = [
            FloorPlanAssetBindingRequest(workOrderID: ObjectID(), floorID: ObjectID(), descriptor: descriptor(for: session.account)),
            FloorPlanAssetBindingRequest(workOrderID: ObjectID(), floorID: floorID, descriptor: descriptor(for: session.account, purpose: .evidence)),
            FloorPlanAssetBindingRequest(workOrderID: ObjectID(), floorID: floorID, descriptor: descriptor(for: foreignAccount)),
        ]

        for request in requests {
            await assertThrows(ProductionFloorPlanAssetAuthorityError.invalidDescriptor) {
                try await authority.bindOrReplace(request, authorization: session.operationContext(.createAttachment))
            }
        }
        let delegated = await binding.requests
        XCTAssertEqual(delegated, [])
    }

    func testAStaleAuthorizationIsRejectedBeforeDelegation() async throws {
        let session = try await SessionHarness.make()
        let binding = RecordingFloorPlanBinding()
        let authority = ProductionFloorPlanAssetAuthority(
            account: session.account, floorID: floorID, sessionAuthorizer: session.authorizer, atomicBinding: binding)
        let request = FloorPlanAssetBindingRequest(workOrderID: ObjectID(), floorID: floorID, descriptor: descriptor(for: session.account))
        let otherInstallation = ServiceFixture.actor(for: session.account, installationID: "installation-2")

        await assertThrows(ProductionFloorPlanAssetAuthorityError.staleAuthorization) {
            try await authority.bindOrReplace(request, authorization: session.operationContext(.createAttachment, actor: otherInstallation))
        }
        let delegated = await binding.requests
        XCTAssertEqual(delegated, [])
    }

    func testAtomicBindingRejectsAnInvalidRequestBeforeClaimingStaging() async throws {
        let session = try await SessionHarness.make()
        let staging = CountingStaging()
        let server = FakeCloudServer()
        let atomic = ProductionFloorPlanAssetAtomicBinding(staging: staging, sessionAuthorizer: session.authorizer, exactRecords: server, mutations: server)
        let invalid = [
            (
                FloorPlanAssetBindingRequest(workOrderID: ObjectID(), floorID: floorID, descriptor: descriptor(for: session.account, purpose: .evidence)),
                session.operationContext(.createAttachment)
            ),
            (
                FloorPlanAssetBindingRequest(workOrderID: ObjectID(), floorID: floorID, descriptor: descriptor(for: session.account)),
                session.operationContext(.readAttachment)
            ),
        ]

        for (request, authorization) in invalid {
            await assertThrows(ProductionFloorPlanAssetAuthorityError.invalidDescriptor) {
                try await atomic.bindOrReplaceFloorPlanAsset(request, account: session.account, authorization: authorization)
            }
        }
        let claims = await staging.claimCount
        let committed = await server.committed
        XCTAssertEqual(claims, 0)
        XCTAssertTrue(committed.isEmpty)
    }

    private func descriptor(for account: AccountContext, purpose: ContentPurpose = .floorPlan) -> SanitizedContentDescriptor {
        SanitizedContentDescriptor(
            id: TopologyFixture.id(900), stagingToken: AttachmentStagingToken(id: UUID()), stagingExpiresAt: .distantFuture,
            namespace: AttachmentNamespace(account: account), purpose: purpose, contentType: .jpeg, byteCount: 4, pixelWidth: 800, pixelHeight: 600,
            contentSHA256: String(repeating: "a", count: 64), domainSeparatedSHA256: String(repeating: "b", count: 64))
    }
}

actor RecordingFloorPlanBinding: FloorPlanAssetAtomicBinding {
    private(set) var requests: [FloorPlanAssetBindingRequest] = []

    static func receipt(for namespace: PersistenceNamespace) throws -> OperationReceipt {
        OperationReceipt(
            workspaceZone: namespace.workspaceZone, operationID: TopologyFixture.id(901),
            intentDigest: try IntentDigest(algorithm: .sha256, bytes: Array(repeating: 7, count: 32)), auditEventID: TopologyFixture.id(902))
    }

    func bindOrReplaceFloorPlanAsset(
        _ request: FloorPlanAssetBindingRequest, account: AccountContext, authorization _: AuthorizedOperationContext
    ) async throws -> OperationReceipt {
        requests.append(request)
        return try Self.receipt(for: account.namespace)
    }
}

/// Staging that must never be reached by the rejected requests.
actor CountingStaging: PrivateAttachmentStaging {
    private(set) var claimCount = 0

    func stage(_: Data, metadata _: SanitizedAttachmentStagingMetadata, namespace _: AttachmentNamespace) async throws -> StagedAttachmentLease {
        throw ServiceTestError(reason: "not used")
    }
    func claim(_: AttachmentStagingToken, namespace _: AttachmentNamespace) async throws -> ClaimedStagedAttachment {
        claimCount += 1
        throw ServiceTestError(reason: "not used")
    }
    func complete(_: ClaimedStagedAttachment) async throws {}
    func release(_: ClaimedStagedAttachment) async {}
    func remove(_: AttachmentStagingToken, namespace _: AttachmentNamespace) async throws {}
}
