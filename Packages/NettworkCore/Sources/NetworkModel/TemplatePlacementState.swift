import Foundation

public struct RackPlacementReservation: Codable, Hashable, Sendable, Identifiable {
    public let id: ObjectID
    public var rackID: ObjectID
    public var startRU: Int
    public var heightRU: Int
    public var face: RackPlacement.Face

    public init(id: ObjectID = .init(), rackID: ObjectID, startRU: Int, heightRU: Int, face: RackPlacement.Face) {
        self.id = id
        self.rackID = rackID
        self.startRU = startRU
        self.heightRU = heightRU
        self.face = face
    }
}

public enum TemplatePlacementValidationError: Error, Hashable, Sendable {
    case duplicatePlacement(ObjectID)
    case missingDevice(ObjectID)
    case missingRack(ObjectID)
    case deletedRack(ObjectID)
    case invalidRackHeight(ObjectID)
    case deviceRackMismatch(ObjectID)
    case deviceHeightMismatch(ObjectID)
    case rackOverlap(rackID: ObjectID, face: RackPlacement.Face, firstID: ObjectID, secondID: ObjectID)
    case duplicateRackReservation(ObjectID)
    case invalidRackReservation(ObjectID)
    case duplicateAnchor(ObjectID)
    case duplicateAnchoredObject(ObjectID)
    case missingFloor(ObjectID)
    case invalidFloor(ObjectID)
    case invalidAnchorCoordinate(ObjectID)
    case unknownAnchoredObject(ObjectID)
    case anchorOwnershipMismatch(anchorID: ObjectID, expectedFloorID: ObjectID, actualFloorID: ObjectID)
    case deviceHasPlacement(ObjectID)
    case deviceHasAnchor(ObjectID)
}

private struct RackElevation: Comparable {
    var rackID: ObjectID
    var face: RackPlacement.Face
    var startRU: Int
    var endRU: Int
    var id: ObjectID

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.rackID != rhs.rackID { return lhs.rackID < rhs.rackID }
        if lhs.face != rhs.face { return lhs.face.rawValue < rhs.face.rawValue }
        if lhs.startRU != rhs.startRU { return lhs.startRU < rhs.startRU }
        if lhs.endRU != rhs.endRU { return lhs.endRU < rhs.endRU }
        return lhs.id < rhs.id
    }
}

/// The D03 aggregate joins the hierarchy and graph without weakening either
/// D01 or D02's independent validation contracts.
public struct TemplatePlacementState: Codable, Hashable, Sendable {
    public var hierarchy: WorkspaceHierarchy
    public var topology: PhysicalTopology
    public var placements: [RackPlacement]
    public var rackReservations: [RackPlacementReservation]
    public var anchors: [FloorPlanAnchor]

    public init(
        hierarchy: WorkspaceHierarchy, topology: PhysicalTopology, placements: [RackPlacement] = [], rackReservations: [RackPlacementReservation] = [],
        anchors: [FloorPlanAnchor] = []
    ) {
        self.hierarchy = hierarchy
        self.topology = topology
        self.placements = placements
        self.rackReservations = rackReservations
        self.anchors = anchors
    }

    public func validate() throws {
        try hierarchy.validate()
        try DefaultTopologyEngine.validate(topology)
        let liveRacks = Dictionary(uniqueKeysWithValues: hierarchy.racks.filter { $0.deletedAt == nil }.map { ($0.id, $0) })
        let devices = Dictionary(uniqueKeysWithValues: topology.devices.map { ($0.id, $0) })
        try validateRackHeights(liveRacks)
        let placementsByDevice = try validatePlacements(liveRacks: liveRacks, devices: devices)
        try validatePlacedDevices(devices, placementIDs: placementsByDevice)
        try validateReservations(liveRacks)
        try validateOverlaps(liveRacks: liveRacks)
        try validateAnchors(liveRacks: liveRacks, devices: devices)
    }

    private func validateRackHeights(_ racks: [ObjectID: Rack]) throws {
        for rack in racks.values where rack.heightRU <= 0 { throw TemplatePlacementValidationError.invalidRackHeight(rack.id) }
    }

    private func validatePlacements(liveRacks: [ObjectID: Rack], devices: [ObjectID: Device]) throws -> Set<ObjectID> {
        var placementIDs = Set<ObjectID>()
        for placement in placements {
            guard placementIDs.insert(placement.deviceID).inserted else { throw TemplatePlacementValidationError.duplicatePlacement(placement.deviceID) }
            try validate(placement: placement, liveRacks: liveRacks, devices: devices)
        }
        return placementIDs
    }

    private func validate(placement: RackPlacement, liveRacks: [ObjectID: Rack], devices: [ObjectID: Device]) throws {
        guard let device = devices[placement.deviceID] else { throw TemplatePlacementValidationError.missingDevice(placement.deviceID) }
        let rack = try liveRack(placement.rackID)
        guard device.rackID == rack.id else { throw TemplatePlacementValidationError.deviceRackMismatch(device.id) }
        try DefaultTopologyEngine.validate(placement, in: rack)
        guard placement.heightRU == rackHeight(for: device) else { throw TemplatePlacementValidationError.deviceHeightMismatch(device.id) }
        _ = liveRacks
    }

    private func liveRack(_ rackID: ObjectID) throws -> Rack {
        if let rack = hierarchy.racks.first(where: { $0.id == rackID && $0.deletedAt == nil }) { return rack }
        if hierarchy.racks.contains(where: { $0.id == rackID }) { throw TemplatePlacementValidationError.deletedRack(rackID) }
        throw TemplatePlacementValidationError.missingRack(rackID)
    }

    private func validatePlacedDevices(_ devices: [ObjectID: Device], placementIDs: Set<ObjectID>) throws {
        for device in devices.values where device.rackID != nil && !placementIDs.contains(device.id) {
            throw TemplatePlacementValidationError.deviceRackMismatch(device.id)
        }
    }

    private func validateReservations(_ liveRacks: [ObjectID: Rack]) throws {
        var reservationIDs = Set<ObjectID>()
        for reservation in rackReservations {
            guard reservationIDs.insert(reservation.id).inserted else { throw TemplatePlacementValidationError.duplicateRackReservation(reservation.id) }
            try validate(reservation: reservation, liveRacks: liveRacks)
        }
    }

    private func validate(reservation: RackPlacementReservation, liveRacks: [ObjectID: Rack]) throws {
        guard let rack = liveRacks[reservation.rackID] else { throw TemplatePlacementValidationError.invalidRackReservation(reservation.id) }
        let placement = RackPlacement(
            deviceID: reservation.id, rackID: reservation.rackID, startRU: reservation.startRU, heightRU: reservation.heightRU, face: reservation.face)
        do { try DefaultTopologyEngine.validate(placement, in: rack) } catch { throw TemplatePlacementValidationError.invalidRackReservation(reservation.id) }
    }

    public mutating func place(_ placement: RackPlacement) throws {
        var candidate = self
        guard let index = candidate.topology.devices.firstIndex(where: { $0.id == placement.deviceID }) else {
            throw TemplatePlacementValidationError.missingDevice(placement.deviceID)
        }
        candidate.topology.devices[index].rackID = placement.rackID
        candidate.placements.removeAll { $0.deviceID == placement.deviceID }
        candidate.placements.append(placement)
        try candidate.validate()
        self = candidate
    }

    public mutating func removePlacement(for deviceID: ObjectID) throws {
        var candidate = self
        guard let index = candidate.topology.devices.firstIndex(where: { $0.id == deviceID }) else {
            throw TemplatePlacementValidationError.missingDevice(deviceID)
        }
        candidate.placements.removeAll { $0.deviceID == deviceID }
        candidate.topology.devices[index].rackID = nil
        try candidate.validate()
        self = candidate
    }

    public mutating func reserve(_ reservation: RackPlacementReservation) throws {
        var candidate = self
        candidate.rackReservations.append(reservation)
        try candidate.validate()
        self = candidate
    }

    public mutating func addAnchor(_ anchor: FloorPlanAnchor) throws {
        var candidate = self
        candidate.anchors.append(anchor)
        try candidate.validate()
        self = candidate
    }

    /// A topology deletion is rejected while it would strand D03 placement or
    /// floor-plan records. The caller must deliberately remove those records
    /// first, then use the existing D02 deletion command.
    public func validateDeviceDeletion(_ deviceID: ObjectID) throws {
        guard !placements.contains(where: { $0.deviceID == deviceID }) else { throw TemplatePlacementValidationError.deviceHasPlacement(deviceID) }
        guard !anchors.contains(where: { $0.objectID == deviceID }) else { throw TemplatePlacementValidationError.deviceHasAnchor(deviceID) }
    }

    private func rackHeight(for device: Device) -> Int {
        device.templateSnapshot?.rackHeightRU
            ?? topology.deviceTypes.first(where: { $0.id == device.typeID })?.rackHeightRU
            ?? 1
    }

    private func validateOverlaps(liveRacks: [ObjectID: Rack]) throws {
        var elevations = placements.map {
            RackElevation(rackID: $0.rackID, face: $0.face, startRU: $0.startRU, endRU: $0.startRU + $0.heightRU - 1, id: $0.deviceID)
        }
        elevations += rackReservations.map {
            RackElevation(rackID: $0.rackID, face: $0.face, startRU: $0.startRU, endRU: $0.startRU + $0.heightRU - 1, id: $0.id)
        }
        var furthestByElevation: [String: RackElevation] = [:]
        for current in elevations.sorted() {
            let key = "\(current.rackID.description):\(current.face.rawValue)"
            if let previous = furthestByElevation[key], current.startRU <= previous.endRU {
                throw TemplatePlacementValidationError.rackOverlap(rackID: current.rackID, face: current.face, firstID: previous.id, secondID: current.id)
            }
            if furthestByElevation[key]?.endRU ?? Int.min < current.endRU {
                furthestByElevation[key] = current
            }
        }
        _ = liveRacks
    }

    private func validateAnchors(liveRacks: [ObjectID: Rack], devices: [ObjectID: Device]) throws {
        let locations = Dictionary(uniqueKeysWithValues: hierarchy.locations.filter { $0.deletedAt == nil }.map { ($0.id, $0) })
        var anchorIDs = Set<ObjectID>()
        var anchoredObjectIDs = Set<ObjectID>()
        for anchor in anchors {
            try validate(anchor: anchor, locations: locations, racks: liveRacks, devices: devices, anchorIDs: &anchorIDs, objectIDs: &anchoredObjectIDs)
        }
    }

    private func validate(
        anchor: FloorPlanAnchor, locations: [ObjectID: Location], racks: [ObjectID: Rack], devices: [ObjectID: Device], anchorIDs: inout Set<ObjectID>,
        objectIDs: inout Set<ObjectID>
    ) throws {
        guard anchorIDs.insert(anchor.id).inserted else { throw TemplatePlacementValidationError.duplicateAnchor(anchor.id) }
        guard objectIDs.insert(anchor.objectID).inserted else { throw TemplatePlacementValidationError.duplicateAnchoredObject(anchor.objectID) }
        try validateAnchorCoordinate(anchor)
        try validateFloor(anchor.floorID, locations: locations)
        let owningFloorID = try owningFloor(for: anchor.objectID, locations: locations, racks: racks, devices: devices)
        guard owningFloorID == anchor.floorID else {
            throw TemplatePlacementValidationError.anchorOwnershipMismatch(anchorID: anchor.id, expectedFloorID: owningFloorID, actualFloorID: anchor.floorID)
        }
    }

    private func validateAnchorCoordinate(_ anchor: FloorPlanAnchor) throws {
        guard anchor.x.isFinite, anchor.y.isFinite, (0...1).contains(anchor.x), (0...1).contains(anchor.y) else {
            throw TemplatePlacementValidationError.invalidAnchorCoordinate(anchor.id)
        }
    }

    private func validateFloor(_ floorID: ObjectID, locations: [ObjectID: Location]) throws {
        guard let floor = locations[floorID] else { throw TemplatePlacementValidationError.missingFloor(floorID) }
        guard floor.kind == .floor else { throw TemplatePlacementValidationError.invalidFloor(floorID) }
    }

    private func owningFloor(for objectID: ObjectID, locations: [ObjectID: Location], racks: [ObjectID: Rack], devices: [ObjectID: Device]) throws -> ObjectID {
        if let location = locations[objectID] { return try floorID(for: location, locations: locations) }
        if let rack = racks[objectID] { return try owningFloor(for: rack, locations: locations) }
        if let device = devices[objectID] { return try owningFloor(for: device, locations: locations, racks: racks) }
        throw TemplatePlacementValidationError.unknownAnchoredObject(objectID)
    }

    private func owningFloor(for rack: Rack, locations: [ObjectID: Location]) throws -> ObjectID {
        guard let room = locations[rack.locationID] else { throw TemplatePlacementValidationError.unknownAnchoredObject(rack.id) }
        return try floorID(for: room, locations: locations)
    }

    private func owningFloor(for device: Device, locations: [ObjectID: Location], racks: [ObjectID: Rack]) throws -> ObjectID {
        guard let rackID = placements.first(where: { $0.deviceID == device.id })?.rackID ?? device.rackID,
            let rack = racks[rackID]
        else { throw TemplatePlacementValidationError.unknownAnchoredObject(device.id) }
        return try owningFloor(for: rack, locations: locations)
    }

    private func floorID(for location: Location, locations: [ObjectID: Location]) throws -> ObjectID {
        var current = location
        while current.kind != .floor {
            guard let parentID = current.parentID, let parent = locations[parentID] else {
                throw TemplatePlacementValidationError.unknownAnchoredObject(location.id)
            }
            current = parent
        }
        return current.id
    }
}
