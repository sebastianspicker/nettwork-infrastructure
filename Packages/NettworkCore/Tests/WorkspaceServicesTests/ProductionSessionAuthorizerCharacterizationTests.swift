import CloudSync
import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import WorkspaceServices

/// Pins ARCHITECTURE.md "Controlled mutations": authority is derived from the
/// verified Cloud session, actor, installation session and lease; presentation
/// values are only checked for an exact match and never grant authority.
final class ProductionSessionAuthorizerCharacterizationTests: XCTestCase {
    func testAuthorizeMutationDerivesIdentityFromTheLiveSession() async throws {
        let harness = try await SessionHarness.make()

        let trusted = try await harness.authorizer.authorizeMutation(namespace: harness.namespace, presentation: harness.presentation)

        XCTAssertEqual(trusted.account, harness.account)
        XCTAssertEqual(trusted.actor, harness.actor)
        XCTAssertEqual(trusted.actorSnapshot.actorID, harness.actor.cloudKitUserRecordName)
        XCTAssertEqual(trusted.actorSnapshot.installationID, harness.actor.installationID)
        XCTAssertEqual(trusted.actorSnapshot.sessionID, "session-1")
        XCTAssertEqual(trusted.actorSnapshot.sessionGeneration, harness.namespace.sessionGeneration)
        let isCurrent = await harness.lifecycle.isCurrent(trusted.lease)
        XCTAssertTrue(isCurrent)
    }

    func testPresentationValuesThatDoNotExactlyMatchAreRejected() async throws {
        let harness = try await SessionHarness.make()
        let actor = harness.actor
        let mismatches = [
            OperationsAuthorization(actorID: "someone-else", role: actor.role, sessionGeneration: actor.sessionGeneration, isFresh: true),
            OperationsAuthorization(actorID: actor.cloudKitUserRecordName, role: .technician, sessionGeneration: actor.sessionGeneration, isFresh: true),
            OperationsAuthorization(actorID: actor.cloudKitUserRecordName, role: actor.role, sessionGeneration: actor.sessionGeneration + 1, isFresh: true),
            OperationsAuthorization(actorID: actor.cloudKitUserRecordName, role: actor.role, sessionGeneration: actor.sessionGeneration, isFresh: false),
        ]

        for presentation in mismatches {
            await assertThrows(ProductionSessionAuthorizationError.presentationMismatch) {
                try await harness.authorizer.authorizeMutation(namespace: harness.namespace, presentation: presentation)
            }
        }
    }

    func testAnotherWorkspaceNamespaceHasNoVerifiedSession() async throws {
        let harness = try await SessionHarness.make()
        let other = ServiceFixture.namespace()

        await assertThrows(ProductionSessionAuthorizationError.noVerifiedSession) {
            try await harness.authorizer.verifiedSession(namespace: other)
        }
    }

    func testChangedCloudKitAccountInvalidatesTheSession() async throws {
        let harness = try await SessionHarness.make()
        await harness.workspaceAuthority.setIdentity(CloudAccountIdentity(cloudKitUserRecordName: "different-account", isAvailable: true))

        await assertThrows(ProductionSessionAuthorizationError.noVerifiedSession) {
            try await harness.authorizer.verifiedSession(namespace: harness.namespace)
        }
        let active = await harness.lifecycle.activeContext()
        XCTAssertNil(active, "An account change must revoke the old session rather than keep it usable.")
    }

    func testRevokedMembershipHasNoVerifiedSession() async throws {
        let harness = try await SessionHarness.make()
        await harness.workspaceAuthority.setMembership(nil)

        await assertThrows(ProductionSessionAuthorizationError.noVerifiedSession) {
            try await harness.authorizer.verifiedSession(namespace: harness.namespace)
        }
    }

    func testActorFromAnotherSessionGenerationIsRejected() async throws {
        let harness = try await SessionHarness.make()
        let stale = ActorContext(
            cloudKitUserRecordName: harness.actor.cloudKitUserRecordName, role: .administrator, installationID: harness.actor.installationID,
            sessionGeneration: harness.namespace.sessionGeneration + 1)
        await harness.actors.setActor(stale)

        await assertThrows(OfficialClientPolicyError.staleActorSession) {
            try await harness.authorizer.authorizeMutation(namespace: harness.namespace, presentation: ServiceFixture.presentation(for: stale))
        }
    }

    func testBlankInstallationSessionIsRejected() async throws {
        let harness = try await SessionHarness.make()
        await harness.installation.setIdentifier("  \n")

        await assertThrows(ProductionSessionAuthorizationError.invalidSessionID) {
            try await harness.authorizer.verifiedSession(namespace: harness.namespace)
        }
    }

    func testRoleRulesFollowOfficialClientPolicy() async throws {
        let viewer = try await SessionHarness.make(role: .viewer)
        await assertThrows(OfficialClientPolicyError.viewerCannotMutate) {
            try await viewer.authorizer.authorizeMutation(namespace: viewer.namespace, presentation: viewer.presentation)
        }

        let technician = try await SessionHarness.make(role: .technician)
        _ = try await technician.authorizer.authorizeMutation(namespace: technician.namespace, presentation: technician.presentation)
        await assertThrows(OfficialClientPolicyError.technicianCannotAdminister) {
            try await technician.authorizer.authorizeMutation(
                namespace: technician.namespace, presentation: technician.presentation, requiresAdministrator: true)
        }

        let readOnly = try await SessionHarness.make(role: .technician, permission: .readOnly)
        await assertThrows(OfficialClientPolicyError.readOnlyShareCannotMutate) {
            try await readOnly.authorizer.authorizeMutation(namespace: readOnly.namespace, presentation: readOnly.presentation)
        }
    }

    func testRevalidateRejectsASupersededSessionGeneration() async throws {
        let harness = try await SessionHarness.make()
        let trusted = try await harness.authorizer.authorizeMutation(namespace: harness.namespace, presentation: harness.presentation)
        let renewed = ServiceFixture.namespace(workspaceID: harness.namespace.workspaceID, generation: harness.namespace.sessionGeneration + 1)
        try await harness.lifecycle.activate(ServiceFixture.account(renewed))

        await assertThrows(ProductionSessionAuthorizationError.sessionSuperseded) {
            try await harness.authorizer.revalidate(trusted)
        }
    }

    func testRevalidateRejectsAChangedInstallation() async throws {
        let harness = try await SessionHarness.make()
        let trusted = try await harness.authorizer.authorizeMutation(namespace: harness.namespace, presentation: harness.presentation)
        await harness.actors.setActor(ServiceFixture.actor(for: harness.account, installationID: "installation-2"))

        await assertThrows(ProductionSessionAuthorizationError.sessionSuperseded) {
            try await harness.authorizer.revalidate(trusted)
        }
    }

    func testClaimedOperationContextMustMatchTheLiveSession() async throws {
        let harness = try await SessionHarness.make()
        _ = try await harness.authorizer.authorizeOperation(
            harness.operationContext(.exportCSV), action: .exportCSV, requiresAdministrator: true)

        await assertThrows(ProductionSessionAuthorizationError.presentationMismatch) {
            try await harness.authorizer.authorizeOperation(harness.operationContext(.exportCSV), action: .importCSV, requiresAdministrator: true)
        }
        let otherInstallation = ServiceFixture.actor(for: harness.account, installationID: "installation-2")
        await assertThrows(ProductionSessionAuthorizationError.presentationMismatch) {
            try await harness.authorizer.authorizeOperation(
                harness.operationContext(.exportCSV, actor: otherInstallation), action: .exportCSV, requiresAdministrator: true)
        }
    }

    func testValidateCurrentRequiresAdministratorOnlyForPrivilegedTransferAndAudit() async throws {
        let technician = try await SessionHarness.make(role: .technician)

        let attachment = await technician.authorizer.validateCurrent(technician.operationContext(.createAttachment))
        let readAttachment = await technician.authorizer.validateCurrent(technician.operationContext(.readAttachment))
        XCTAssertTrue(attachment)
        XCTAssertTrue(readAttachment)
        for action in [AuthorizedOperationAction.importCSV, .exportCSV, .exportAudit, .exportArchive, .restoreArchive] {
            let allowed = await technician.authorizer.validateCurrent(technician.operationContext(action))
            XCTAssertFalse(allowed, "\(action) requires administrator authorization")
        }

        let administrator = try await SessionHarness.make()
        let restore = await administrator.authorizer.validateCurrent(administrator.operationContext(.restoreArchive))
        XCTAssertTrue(restore)
    }
}
