import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl

/// Presentation claims of the single local administrator, always for the one
/// assembled account. A claim grants nothing by itself: every authority
/// re-resolves it through `ProductionSessionAuthorizer` against the live
/// session, the persisted identity (`LocalWorkspaceAuthority`,
/// `LocalActorContextProvider`) and the installation session, so a claim for
/// another namespace, actor or session is rejected there.
struct LocalRuntimeAdministratorClaims {
    let account: AccountContext
    let installationID: String
    let installationSessionID: String

    var actor: ActorContext {
        ActorContext(
            cloudKitUserRecordName: account.namespace.cloudKitAccountRecordName, role: .administrator, installationID: installationID,
            sessionGeneration: account.namespace.sessionGeneration)
    }

    var operations: OperationsAuthorization {
        OperationsAuthorization(
            actorID: account.namespace.cloudKitAccountRecordName, role: .administrator, sessionGeneration: account.namespace.sessionGeneration,
            isFresh: true)
    }

    /// A factory minting a fresh operation ID per request for `action`.
    func operation(_ action: AuthorizedOperationAction) -> () -> AuthorizedOperationContext? {
        { [account, actor] in AuthorizedOperationContext(operationID: ObjectID(), account: account, actor: actor, action: action) }
    }

    /// An attestation-only release scoped to this request, actor, installation
    /// session and a short validity window. An empty attestation yields nil.
    func cancellationRelease(for request: CancellationReleaseRequest, at now: Date) -> CancellationReleaseAuthorization? {
        let statement = request.physicalAttestation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !statement.isEmpty else { return nil }
        let scope = CancellationReleaseScope(
            workspaceZone: account.namespace.workspaceZone, workOrderID: request.workOrderID, reservationID: request.reservationID,
            cancellationRequestID: request.cancellationRequestID, actorID: account.namespace.cloudKitAccountRecordName,
            installationID: installationID, sessionID: installationSessionID, sessionGeneration: account.namespace.sessionGeneration,
            issuedAt: now, expiresAt: now.addingTimeInterval(LocalRuntimePolicies.cancellationReleaseLifetime))
        return .attestation(scope: scope, statement: statement)
    }
}
