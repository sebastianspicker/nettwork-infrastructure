import FeatureContracts
import Foundation

extension IPAMWorkspaceModel {
    var selectedVRF: VRFSnapshot? {
        vrfs.first { $0.id == selectedVRFID }
    }

    var selectedPrefix: IPAMPrefixSnapshot? {
        prefixes.first { $0.id == selectedPrefixID }
    }

    func focus(on object: InventorySearchResult?) {
        searchText = object?.kind == .interface ? object?.title ?? "" : ""
    }
}
