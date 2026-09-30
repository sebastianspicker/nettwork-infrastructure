import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl

@MainActor
extension IPAMWorkspaceModel {
    func stage(_ request: IPAMWorkOrderRequest) async {
        guard !request.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !request.ticketID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            state = .unavailable("A work-order title and ticket are required before staging an IPAM request.")
            return
        }
        do {
            let id = try await drafts.stage(request, in: account.namespace)
            stagedWorkOrderID = id
            await onStagedWorkOrder?(id)
            state = .pending("IPAM changes are staged in work order \(id.description). Authoritative IPAM data has not changed.")
        } catch {
            state = .conflict("The VRF revision changed or the proposed resources conflict. Review the planned request before retrying.")
        }
    }
}
