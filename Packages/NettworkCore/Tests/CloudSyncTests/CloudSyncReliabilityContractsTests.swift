import CloudSync
import Foundation
import NetworkModel
import Testing
import WorkspaceChangeControl

@Test func telemetryEventContainsOnlyAggregateValues() {
    let event = PrivacySafeSyncTelemetryEvent(
        operation: .synchronize,
        outcome: .failed,
        recordCount: 12,
        assetCount: 3,
        queueDepth: 5,
        oldestQueuedAgeSeconds: 90,
        quarantineCount: 2,
        conflictCount: 1,
        quotaExceededFailureCount: 1,
        lastSuccessfulServerContactAgeSeconds: 15,
        externalQuota: .reported(usedBytes: 40, limitBytes: 100),
        externalBackupAge: .reported(ageSeconds: 3_600),
        failureCategory: .networkFlap
    )

    #expect(event.recordCount == 12)
    #expect(event.failureCategory == .networkFlap)
    #expect(event.oldestQueuedAgeSeconds == 90)
    #expect(event.quarantineCount == 2)
    #expect(event.conflictCount == 1)
    #expect(event.quotaExceededFailureCount == 1)
    #expect(event.lastSuccessfulServerContactAgeSeconds == 15)
    #expect(event.externalQuota.reportedBytes?.used == 40)
    #expect(event.externalBackupAge.seconds == 3_600)
}

@Test func telemetryRetentionStoreEnforcesConfiguredAgeAndCount() {
    let retention = SyncTelemetryRetentionPolicy(maximumEventAgeSeconds: 10, maximumEventCount: 2)
    let store = BoundedPrivacySafeSyncTelemetryStore(retention: retention)
    let event = PrivacySafeSyncTelemetryEvent(
        operation: .synchronize,
        outcome: .succeeded,
        recordCount: 0,
        assetCount: 0,
        queueDepth: 0
    )
    let start = Date(timeIntervalSinceReferenceDate: 10_000)
    let mismatchedRetention = SyncTelemetryRetentionPolicy(maximumEventAgeSeconds: 5, maximumEventCount: 1)

    store.record(event, retention: mismatchedRetention, emittedAt: start)
    store.record(event, retention: retention, emittedAt: start)
    store.record(event, retention: retention, emittedAt: start.addingTimeInterval(1))
    store.record(event, retention: retention, emittedAt: start.addingTimeInterval(2))

    let countBounded = store.events(asOf: start.addingTimeInterval(2))
    #expect(countBounded.count == 2)
    #expect(countBounded.map(\.emittedAt) == [start.addingTimeInterval(1), start.addingTimeInterval(2)])

    let ageBounded = store.events(asOf: start.addingTimeInterval(13))
    #expect(ageBounded.isEmpty)
}
