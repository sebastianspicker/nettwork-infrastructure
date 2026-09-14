import Foundation
import NetworkModel
import WorkspaceChangeControl

/// This schema intentionally accepts only aggregate quantities, bounded ages,
/// and enumerated categories. It has no fields capable of holding customer
/// payloads, display labels, network addresses, identities, or record keys.
public enum PrivacySafeSyncTelemetryOutcome: String, Codable, Hashable, Sendable {
    case started
    case succeeded
    case failed
    case cancelled
}

public enum PrivacySafeSyncTelemetryFailureCategory: String, Codable, Hashable, Sendable {
    case lowStorage
    case memoryPressure
    case networkFlap
    case rateLimited
    case assetUnavailable
    case corruptMirror
    case rebuild
    case accountUnavailable
    case permissionDenied
    case validation
    case conflict
    case malformedRemoteRecord
    case quotaExceeded
    case security
    case unknown
}

/// This distinguishes an unavailable organization-owned quota source from a
/// reported aggregate. It never represents a locally inferred quota balance.
public enum PrivacySafeSyncTelemetryExternalQuota: Codable, Hashable, Sendable {
    case unavailable
    case reported(usedBytes: Int, limitBytes: Int)

    public var reportedBytes: (used: Int, limit: Int)? {
        guard case let .reported(usedBytes, limitBytes) = self else { return nil }
        return (usedBytes, limitBytes)
    }
}

/// The local Cloud mirror is not a backup authority. A backup age is therefore
/// unavailable until an organization-owned backup system reports it explicitly.
public enum PrivacySafeSyncTelemetryExternalBackupAge: Codable, Hashable, Sendable {
    case unavailable
    case reported(ageSeconds: Int)

    public var seconds: Int? {
        guard case let .reported(ageSeconds) = self else { return nil }
        return ageSeconds
    }
}

public struct PrivacySafeSyncTelemetryExternalSignals: Codable, Hashable, Sendable {
    public let quota: PrivacySafeSyncTelemetryExternalQuota
    public let backupAge: PrivacySafeSyncTelemetryExternalBackupAge

    public init(
        quota: PrivacySafeSyncTelemetryExternalQuota = .unavailable,
        backupAge: PrivacySafeSyncTelemetryExternalBackupAge = .unavailable
    ) {
        if case let .reported(usedBytes, limitBytes) = quota {
            precondition(usedBytes >= 0 && limitBytes >= 0, "Reported quota must be a non-negative aggregate.")
        }
        precondition(backupAge.seconds.map { $0 >= 0 } ?? true, "Reported backup age cannot be negative.")
        self.quota = quota
        self.backupAge = backupAge
    }

    public static let unavailable = Self()
}

/// Deployment composition must inject a provider when it has an external
/// quota or backup authority. The default provider is intentionally unknown,
/// rather than manufacturing a healthy or zero-valued external metric.
public protocol PrivacySafeSyncTelemetryExternalSignalProviding: Sendable {
    func currentSignals() async -> PrivacySafeSyncTelemetryExternalSignals
}

public struct UnavailablePrivacySafeSyncTelemetryExternalSignalProvider: PrivacySafeSyncTelemetryExternalSignalProviding {
    public init() {}

    public func currentSignals() async -> PrivacySafeSyncTelemetryExternalSignals {
        .unavailable
    }
}

public struct PrivacySafeSyncTelemetryEvent: Codable, Hashable, Sendable {
    public let operation: BoundedOperationKind
    public let outcome: PrivacySafeSyncTelemetryOutcome
    public let recordCount: Int
    public let assetCount: Int
    public let queueDepth: Int
    public let oldestQueuedAgeSeconds: Int?
    public let quarantineCount: Int?
    public let conflictCount: Int?
    public let quotaExceededFailureCount: Int?
    public let lastSuccessfulServerContactAgeSeconds: Int?
    public let externalQuota: PrivacySafeSyncTelemetryExternalQuota
    public let externalBackupAge: PrivacySafeSyncTelemetryExternalBackupAge
    public let failureCategory: PrivacySafeSyncTelemetryFailureCategory?

    public init(
        operation: BoundedOperationKind, outcome: PrivacySafeSyncTelemetryOutcome, recordCount: Int,
        assetCount: Int, queueDepth: Int, oldestQueuedAgeSeconds: Int? = nil, quarantineCount: Int? = nil,
        conflictCount: Int? = nil, quotaExceededFailureCount: Int? = nil,
        lastSuccessfulServerContactAgeSeconds: Int? = nil,
        externalQuota: PrivacySafeSyncTelemetryExternalQuota = .unavailable,
        externalBackupAge: PrivacySafeSyncTelemetryExternalBackupAge = .unavailable,
        failureCategory: PrivacySafeSyncTelemetryFailureCategory? = nil
    ) {
        precondition(recordCount >= 0 && assetCount >= 0 && queueDepth >= 0, "Telemetry counts cannot be negative.")
        precondition(oldestQueuedAgeSeconds.map { $0 >= 0 } ?? true, "Telemetry age cannot be negative.")
        precondition(
            [quarantineCount, conflictCount, quotaExceededFailureCount].allSatisfy { $0.map { $0 >= 0 } ?? true },
            "Telemetry aggregate counts cannot be negative.")
        precondition(lastSuccessfulServerContactAgeSeconds.map { $0 >= 0 } ?? true, "Server-contact age cannot be negative.")
        _ = PrivacySafeSyncTelemetryExternalSignals(quota: externalQuota, backupAge: externalBackupAge)
        self.operation = operation
        self.outcome = outcome
        self.recordCount = recordCount
        self.assetCount = assetCount
        self.queueDepth = queueDepth
        self.oldestQueuedAgeSeconds = oldestQueuedAgeSeconds
        self.quarantineCount = quarantineCount
        self.conflictCount = conflictCount
        self.quotaExceededFailureCount = quotaExceededFailureCount
        self.lastSuccessfulServerContactAgeSeconds = lastSuccessfulServerContactAgeSeconds
        self.externalQuota = externalQuota
        self.externalBackupAge = externalBackupAge
        self.failureCategory = failureCategory
    }
}

/// The application owns retention selection and passes it into its telemetry
/// sink. There is deliberately no implicit product retention value here.
public struct SyncTelemetryRetentionPolicy: Codable, Hashable, Sendable {
    public let maximumEventAgeSeconds: Int
    public let maximumEventCount: Int

    public init(maximumEventAgeSeconds: Int, maximumEventCount: Int) {
        precondition(maximumEventAgeSeconds > 0 && maximumEventCount > 0, "Retention limits must be positive.")
        self.maximumEventAgeSeconds = maximumEventAgeSeconds
        self.maximumEventCount = maximumEventCount
    }
}

public protocol PrivacySafeSyncTelemetryMetricsStoring: Sendable {
    func record(_ event: PrivacySafeSyncTelemetryEvent, retention: SyncTelemetryRetentionPolicy)
}

public struct RetainedPrivacySafeSyncTelemetryEvent: Codable, Hashable, Sendable {
    public let emittedAt: Date
    public let event: PrivacySafeSyncTelemetryEvent

    public init(emittedAt: Date, event: PrivacySafeSyncTelemetryEvent) {
        self.emittedAt = emittedAt
        self.event = event
    }
}

/// An in-process metrics store with enforced age and count limits. It is not a
/// durable backup or audit store; deployments needing durable metrics must
/// inject their own `PrivacySafeSyncTelemetryMetricsStoring` implementation.
public final class BoundedPrivacySafeSyncTelemetryStore: PrivacySafeSyncTelemetryMetricsStoring, @unchecked Sendable {
    private let configuredRetention: SyncTelemetryRetentionPolicy
    private var retainedEvents: [RetainedPrivacySafeSyncTelemetryEvent] = []
    private let lock = NSLock()

    public init(retention: SyncTelemetryRetentionPolicy) {
        self.configuredRetention = retention
    }

    public func record(_ event: PrivacySafeSyncTelemetryEvent, retention: SyncTelemetryRetentionPolicy) {
        record(event, retention: retention, emittedAt: .now)
    }

    public func record(
        _ event: PrivacySafeSyncTelemetryEvent, retention: SyncTelemetryRetentionPolicy,
        emittedAt: Date
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard retention == configuredRetention else { return }
        retainedEvents.append(RetainedPrivacySafeSyncTelemetryEvent(emittedAt: emittedAt, event: event))
        enforceRetention(asOf: emittedAt)
    }

    public func events(asOf now: Date = .now) -> [RetainedPrivacySafeSyncTelemetryEvent] {
        lock.lock()
        defer { lock.unlock() }
        enforceRetention(asOf: now)
        return retainedEvents
    }

    private func enforceRetention(asOf now: Date) {
        let oldestPermitted = now.addingTimeInterval(-Double(configuredRetention.maximumEventAgeSeconds))
        retainedEvents.removeAll { $0.emittedAt < oldestPermitted }
        retainedEvents.sort { $0.emittedAt < $1.emittedAt }
        let excess = retainedEvents.count - configuredRetention.maximumEventCount
        if excess > 0 {
            retainedEvents.removeFirst(excess)
        }
    }
}

public protocol PrivacySafeSyncTelemetryEmitting: Sendable {
    func emit(_ event: PrivacySafeSyncTelemetryEvent, retention: SyncTelemetryRetentionPolicy)
}

/// Scenarios available to an organization-run synchronization resilience exercise.
public enum SyncFailureInjectionScenario: String, CaseIterable, Codable, Hashable, Sendable {
    case lowStorage
    case memoryPressure
    case networkFlap
    case rateLimit
    case assetUnavailable
    case corruptMirror
    case rebuild

    public var telemetryCategory: PrivacySafeSyncTelemetryFailureCategory {
        switch self {
        case .lowStorage: .lowStorage
        case .memoryPressure: .memoryPressure
        case .networkFlap: .networkFlap
        case .rateLimit: .rateLimited
        case .assetUnavailable: .assetUnavailable
        case .corruptMirror: .corruptMirror
        case .rebuild: .rebuild
        }
    }
}

/// A deterministic fault plan supplied explicitly by a resilience harness.
public struct SyncFailureInjectionPlan: Codable, Hashable, Sendable {
    public let scenario: SyncFailureInjectionScenario
    public let failingAttempt: Int

    public init(scenario: SyncFailureInjectionScenario, failingAttempt: Int = 1) {
        precondition(failingAttempt > 0, "Injected failure attempts start at one.")
        self.scenario = scenario
        self.failingAttempt = failingAttempt
    }

    public func shouldFail(attempt: Int) -> Bool {
        attempt == failingAttempt
    }
}

public protocol SyncFailureInjecting: Sendable {
    func failurePlan(for operation: BoundedOperationKind) -> SyncFailureInjectionPlan?
}
