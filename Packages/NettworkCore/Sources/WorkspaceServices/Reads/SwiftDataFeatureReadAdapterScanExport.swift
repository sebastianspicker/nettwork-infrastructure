import CloudSync
import ContentSafety
import CryptoKit
import FeatureContracts
import Foundation
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl

extension SwiftDataFeatureReadAdapter {
    public func labels(in namespace: PersistenceNamespace, limit: Int) async throws -> [PrivacySafeLabel] {
        let projection = try await readProjection(in: namespace)
        let boundedLimit = min(max(limit, 1), PrivacySafeLabelValidator.maximumLabels)
        let topologyTombstones = Set(projection.topology.tombstones.map(\.id))
        let hierarchyTombstones = Set(projection.hierarchy.tombstones.map(\.id))
        let candidates: [(ObjectID, AssetCode)] =
            projection.topology.devices
            .filter { !topologyTombstones.contains($0.id) }
            .map { ($0.id, $0.assetCode) }
            + projection.topology.cables
            .filter { !topologyTombstones.contains($0.id) && $0.status != .planned }
            .map { ($0.id, $0.assetCode) }
            + projection.hierarchy.racks
            .filter { $0.deletedAt == nil && !hierarchyTombstones.contains($0.id) }
            .map { ($0.id, $0.assetCode) }

        return
            candidates
            .filter { !projection.hasPendingWork(for: .object($0.0)) && !projection.hasConflict(for: .object($0.0)) }
            .compactMap { objectID, assetCode -> PrivacySafeLabel? in
                let checkText = String(objectID.description.replacingOccurrences(of: "-", with: "").prefix(8)).uppercased()
                let label = PrivacySafeLabel(objectID: objectID, assetCode: assetCode, checkText: checkText)
                guard (try? PrivacySafeLabelValidator.validate(label)) != nil else { return nil }
                return label
            }
            .sorted {
                if $0.assetCode != $1.assetCode { return $0.assetCode < $1.assetCode }
                return $0.objectID < $1.objectID
            }
            .prefix(boundedLimit)
            .map { $0 }
    }

    public func exportCSV(authorization: AuthorizedOperationContext) async throws -> CSVWorkspaceExportDocument {
        try await operationBoundary.perform(.workspaceExport, outputRecordCount: { $0.files.count }) {
            try await self.performCSVExport(authorization: authorization)
        }
    }

    private func performCSVExport(authorization: AuthorizedOperationContext) async throws -> CSVWorkspaceExportDocument {
        try await validateCSVExportAuthorization(authorization)
        let projection = try await completeCSVExportProjection()
        try Task.checkCancellation()
        let document = try CSVWorkspaceExporter.export(projection.csvWorkspaceExportProjection)
        try await validateCSVExportAuthorization(authorization)
        return document
    }

    public func validateCSVExportAuthorization(_ authorization: AuthorizedOperationContext) async throws {
        guard authorization.action == .exportCSV,
            authorization.actor.role == .administrator,
            authorization.account.sharePermission == .owner || authorization.account.sharePermission == .readWrite,
            authorization.validateCurrent(account: account),
            await currentAuthorizationContext.validateCurrent(authorization)
        else {
            throw ProductionAdapterError.invalidExportAuthorization
        }
    }

    func readProjection(in namespace: PersistenceNamespace) async throws -> MirrorProjection {
        guard namespace == account.namespace else { throw ProductionAdapterError.namespaceMismatch }
        let records = try await reader.records(in: namespace, recordTypes: MirrorProjection.featureRecordTypes, limitPerType: recordLimitPerType)
        let conflicts = try await persistence.unresolvedCases(in: namespace, limit: 200)
        let conflictResourceKeys = try await persistence.unresolvedConflictResourceKeys(in: namespace)
        let conflictCount = try await persistence.unresolvedConflictCount(in: namespace)
        let syncState = try await persistence.syncState(in: namespace)
        return try MirrorProjection(
            records: records, conflicts: conflicts, conflictResourceKeys: conflictResourceKeys, conflictCount: conflictCount, syncState: syncState
        )
    }

    private func completeCSVExportProjection() async throws -> MirrorProjection {
        // The typed SwiftData reader probes `limit + 1` and throws rather than
        // truncating, so this exact published table limit fails closed.
        let limitPerType = CSVImportLimits.maximumRowsPerTable
        let records = try await reader.records(in: account.namespace, recordTypes: MirrorProjection.csvExportRecordTypes, limitPerType: limitPerType)
        return try MirrorProjection(records: records, conflicts: [], conflictResourceKeys: [], conflictCount: 0, syncState: nil)
    }
}
