import ContentSafety
import WorkspaceChangeControl

enum ImportOperationAuthorization {
    static func validate(
        _ context: AuthorizedOperationContext,
        expectedAction: AuthorizedOperationAction,
        currentContext: any CurrentAuthorizationContextProviding,
        currentAccount: @Sendable () async throws -> AccountContext
    ) async throws {
        guard await currentContext.validateCurrent(context) else {
            throw ImportAuthorizationError.staleContext
        }
        guard context.action == expectedAction else { throw ImportAuthorizationError.actionMismatch }
        guard context.actor.role == .administrator else { throw ImportAuthorizationError.administratorRequired }
        guard context.account.sharePermission == .owner || context.account.sharePermission == .readWrite else {
            throw ImportAuthorizationError.writePermissionRequired
        }
        guard context.validateCurrent(account: try await currentAccount()),
            await currentContext.validateCurrent(context)
        else {
            throw ImportAuthorizationError.staleContext
        }
    }
}
