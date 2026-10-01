import NetworkModel
import WorkspaceChangeControl

extension SwiftDataProductionMutationPlanner {
    func applyHierarchy(_ operation: PlannedHierarchyOperation, snapshot: inout Snapshot, changes: inout ChangeAccumulator) throws {
        switch operation {
        case .upsertLocation(let location):
            try upsertLocation(location, snapshot: &snapshot, changes: &changes)
        case .removeLocation(let location):
            try removeLocation(location, snapshot: &snapshot, changes: &changes)
        case .upsertRack(let rack):
            try upsertRack(rack, snapshot: &snapshot, changes: &changes)
        case .removeRack(let rack):
            try removeRack(rack, snapshot: &snapshot, changes: &changes)
        }
    }

    private func upsertLocation(_ location: Location, snapshot: inout Snapshot, changes: inout ChangeAccumulator) throws {
        guard location.deletedAt == nil else {
            throw ProductionMutationPlannerError.invalidHierarchyOperation
        }
        var candidate = snapshot.hierarchy
        if let index = candidate.locations.firstIndex(where: { $0.id == location.id }) {
            guard candidate.locations[index].deletedAt == nil else {
                throw ProductionMutationPlannerError.invalidHierarchyOperation
            }
            candidate.locations[index] = location
        } else {
            candidate.locations.append(location)
        }
        try candidate.validate()
        snapshot.hierarchy = candidate
        try changes.save(location, recordType: WorkspaceRecordType.Legacy.location)
        try saveHierarchyParent(location.parentID, snapshot: snapshot, changes: &changes)
    }

    private func removeLocation(_ location: Location, snapshot: inout Snapshot, changes: inout ChangeAccumulator) throws {
        guard snapshot.hierarchy.locations.first(where: { $0.id == location.id }) == location,
            location.deletedAt == nil
        else {
            throw ProductionMutationPlannerError.missingHierarchyObject(.object(location.id))
        }
        var candidate = snapshot.hierarchy
        try candidate.softDelete(location.id, at: changes.deletedAt)
        guard let deleted = candidate.locations.first(where: { $0.id == location.id }) else {
            throw ProductionMutationPlannerError.missingHierarchyObject(.object(location.id))
        }
        snapshot.hierarchy = candidate
        try changes.save(deleted, recordType: WorkspaceRecordType.Legacy.location)
        try saveHierarchyParent(location.parentID, snapshot: snapshot, changes: &changes)
    }

    private func upsertRack(_ rack: Rack, snapshot: inout Snapshot, changes: inout ChangeAccumulator) throws {
        guard rack.deletedAt == nil else {
            throw ProductionMutationPlannerError.invalidHierarchyOperation
        }
        var candidate = snapshot.hierarchy
        if let index = candidate.racks.firstIndex(where: { $0.id == rack.id }) {
            guard candidate.racks[index].deletedAt == nil else {
                throw ProductionMutationPlannerError.invalidHierarchyOperation
            }
            candidate.racks[index] = rack
        } else {
            candidate.racks.append(rack)
        }
        try candidate.validate()
        snapshot.hierarchy = candidate
        try changes.save(rack, recordType: WorkspaceRecordType.Legacy.rack)
        try saveHierarchyParent(rack.locationID, snapshot: snapshot, changes: &changes)
    }

    private func removeRack(_ rack: Rack, snapshot: inout Snapshot, changes: inout ChangeAccumulator) throws {
        guard snapshot.hierarchy.racks.first(where: { $0.id == rack.id }) == rack,
            rack.deletedAt == nil
        else {
            throw ProductionMutationPlannerError.missingHierarchyObject(.object(rack.id))
        }
        var candidate = snapshot.hierarchy
        try candidate.softDelete(rack.id, at: changes.deletedAt)
        guard let deleted = candidate.racks.first(where: { $0.id == rack.id }) else {
            throw ProductionMutationPlannerError.missingHierarchyObject(.object(rack.id))
        }
        snapshot.hierarchy = candidate
        try changes.save(deleted, recordType: WorkspaceRecordType.Legacy.rack)
        try saveHierarchyParent(rack.locationID, snapshot: snapshot, changes: &changes)
    }

    func saveHierarchyParent(_ parentID: ObjectID?, snapshot: Snapshot, changes: inout ChangeAccumulator) throws {
        guard let parentID else { return }
        guard
            let parent = snapshot.hierarchy.locations.first(where: {
                $0.id == parentID && $0.deletedAt == nil
            })
        else {
            throw ProductionMutationPlannerError.missingHierarchyObject(.object(parentID))
        }
        try changes.save(parent, recordType: WorkspaceRecordType.Legacy.location)
    }
}
