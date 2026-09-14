import Foundation

public enum DeviceKind: String, Codable, CaseIterable, Sendable {
    case switchDevice, server, workstation, patchPanel, fiberPanel, wallOutlet, pdu, passive, generic

    var permitsPassThrough: Bool {
        switch self {
        case .patchPanel, .fiberPanel, .wallOutlet, .passive: true
        case .switchDevice, .server, .workstation, .pdu, .generic: false
        }
    }
}

public enum PortMedium: String, Codable, CaseIterable, Sendable { case copper, fiber, power, other }
public enum Connector: String, Codable, CaseIterable, Sendable { case rj45, lc, sc, mpo, c13, c14, other }
public enum CableKind: String, Codable, CaseIterable, Sendable { case fixed, patchCord, fiberLink }
public enum CableStatus: String, Codable, CaseIterable, Sendable { case planned, installed, unavailable }
public enum PortState: String, Codable, CaseIterable, Sendable { case free, occupied, reserved, planned, unavailable }

public enum LocationKind: String, Codable, CaseIterable, Sendable {
    case workspace, site, building, floor, room, unrackedArea

    var allowedParentKinds: Set<LocationKind> {
        switch self {
        case .workspace: []
        case .site: [.workspace]
        case .building: [.site]
        case .floor: [.building]
        case .room: [.floor]
        case .unrackedArea: [.room]
        }
    }
}

/// A containment record. `id`, `name`, and `parentID` retain the original
/// import shape; `kind` makes the previously generic tree explicit.
public struct Location: Identifiable, Codable, Hashable, Sendable {
    public let id: ObjectID
    public var name: String
    public var kind: LocationKind
    public var parentID: ObjectID?
    public var deletedAt: Date?

    /// The default preserves source/import compatibility: a root is a
    /// workspace and a legacy child is a room until an importer assigns its
    /// more-specific kind.
    public init(id: ObjectID = .init(), name: String, kind: LocationKind? = nil, parentID: ObjectID? = nil, deletedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.kind = kind ?? (parentID == nil ? .workspace : .room)
        self.parentID = parentID
        self.deletedAt = deletedAt
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind, parentID, deletedAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ObjectID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        parentID = try container.decodeIfPresent(ObjectID.self, forKey: .parentID)
        kind = try container.decodeIfPresent(LocationKind.self, forKey: .kind) ?? (parentID == nil ? .workspace : .room)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(parentID, forKey: .parentID)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
    }
}

public struct Rack: Identifiable, Codable, Hashable, Sendable {
    public let id: ObjectID
    public var assetCode: AssetCode
    /// A rack belongs directly to a room; unracked areas are sibling room
    /// children used for devices that have no rack placement.
    public var locationID: ObjectID
    public var heightRU: Int
    public var deletedAt: Date?
    public init(id: ObjectID = .init(), assetCode: AssetCode, locationID: ObjectID, heightRU: Int, deletedAt: Date? = nil) {
        self.id = id
        self.assetCode = assetCode
        self.locationID = locationID
        self.heightRU = heightRU
        self.deletedAt = deletedAt
    }
}

public enum HierarchyObjectKind: String, Codable, CaseIterable, Sendable {
    case workspace, site, building, floor, room, unrackedArea, rack

    init(_ kind: LocationKind) {
        switch kind {
        case .workspace: self = .workspace
        case .site: self = .site
        case .building: self = .building
        case .floor: self = .floor
        case .room: self = .room
        case .unrackedArea: self = .unrackedArea
        }
    }
}

/// A durable delete marker prevents stale clients from recreating an object
/// after the corresponding live record has been compacted away.
public struct HierarchyTombstone: Identifiable, Codable, Hashable, Sendable {
    public let id: ObjectID
    public var kind: HierarchyObjectKind
    public var deletedAt: Date

    public init(id: ObjectID, kind: HierarchyObjectKind, deletedAt: Date) {
        self.id = id
        self.kind = kind
        self.deletedAt = deletedAt
    }
}

public enum HierarchyValidationError: Error, Hashable, Sendable {
    case duplicateObject(ObjectID)
    case duplicateTombstone(ObjectID)
    case tombstoneConflictsWithObject(ObjectID)
    case missingWorkspace
    case multipleWorkspaces
    case missingObject(ObjectID)
    case deletedObject(ObjectID)
    case missingParent(childID: ObjectID, parentID: ObjectID)
    case invalidRoot(ObjectID)
    case invalidParentType(childID: ObjectID, parentID: ObjectID)
    case invalidRackParent(rackID: ObjectID, locationID: ObjectID)
    case deletedParent(childID: ObjectID, parentID: ObjectID)
    case containmentCycle(ObjectID)
    case cannotDeleteWithLiveChildren(ObjectID)
}

/// The authoritative containment aggregate. It deliberately validates before
/// accepting a move, soft deletion, or tombstone addition.
public struct WorkspaceHierarchy: Codable, Hashable, Sendable {
    public var locations: [Location]
    public var racks: [Rack]
    public var tombstones: [HierarchyTombstone]

    public init(locations: [Location] = [], racks: [Rack] = [], tombstones: [HierarchyTombstone] = []) {
        self.locations = locations
        self.racks = racks
        self.tombstones = tombstones
    }

    public func validate() throws {
        let locationsByID = try locationIndex()
        let objectIDs = try allObjectIDs(locationsByID: locationsByID)
        try validateTombstones(against: objectIDs)
        try validateWorkspaceCount()
        try validateLocations(using: locationsByID)
        try validateRacks(using: locationsByID)
        try validateContainment(using: locationsByID)
    }

    private func locationIndex() throws -> [ObjectID: Location] {
        var result = [ObjectID: Location]()
        for location in locations {
            guard result.updateValue(location, forKey: location.id) == nil else { throw HierarchyValidationError.duplicateObject(location.id) }
        }
        return result
    }

    private func allObjectIDs(locationsByID: [ObjectID: Location]) throws -> Set<ObjectID> {
        var result = Set(locationsByID.keys)
        for rack in racks {
            guard result.insert(rack.id).inserted else { throw HierarchyValidationError.duplicateObject(rack.id) }
        }
        return result
    }

    private func validateTombstones(against objectIDs: Set<ObjectID>) throws {
        var tombstoneIDs = Set<ObjectID>()
        for tombstone in tombstones {
            guard tombstoneIDs.insert(tombstone.id).inserted else { throw HierarchyValidationError.duplicateTombstone(tombstone.id) }
            guard !objectIDs.contains(tombstone.id) else { throw HierarchyValidationError.tombstoneConflictsWithObject(tombstone.id) }
        }
    }

    private func validateWorkspaceCount() throws {
        let count = locations.filter { $0.kind == .workspace && $0.deletedAt == nil }.count
        guard count > 0 else { throw HierarchyValidationError.missingWorkspace }
        guard count == 1 else { throw HierarchyValidationError.multipleWorkspaces }
    }

    private func validateLocations(using locationsByID: [ObjectID: Location]) throws {
        for location in locations where location.deletedAt == nil {
            try validate(location: location, using: locationsByID)
        }
    }

    private func validate(location: Location, using locationsByID: [ObjectID: Location]) throws {
        guard location.kind != .workspace else {
            guard location.parentID == nil else { throw HierarchyValidationError.invalidRoot(location.id) }
            return
        }
        guard let parentID = location.parentID else { throw HierarchyValidationError.invalidRoot(location.id) }
        guard let parent = locationsByID[parentID] else { throw HierarchyValidationError.missingParent(childID: location.id, parentID: parentID) }
        guard parent.deletedAt == nil else { throw HierarchyValidationError.deletedParent(childID: location.id, parentID: parentID) }
        guard location.kind.allowedParentKinds.contains(parent.kind) else {
            throw HierarchyValidationError.invalidParentType(childID: location.id, parentID: parentID)
        }
    }

    private func validateRacks(using locationsByID: [ObjectID: Location]) throws {
        for rack in racks where rack.deletedAt == nil {
            guard let parent = locationsByID[rack.locationID] else { throw HierarchyValidationError.missingParent(childID: rack.id, parentID: rack.locationID) }
            guard parent.deletedAt == nil else { throw HierarchyValidationError.deletedParent(childID: rack.id, parentID: rack.locationID) }
            guard parent.kind == .room else { throw HierarchyValidationError.invalidRackParent(rackID: rack.id, locationID: rack.locationID) }
        }
    }

    private func validateContainment(using locationsByID: [ObjectID: Location]) throws {
        for location in locations {
            try validateParentChain(of: location, using: locationsByID)
        }
    }

    private func validateParentChain(of location: Location, using locationsByID: [ObjectID: Location]) throws {
        var visited = Set<ObjectID>()
        var current = location
        while let parentID = current.parentID {
            guard visited.insert(current.id).inserted else { throw HierarchyValidationError.containmentCycle(location.id) }
            guard let parent = locationsByID[parentID] else { return }
            current = parent
        }
    }

    public mutating func move(locationID: ObjectID, to parentID: ObjectID?) throws {
        guard let index = locations.firstIndex(where: { $0.id == locationID }) else { throw HierarchyValidationError.missingObject(locationID) }
        guard locations[index].deletedAt == nil else { throw HierarchyValidationError.deletedObject(locationID) }
        var candidate = self
        candidate.locations[index].parentID = parentID
        try candidate.validate()
        self = candidate
    }

    public mutating func moveRack(rackID: ObjectID, to locationID: ObjectID) throws {
        guard let index = racks.firstIndex(where: { $0.id == rackID }) else { throw HierarchyValidationError.missingObject(rackID) }
        guard racks[index].deletedAt == nil else { throw HierarchyValidationError.deletedObject(rackID) }
        var candidate = self
        candidate.racks[index].locationID = locationID
        try candidate.validate()
        self = candidate
    }

    public mutating func softDelete(_ objectID: ObjectID, at deletedAt: Date) throws {
        let hasLiveChild =
            locations.contains { $0.parentID == objectID && $0.deletedAt == nil }
            || racks.contains { $0.locationID == objectID && $0.deletedAt == nil }
        guard !hasLiveChild else { throw HierarchyValidationError.cannotDeleteWithLiveChildren(objectID) }
        var candidate = self
        if let index = candidate.locations.firstIndex(where: { $0.id == objectID }) {
            candidate.locations[index].deletedAt = deletedAt
        } else if let index = candidate.racks.firstIndex(where: { $0.id == objectID }) {
            candidate.racks[index].deletedAt = deletedAt
        } else {
            throw HierarchyValidationError.missingObject(objectID)
        }
        try candidate.validate()
        self = candidate
    }

    public mutating func addTombstone(_ tombstone: HierarchyTombstone) throws {
        var candidate = self
        candidate.tombstones.append(tombstone)
        try candidate.validate()
        self = candidate
    }
}
