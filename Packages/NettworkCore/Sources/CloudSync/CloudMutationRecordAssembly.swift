import Foundation
import NetworkModel
import WorkspaceChangeControl

struct CloudRecordEnvelopeAccumulator {
    private(set) var records: [CloudRecordEnvelope] = []
    private var usedKeys = Set<ResourceKey>()

    mutating func append(
        _ key: ResourceKey,
        type: String,
        version: Int,
        payload: Data,
        workspaceID: ObjectID,
        asset: CloudRecordAssetDescriptor? = nil,
        mode: CloudRecordWriteMode = .businessSave,
        deleted: Bool = false,
        condition: (ResourceKey) throws -> (systemFields: Data, changeTag: String),
        duplicateError: (ResourceKey) -> any Error,
        invalidTypeError: (String) -> any Error,
        invalidNameError: (ResourceKey) -> any Error
    ) throws {
        guard usedKeys.insert(key).inserted else { throw duplicateError(key) }
        guard let canonicalType = CloudRecordNaming.canonicalRecordType(type) else {
            throw invalidTypeError(type)
        }
        let recordName = CloudRecordNaming.recordName(for: key, workspaceID: workspaceID)
        guard CloudRecordNaming.isValidRecordName(recordName) else {
            throw invalidNameError(key)
        }
        let precondition = try condition(key)
        records.append(
            CloudRecordEnvelope(
                recordName: recordName,
                resourceKey: key,
                workspaceID: workspaceID,
                recordType: canonicalType,
                schemaVersion: version,
                payload: payload,
                recordAsset: asset,
                writeMode: mode,
                systemFields: precondition.systemFields,
                changeTag: precondition.changeTag,
                isDeleted: deleted
            ))
    }
}

extension MutationPrecondition {
    func cloudPrecondition(recordName: String) -> CloudRecordPrecondition {
        switch self {
        case .mustNotExist:
            return .mustNotExist(recordName: recordName)
        case .exactSystemFields(_, let exact):
            return .exact(
                recordName: recordName,
                systemFields: exact.systemFields,
                changeTag: exact.changeTag)
        }
    }
}

extension CloudRecordPrecondition {
    var preconditionRecordName: String {
        switch self {
        case .mustNotExist(let recordName), .exact(let recordName, _, _):
            return recordName
        }
    }
}
