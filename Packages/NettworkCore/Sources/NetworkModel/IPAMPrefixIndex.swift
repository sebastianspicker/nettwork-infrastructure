import Foundation

/// Canonical prefix lookup keyed by VRF, address family, network, and prefix
/// length. Active prefixes alone participate in allocation validation.
struct IPAMPrefixIndex {
    private struct Key: Hashable {
        let vrfID: ObjectID
        let bitWidth: Int
        let network: IPAddress
        let prefixLength: Int
    }

    private struct IndexedPrefix {
        let inputOffset: Int
        let prefix: Prefix
    }

    private let prefixesByKey: [Key: [IndexedPrefix]]

    init(activePrefixes: [Prefix]) {
        prefixesByKey = Dictionary(
            grouping: activePrefixes.enumerated().map { offset, prefix in
                (
                    Key(
                        vrfID: prefix.vrfID,
                        bitWidth: prefix.network.bitWidth,
                        network: prefix.network,
                        prefixLength: prefix.prefixLength
                    ),
                    IndexedPrefix(inputOffset: offset, prefix: prefix)
                )
            }, by: \.0
        ).mapValues { $0.map(\.1) }
    }

    func earliestDuplicatePair() -> (Prefix, Prefix)? {
        var earliest: (first: IndexedPrefix, second: IndexedPrefix)?
        for values in prefixesByKey.values where values.count > 1 {
            let candidate = (values[0], values[1])
            guard let current = earliest else {
                earliest = candidate
                continue
            }
            if candidate.0.inputOffset < current.first.inputOffset
                || (candidate.0.inputOffset == current.first.inputOffset && candidate.1.inputOffset < current.second.inputOffset)
            {
                earliest = candidate
            }
        }
        return earliest.map { ($0.first.prefix, $0.second.prefix) }
    }

    func containingPrefixes(for address: IPAddress, vrfID: ObjectID) -> [Prefix] {
        guard address.isWellFormed else { return [] }
        var result: [Prefix] = []
        for prefixLength in 0...address.bitWidth {
            let key = Key(
                vrfID: vrfID,
                bitWidth: address.bitWidth,
                network: address.masked(prefixLength: prefixLength),
                prefixLength: prefixLength
            )
            result.append(contentsOf: prefixesByKey[key, default: []].map(\.prefix))
        }
        return result
    }
}
