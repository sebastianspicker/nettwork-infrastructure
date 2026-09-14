import CryptoKit
import Foundation
import NetworkModel
import WorkspaceChangeControl

public enum WorkspaceTransferCommitment {
    public static func member(for record: WorkspaceTransferRecord) throws -> String {
        digest(
            domain: "nettwork.workspace-transfer-member.v1",
            fields: [
                Data(record.recordType.rawValue.utf8), Data(record.resourceKey.description.utf8),
                try WorkspaceTransferCoding.encode(record),
            ])
    }

    public static func initial(transferID: ObjectID, operationID: ObjectID) -> String {
        digest(
            domain: "nettwork.workspace-transfer-stage-initial.v1",
            fields: [
                Data(transferID.description.utf8),
                Data(operationID.description.utf8),
            ])
    }

    public static func batch(
        transferID: ObjectID,
        operationID: ObjectID,
        index: Int,
        previousSHA256: String,
        members: [WorkspaceTransferStagingMember]
    ) -> String {
        var indexBytes = UInt64(index).bigEndian
        let memberBytes = members.reduce(into: Data()) { data, member in
            data.append(Data(member.id.utf8))
            data.append(0)
            data.append(Data(member.sha256.utf8))
            data.append(0)
        }
        return digest(
            domain: "nettwork.workspace-transfer-stage-batch.v1",
            fields: [
                Data(transferID.description.utf8),
                Data(operationID.description.utf8),
                Data(bytes: &indexBytes, count: MemoryLayout<UInt64>.size),
                Data(previousSHA256.utf8),
                memberBytes,
            ])
    }

    private static func digest(domain: String, fields: [Data]) -> String {
        var hasher = SHA256()
        update(Data(domain.utf8), into: &hasher)
        for field in fields { update(field, into: &hasher) }
        return HexDigest.string(hasher.finalize())
    }

    private static func update(_ field: Data, into hasher: inout SHA256) {
        var length = UInt64(field.count).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
        hasher.update(data: field)
    }
}

/// The immutable identity and digest of one staged record. Its identifier is
/// derived from the canonical resource identity, rather than random process
/// state, so a reopened transfer has the same member list.
public struct WorkspaceTransferStagingMember: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let recordType: WorkspaceTransferRecordType
    public let resourceKey: ResourceKey
    public let byteCount: Int
    public let sha256: String

    public init(record: WorkspaceTransferRecord) throws {
        recordType = record.recordType
        resourceKey = record.resourceKey
        let payload = try WorkspaceTransferCoding.encode(record)
        byteCount = payload.count
        sha256 = try WorkspaceTransferCommitment.member(for: record)
        id = "\(recordType.rawValue):\(resourceKey.description)"
    }
}

/// One bounded append to the rolling staged-transfer commitment chain.
public struct WorkspaceTransferStagingBatch: Codable, Hashable, Sendable {
    public let index: Int
    public let members: [WorkspaceTransferStagingMember]
    public let previousSHA256: String
    public let commitmentSHA256: String

    public init(
        index: Int,
        members: [WorkspaceTransferStagingMember],
        previousSHA256: String,
        transferID: ObjectID,
        operationID: ObjectID
    ) throws {
        guard index >= 0, !members.isEmpty, members.count <= WorkspaceTransferStagingLimits.maximumMembersPerBatch else {
            throw WorkspaceTransferStagingError.invalidBatchSize
        }
        guard Set(members.map(\.id)).count == members.count,
            members.allSatisfy({ $0.byteCount >= 0 && !$0.sha256.isEmpty })
        else {
            throw WorkspaceTransferStagingError.invalidMember
        }
        self.index = index
        self.members = members
        self.previousSHA256 = previousSHA256
        commitmentSHA256 = WorkspaceTransferCommitment.batch(
            transferID: transferID,
            operationID: operationID,
            index: index,
            previousSHA256: previousSHA256,
            members: members
        )
    }
}

/// Deterministic plan for the invisible, resumable transfer stage. Records are
/// sorted by their canonical archive ordering before they become members.
public struct WorkspaceTransferStagingPlan: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let transferID: ObjectID
    public let operationID: ObjectID
    public let members: [WorkspaceTransferStagingMember]
    public let batches: [WorkspaceTransferStagingBatch]
    public let commitmentSHA256: String

    public init(transferID: ObjectID, operationID: ObjectID, records: [WorkspaceTransferRecord]) throws {
        schemaVersion = Self.currentSchemaVersion
        self.transferID = transferID
        self.operationID = operationID
        let sorted = records.sorted(by: Self.less)
        let members = try sorted.map { try WorkspaceTransferStagingMember(record: $0) }
        guard Set(members.map(\.id)).count == members.count else { throw WorkspaceTransferStagingError.invalidMember }
        self.members = members

        var previous = WorkspaceTransferCommitment.initial(transferID: transferID, operationID: operationID)
        var batches: [WorkspaceTransferStagingBatch] = []
        for (index, offset) in stride(from: 0, to: members.count, by: WorkspaceTransferStagingLimits.maximumMembersPerBatch).enumerated() {
            let end = min(offset + WorkspaceTransferStagingLimits.maximumMembersPerBatch, members.count)
            let batch = try WorkspaceTransferStagingBatch(
                index: index,
                members: Array(members[offset..<end]),
                previousSHA256: previous,
                transferID: transferID,
                operationID: operationID
            )
            batches.append(batch)
            previous = batch.commitmentSHA256
        }
        self.batches = batches
        commitmentSHA256 = previous
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
            Set(members.map(\.id)).count == members.count
        else {
            throw WorkspaceTransferStagingError.invalidMember
        }
        var previous = WorkspaceTransferCommitment.initial(transferID: transferID, operationID: operationID)
        var flattened: [WorkspaceTransferStagingMember] = []
        for (index, batch) in batches.enumerated() {
            guard batch.index == index,
                batch.previousSHA256 == previous,
                !batch.members.isEmpty,
                batch.members.count <= WorkspaceTransferStagingLimits.maximumMembersPerBatch
            else {
                throw WorkspaceTransferStagingError.invalidBatchSize
            }
            let expected = WorkspaceTransferCommitment.batch(
                transferID: transferID,
                operationID: operationID,
                index: index,
                previousSHA256: previous,
                members: batch.members
            )
            guard batch.commitmentSHA256 == expected else { throw WorkspaceTransferStagingError.invalidMember }
            previous = expected
            flattened.append(contentsOf: batch.members)
        }
        guard flattened == members, commitmentSHA256 == previous else {
            throw WorkspaceTransferStagingError.invalidCheckpoint
        }
    }

    private static func less(_ lhs: WorkspaceTransferRecord, _ rhs: WorkspaceTransferRecord) -> Bool {
        if lhs.recordType != rhs.recordType { return lhs.recordType.rawValue < rhs.recordType.rawValue }
        return lhs.resourceKey < rhs.resourceKey
    }
}

/// Persist this exact value after each acknowledged batch. It proves the
/// durable prefix without treating a process-local in-memory cursor as truth.
public struct WorkspaceTransferStagingCheckpoint: Codable, Hashable, Sendable {
    public let transferID: ObjectID
    public let operationID: ObjectID
    public let completedBatchCount: Int
    public let completedMemberCount: Int
    public let rollingCommitmentSHA256: String

    public init(plan: WorkspaceTransferStagingPlan, completedBatchCount: Int) throws {
        try plan.validate()
        guard completedBatchCount >= 0, completedBatchCount <= plan.batches.count else {
            throw WorkspaceTransferStagingError.invalidCheckpoint
        }
        transferID = plan.transferID
        operationID = plan.operationID
        self.completedBatchCount = completedBatchCount
        completedMemberCount = plan.batches.prefix(completedBatchCount).reduce(0) { $0 + $1.members.count }
        rollingCommitmentSHA256 =
            completedBatchCount == 0
            ? WorkspaceTransferCommitment.initial(transferID: plan.transferID, operationID: plan.operationID)
            : plan.batches[completedBatchCount - 1].commitmentSHA256
    }

    public func validates(plan: WorkspaceTransferStagingPlan) throws {
        try plan.validate()
        guard transferID == plan.transferID,
            operationID == plan.operationID,
            completedBatchCount >= 0,
            completedBatchCount <= plan.batches.count,
            completedMemberCount == plan.batches.prefix(completedBatchCount).reduce(0, { $0 + $1.members.count })
        else {
            throw WorkspaceTransferStagingError.invalidCheckpoint
        }
        let expected =
            completedBatchCount == 0
            ? WorkspaceTransferCommitment.initial(transferID: plan.transferID, operationID: plan.operationID)
            : plan.batches[completedBatchCount - 1].commitmentSHA256
        guard rollingCommitmentSHA256 == expected else { throw WorkspaceTransferStagingError.invalidCheckpoint }
    }
}
