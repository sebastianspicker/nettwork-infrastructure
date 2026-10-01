import CloudSync
import Foundation
import WorkspaceChangeControl

/// Accepts only a payload that round-trips through the deterministic Cloud
/// codec, allowing the set order of payloads stored before canonical set
/// encoding. Archive and mirror readers use this before trusting record fields.
func canonicalDecoded<Value: Codable>(_ type: Value.Type, from payload: Data) -> Value? {
    guard let value = try? CloudDeterministicCoding.decode(type, from: payload),
        let reencoded = try? CloudDeterministicCoding.encode(value),
        CanonicalPayloadComparison.matches(stored: payload, reencoded: reencoded)
    else {
        return nil
    }
    return value
}
