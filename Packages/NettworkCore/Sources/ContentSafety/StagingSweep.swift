import Foundation

/// Launch-time recovery for staging that an app kill left behind. Only
/// app-created staging units carry the marker file, and only marked units are
/// ever selected, so nothing else below a staging root can be removed.
/// Selection is pure; deletion runs through an injected closure.
public enum StagingSweep {
    public static let markerName = ".nettwork-staging"

    /// What one staging root holds.
    public enum Layout: Sendable {
        /// Each direct child directory is one short-lived staging unit.
        case unitDirectories
        /// Each direct child directory is a long-lived marked namespace; its
        /// regular files are the staging units. The directory itself stays.
        case filesInNamespaceDirectories
    }

    /// Writes the marker into a directory the app just created.
    public static func markDirectory(_ directory: URL, fileManager: FileManager = .default) throws {
        let marker = directory.appendingPathComponent(markerName, isDirectory: false)
        guard !fileManager.fileExists(atPath: marker.path) else { return }
        guard fileManager.createFile(atPath: marker.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Returns the expired, marked items below `root`. Never returns `root`,
    /// symlinks, unmarked directories, or anything deeper than the layout allows.
    public static func victims(
        in root: URL, layout: Layout, now: Date, lifetime: TimeInterval,
        fileManager: FileManager = .default
    ) -> [URL] {
        let cutoff = now.addingTimeInterval(-lifetime)
        let directories = children(of: root, fileManager: fileManager).filter(isMarkedDirectory)
        switch layout {
        case .unitDirectories:
            return directories.filter { isOlder($0, than: cutoff) }
        case .filesInNamespaceDirectories:
            return directories.flatMap { children(of: $0, fileManager: fileManager) }
                .filter { $0.lastPathComponent != markerName && isRegularFile($0) && isOlder($0, than: cutoff) }
        }
    }

    /// Removes every victim through `remove`. Failures never stop the sweep;
    /// they are returned for the caller to log.
    @discardableResult
    public static func sweep(
        root: URL, layout: Layout, now: Date, lifetime: TimeInterval,
        fileManager: FileManager = .default, remove: (URL) throws -> Void
    ) -> [Error] {
        var failures: [Error] = []
        for victim in victims(in: root, layout: layout, now: now, lifetime: lifetime, fileManager: fileManager) {
            do { try remove(victim) } catch { failures.append(error) }
        }
        return failures
    }

    private static func children(of directory: URL, fileManager: FileManager) -> [URL] {
        (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    private static func isMarkedDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
            values.isDirectory == true, values.isSymbolicLink != true
        else { return false }
        return isRegularFile(url.appendingPathComponent(markerName, isDirectory: false))
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func isOlder(_ url: URL, than cutoff: Date) -> Bool {
        guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return false }
        return modified < cutoff
    }
}
