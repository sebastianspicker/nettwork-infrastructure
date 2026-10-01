import Foundation

/// Decides whether stored canonical bytes are the encoding of the value they
/// decode to. Readers re-encode the decoded value and compare it with the
/// stored bytes. Ordered arrays decode and re-encode in the same order, so only
/// set-valued fields can differ: builds before canonical set encoding stored
/// them in hash order, and some set fields (for example the topology
/// reservation port sets) still encode in hash order. Those payloads stay
/// accepted. Object member order is not compared (JSONSerialization does not
/// keep it); such a payload decodes to the same value. One value can therefore
/// have several accepted encodings, so never hash stored bytes and expect a
/// unique encoding; hash a deterministic projection instead, as intent digests do.
public enum CanonicalPayloadComparison {
    public static func matches(stored: Data, reencoded: Data) -> Bool {
        if stored == reencoded { return true }
        // A permuted array keeps every byte, so any other difference in
        // spacing, escaping, duplicate members or number spelling is rejected.
        guard stored.count == reencoded.count,
            let storedTree = try? JSONSerialization.jsonObject(with: stored, options: [.fragmentsAllowed]),
            let reencodedTree = try? JSONSerialization.jsonObject(with: reencoded, options: [.fragmentsAllowed]),
            let storedForm = canonicalForm(storedTree), let reencodedForm = canonicalForm(reencodedTree)
        else {
            return false
        }
        return storedForm == reencodedForm
    }

    /// An unambiguous text form of a JSON tree in which every array is a
    /// multiset. Strings are length-prefixed and numbers carry their exact
    /// parsed type, so `1`, `1.0`, `true`, and `"1"` all stay distinct.
    private static func canonicalForm(_ node: Any) -> String? {
        switch node {
        case let object as [String: Any]:
            var members: [String] = []
            for key in object.keys.sorted() {
                guard let value = object[key], let form = canonicalForm(value) else { return nil }
                members.append(string(key) + ":" + form)
            }
            return "{" + members.joined(separator: ",") + "}"
        case let array as [Any]:
            let elements = array.compactMap(canonicalForm)
            guard elements.count == array.count else { return nil }
            return "[" + elements.sorted().joined(separator: ",") + "]"
        case let value as String:
            return string(value)
        case let value as NSNumber:
            return number(value)
        case is NSNull:
            return "z"
        default:
            return nil
        }
    }

    private static func string(_ value: String) -> String {
        "s\(value.utf8.count):\(value)"
    }

    private static func number(_ value: NSNumber) -> String {
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return value.boolValue ? "b1" : "b0"
        }
        return "n" + String(cString: value.objCType) + ":" + value.stringValue
    }
}
