import Foundation
import NetworkModel
import SwiftData
import WorkspaceChangeControl

extension SwiftDataPersistenceStore {
    public func reconcileCloudRecordNameIdentities(
        _ identities: [LocalCloudRecordNameIdentity],
        in namespace: PersistenceNamespace, maximumEntries: Int
    ) throws {
        try validateActiveLease(for: namespace)
        guard maximumEntries >= LocalCloudRecordNameIdentityIndexLimits.minimumCapacity else {
            throw PersistenceStoreError.cloudRecordNameIdentityCapacityExceeded(maximumEntries)
        }
        let uniqueIdentities = try uniqueCloudRecordNameIdentities(identities, in: namespace)
        try transaction {
            try validateActiveLease(for: namespace)
            try reconcileCloudRecordNameIdentityModels(uniqueIdentities, in: namespace, maximumEntries: maximumEntries)
            try validateActiveLease(for: namespace)
        }
    }

    func uniqueCloudRecordNameIdentities(_ identities: [LocalCloudRecordNameIdentity], in namespace: PersistenceNamespace) throws -> [String:
        LocalCloudRecordNameIdentity]
    {
        var unique = [String: LocalCloudRecordNameIdentity]()
        for identity in identities {
            try validateCloudRecordNameIdentity(identity, in: namespace)
            guard unique[identity.recordName].map({ $0 == identity }) ?? true else {
                throw PersistenceStoreError.invalidCloudRecordNameIdentity(identity.recordName)
            }
            unique[identity.recordName] = identity
        }
        return unique
    }

    func reconcileCloudRecordNameIdentityModels(_ identities: [String: LocalCloudRecordNameIdentity], in namespace: PersistenceNamespace, maximumEntries: Int)
        throws
    {
        let existingModels = try cloudRecordNameIdentityModels(namespaceKey: PersistenceNamespaceKey.value(for: namespace))
        let existing = try cloudRecordNameIdentityMap(existingModels)
        try validateCloudRecordNameIdentityCapacity(existing: existing, incoming: identities, maximumEntries: maximumEntries)
        for identity in identities.values { try persistCloudRecordNameIdentity(identity, existing: existing[identity.recordName]) }
    }

    func cloudRecordNameIdentityMap(_ models: [LocalCloudRecordNameIdentityModel]) throws -> [String: LocalCloudRecordNameIdentityModel] {
        var values = [String: LocalCloudRecordNameIdentityModel]()
        for model in models {
            guard values[model.recordName] == nil else { throw PersistenceStoreError.malformedStoredValue("duplicate cloud record-name identity") }
            values[model.recordName] = model
        }
        return values
    }

    func validateCloudRecordNameIdentityCapacity(
        existing: [String: LocalCloudRecordNameIdentityModel], incoming: [String: LocalCloudRecordNameIdentity], maximumEntries: Int
    ) throws {
        let newCount = incoming.keys.filter { existing[$0] == nil }.count
        guard existing.count <= maximumEntries - newCount else { throw PersistenceStoreError.cloudRecordNameIdentityCapacityExceeded(maximumEntries) }
    }

    func persistCloudRecordNameIdentity(_ identity: LocalCloudRecordNameIdentity, existing: LocalCloudRecordNameIdentityModel?) throws {
        if let existing { try overwrite(existing, with: identity) } else { modelContext.insert(try LocalCloudRecordNameIdentityModel(identity: identity)) }
    }

    public func storeCloudRecordNameIdentity(
        _ identity: LocalCloudRecordNameIdentity,
        in namespace: PersistenceNamespace, maximumEntries: Int
    ) throws {
        try reconcileCloudRecordNameIdentities([identity], in: namespace, maximumEntries: maximumEntries)
    }

    /// Explicit namespace teardown is the only deletion path for identity
    /// evidence. A stale account/session handle cannot purge another lease.
    @discardableResult
    public func purgeCloudRecordNameIdentities(in namespace: PersistenceNamespace) throws -> Int {
        try transaction {
            try validateActiveLease(for: namespace)
            let models = try cloudRecordNameIdentityModels(
                namespaceKey: PersistenceNamespaceKey.value(for: namespace))
            models.forEach(modelContext.delete)
            try validateActiveLease(for: namespace)
            return models.count
        }
    }

    // MARK: CloudSync batch/replay seam

    /// Applies an already-validated authoritative batch in one SwiftData save.
    /// CloudSync must validate remote schemas and references before calling it.
}
