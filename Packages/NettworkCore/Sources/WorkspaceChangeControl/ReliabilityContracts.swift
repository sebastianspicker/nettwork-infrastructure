import Foundation
import NetworkModel

/// Work categories that must expose cancellation and an explicit concurrency limit.
public enum BoundedOperationKind: String, CaseIterable, Codable, Hashable, Sendable {
    case search
    case workspaceImport
    case workspaceExport
    case assetTransfer
    case synchronize
    case accountLifecycle
    case outboxReplay
    case conflictHandling
    case quarantine
    case quotaHealth
    case backupHealth
    case reportGeneration
}

/// An injected execution limit. Product composition chooses the value; this
/// contract intentionally supplies no product-wide default.
public struct BoundedOperationPolicy: Codable, Hashable, Sendable {
    public let operation: BoundedOperationKind
    public let maximumConcurrentOperations: Int
    public let cancellationCheckInterval: Int

    public init(operation: BoundedOperationKind, maximumConcurrentOperations: Int, cancellationCheckInterval: Int) {
        precondition(maximumConcurrentOperations > 0, "A bounded operation requires positive concurrency.")
        precondition(cancellationCheckInterval > 0, "Cancellation must be checked at a positive interval.")
        self.operation = operation
        self.maximumConcurrentOperations = maximumConcurrentOperations
        self.cancellationCheckInterval = cancellationCheckInterval
    }
}

public enum CooperativeCancellation {
    public static func check() throws {
        try Task.checkCancellation()
    }
}

/// A small, ordered helper for callers that have already selected an injected
/// `BoundedOperationPolicy`. The closure is responsible for additional checks
/// inside long-running individual items.
public enum BoundedOperationExecutor {
    public static func perform<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        policy: BoundedOperationPolicy, operation: @escaping @Sendable (Input) async throws -> Output
    ) async throws -> [Output] {
        guard !inputs.isEmpty else { return [] }
        var results = Array<Output?>(repeating: nil, count: inputs.count)
        var nextIndex = 0

        try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            try CooperativeCancellation.check()
            let initialCount = min(policy.maximumConcurrentOperations, inputs.count)
            for index in 0..<initialCount {
                if index.isMultiple(of: policy.cancellationCheckInterval) {
                    try CooperativeCancellation.check()
                }
                group.addTask { (index, try await operation(inputs[index])) }
                nextIndex = index + 1
            }

            while let (index, output) = try await group.next() {
                results[index] = output
                if index.isMultiple(of: policy.cancellationCheckInterval) {
                    try CooperativeCancellation.check()
                }
                if nextIndex < inputs.count {
                    let scheduledIndex = nextIndex
                    if scheduledIndex.isMultiple(of: policy.cancellationCheckInterval) {
                        try CooperativeCancellation.check()
                    }
                    group.addTask { (scheduledIndex, try await operation(inputs[scheduledIndex])) }
                    nextIndex += 1
                }
            }
        }

        return results.compactMap { $0 }
    }
}

/// A requirement supplied by a caller or deployment policy, not evidence that a target
/// has been achieved.
public struct OperationPerformanceBudget: Codable, Hashable, Sendable {
    public let operation: BoundedOperationKind
    public let maximumWallClockMilliseconds: Int
    public let maximumPeakResidentBytes: Int?

    public init(operation: BoundedOperationKind, maximumWallClockMilliseconds: Int, maximumPeakResidentBytes: Int? = nil) {
        precondition(maximumWallClockMilliseconds > 0, "A performance budget requires a positive wall-clock limit.")
        precondition(maximumPeakResidentBytes.map { $0 > 0 } ?? true, "A memory budget must be positive when supplied.")
        self.operation = operation
        self.maximumWallClockMilliseconds = maximumWallClockMilliseconds
        self.maximumPeakResidentBytes = maximumPeakResidentBytes
    }
}

public struct OperationMeasurement: Codable, Hashable, Sendable {
    public let operation: BoundedOperationKind
    public let startedAt: Date
    public let finishedAt: Date
    public let inputRecordCount: Int
    public let outputRecordCount: Int
    public let peakResidentBytes: Int?
    public let wasCancelled: Bool

    public init(
        operation: BoundedOperationKind, startedAt: Date, finishedAt: Date, inputRecordCount: Int, outputRecordCount: Int, peakResidentBytes: Int? = nil,
        wasCancelled: Bool
    ) {
        precondition(finishedAt >= startedAt, "Measurement completion cannot precede its start.")
        precondition(inputRecordCount >= 0 && outputRecordCount >= 0, "Measured record counts cannot be negative.")
        precondition(peakResidentBytes.map { $0 >= 0 } ?? true, "Measured memory cannot be negative.")
        self.operation = operation
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.inputRecordCount = inputRecordCount
        self.outputRecordCount = outputRecordCount
        self.peakResidentBytes = peakResidentBytes
        self.wasCancelled = wasCancelled
    }

    public var wallClockMilliseconds: Int {
        Int((finishedAt.timeIntervalSince(startedAt) * 1_000).rounded(.down))
    }
}

public enum OperationBudgetEvaluation: Codable, Hashable, Sendable {
    case withinBudget
    case exceededWallClock
    case exceededResidentMemory
    case cancelled
}

public extension OperationPerformanceBudget {
    func evaluate(_ measurement: OperationMeasurement) -> OperationBudgetEvaluation {
        precondition(operation == measurement.operation, "Budgets only evaluate their matching operation.")
        if measurement.wasCancelled { return .cancelled }
        if measurement.wallClockMilliseconds > maximumWallClockMilliseconds { return .exceededWallClock }
        if let maximumPeakResidentBytes, let peakResidentBytes = measurement.peakResidentBytes, peakResidentBytes > maximumPeakResidentBytes {
            return .exceededResidentMemory
        }
        return .withinBudget
    }
}
