import ContentSafety
import CoreGraphics
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

@MainActor
extension FloorPlanViewModel {
    func move(anchor: FloorPlanAnchor, to point: CGPoint, in size: CGSize, authorization: OperationsAuthorization) async {
        guard size.width > 0, size.height > 0 else {
            anchorActionError = "The floor-plan canvas size is unavailable."
            return
        }
        await move(
            anchor: anchor,
            normalizedX: Double(point.x / size.width),
            normalizedY: Double(point.y / size.height),
            authorization: authorization
        )
    }

    func move(
        anchor: FloorPlanAnchor,
        normalizedX: Double,
        normalizedY: Double,
        authorization: OperationsAuthorization
    ) async {
        guard authorization.permitsPrivilegedAction else {
            anchorActionError = "Current authorization does not permit anchor changes."
            return
        }
        guard let generation = beginAnchorAction() else { return }
        var updated = anchor
        updated.x = min(max(normalizedX, 0), 1)
        updated.y = min(max(normalizedY, 0), 1)
        await stageAnchorAction(generation) {
            try await service.saveNormalizedAnchor(updated, authorization: authorization)
        }
    }

    func addAnchor(for objectID: ObjectID, authorization: OperationsAuthorization) async {
        guard authorization.permitsPrivilegedAction else {
            anchorActionError = "Current authorization does not permit anchor changes."
            return
        }
        guard let generation = beginAnchorAction() else { return }
        let anchor = FloorPlanAnchor(objectID: objectID, floorID: floorID, x: 0.5, y: 0.5)
        await stageAnchorAction(generation) {
            try await service.saveNormalizedAnchor(anchor, authorization: authorization)
        }
    }

    func remove(anchor: FloorPlanAnchor, authorization: OperationsAuthorization) async {
        guard anchors.contains(anchor) else {
            anchorActionError = "The selected anchor is no longer part of this floor plan. Refresh before trying again."
            return
        }
        guard authorization.permitsPrivilegedAction else {
            anchorActionError = "Current authorization does not permit anchor changes."
            return
        }
        guard let generation = beginAnchorAction() else { return }
        await stageAnchorAction(generation) {
            try await service.removeNormalizedAnchor(anchor, authorization: authorization)
        }
    }

    private func beginAnchorAction() -> UUID? {
        guard anchorActionGeneration == nil else { return nil }
        let generation = UUID()
        anchorActionGeneration = generation
        anchorActionError = nil
        return generation
    }

    private func stageAnchorAction(
        _ generation: UUID,
        operation: () async throws -> ObjectID
    ) async {
        do {
            let id = try await operation()
            guard anchorActionGeneration == generation else { return }
            pendingAnchorWorkOrderIDs.insert(id)
            await onStagedWorkOrder(id)
            guard anchorActionGeneration == generation else { return }
            anchorActionGeneration = nil
        } catch {
            guard anchorActionGeneration == generation else { return }
            anchorActionError = error.localizedDescription
            anchorActionGeneration = nil
        }
    }
}
