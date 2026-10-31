import Foundation

extension InventoryHistoryStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .corruptHistory, .unsupportedFormatVersion, .historyTooLarge:
            "Your saved favorites and recent items could not be read. They start empty, and the damaged file is kept aside."
        case .readFailed:
            "Your saved favorites and recent items could not be loaded from this device."
        case .writeFailed:
            "Your favorites and recent items could not be saved on this device. They stay available until you close the app."
        case .favoriteLimitReached(let limit):
            "You can save up to \(limit) favorites. Remove one to add another."
        }
    }
}
