import ContentSafety
import CryptoKit
import Foundation
import NetworkModel
import WorkspaceChangeControl

enum CanonicalActivationReceipt {
    static func intent(
        domain: String, namespace: PersistenceNamespace, operationID: ObjectID,
        fields: [String]
    ) throws -> IntentDigest {
        var hasher = SHA256()
        update(domain, into: &hasher)
        update(namespace.containerIdentifier, into: &hasher)
        update(namespace.cloudKitAccountRecordName, into: &hasher)
        update(namespace.workspaceID.description, into: &hasher)
        update(namespace.zoneName, into: &hasher)
        update(namespace.zoneOwnerRecordName, into: &hasher)
        update(String(namespace.sessionGeneration), into: &hasher)
        update(operationID.description, into: &hasher)
        for field in fields { update(field, into: &hasher) }
        return try IntentDigest(algorithm: .sha256, bytes: Array(hasher.finalize()))
    }

    private static func update(_ value: String, into hasher: inout SHA256) {
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
        hasher.update(data: bytes)
    }
}

enum HexDigest { static func string<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() } }
