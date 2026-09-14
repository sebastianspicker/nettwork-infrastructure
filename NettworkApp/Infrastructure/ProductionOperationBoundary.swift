import Foundation
import NetworkModel
import WorkspaceChangeControl

/// The organization-owned sink receives only aggregate operation metrics.
/// It never receives account, workspace, record, asset, or payload identity.
protocol PrivacySafeOperationMeasurementRecording: Sendable {
    func record(_ measurement: PrivacySafeOperationMeasurement) async
}

enum PrivacySafeOperationOutcome: String, Hashable, Sendable {
    case succeeded
    case failed
    case cancelled
    case budgetExceeded
}

struct PrivacySafeOperationMeasurement: Hashable, Sendable {
    let operation: BoundedOperationKind
    let durationMilliseconds: Int
    let inputRecordCount: Int
    let outputRecordCount: Int
    let outcome: PrivacySafeOperationOutcome
    let budgetEvaluation: OperationBudgetEvaluation

    init(measurement: OperationMeasurement, outcome: PrivacySafeOperationOutcome, budgetEvaluation: OperationBudgetEvaluation) {
        operation = measurement.operation
        durationMilliseconds = measurement.wallClockMilliseconds
        inputRecordCount = measurement.inputRecordCount
        outputRecordCount = measurement.outputRecordCount
        self.outcome = outcome
        self.budgetEvaluation = budgetEvaluation
    }
}

enum ProductionOperationBoundaryError: LocalizedError {
    case missingPolicy(BoundedOperationKind)
    case missingBudget(BoundedOperationKind)
    case duplicatePolicy(BoundedOperationKind)
    case duplicateBudget(BoundedOperationKind)

    var errorDescription: String? {
        switch self {
        case let .missingPolicy(operation):
            "The production operation policy is missing for \(operation.rawValue)."
        case let .missingBudget(operation):
            "The production operation budget is missing for \(operation.rawValue)."
        case let .duplicatePolicy(operation):
            "The production operation policy is duplicated for \(operation.rawValue)."
        case let .duplicateBudget(operation):
            "The production operation budget is duplicated for \(operation.rawValue)."
        }
    }
}

/// Serializes admission by operation kind and checks cancellation before work.
/// Long-running operations retain their own periodic cooperative checks. The
/// boundary never throws after `work` returns because that return is the commit
/// point for sync, import, and asset mutations.
actor ProductionOperationBoundary {
    private let policies: [BoundedOperationKind: BoundedOperationPolicy]
    private let budgets: [BoundedOperationKind: OperationPerformanceBudget]
    private let gates: [BoundedOperationKind: OperationConcurrencyGate]
    private let measurementRecorder: OperationMeasurementRecorder

    init(policies: [BoundedOperationPolicy], budgets: [OperationPerformanceBudget], measurementSink: any PrivacySafeOperationMeasurementRecording) throws {
        try Self.validate(policies: policies, budgets: budgets)
        self.policies = Dictionary(uniqueKeysWithValues: policies.map { ($0.operation, $0) })
        self.budgets = Dictionary(uniqueKeysWithValues: budgets.map { ($0.operation, $0) })
        self.gates = Dictionary(
            uniqueKeysWithValues: policies.map {
                ($0.operation, OperationConcurrencyGate(maximumConcurrentOperations: $0.maximumConcurrentOperations))
            })
        self.measurementRecorder = OperationMeasurementRecorder(sink: measurementSink)
    }

    static func validate(policies: [BoundedOperationPolicy], budgets: [OperationPerformanceBudget]) throws {
        for operation in BoundedOperationKind.allCases {
            let policyCount = policies.count { $0.operation == operation }
            guard policyCount != 0 else { throw ProductionOperationBoundaryError.missingPolicy(operation) }
            guard policyCount == 1 else { throw ProductionOperationBoundaryError.duplicatePolicy(operation) }

            let budgetCount = budgets.count { $0.operation == operation }
            guard budgetCount != 0 else { throw ProductionOperationBoundaryError.missingBudget(operation) }
            guard budgetCount == 1 else { throw ProductionOperationBoundaryError.duplicateBudget(operation) }
        }
    }

    func perform<Output: Sendable>(
        _ operation: BoundedOperationKind,
        inputRecordCount: Int = 0,
        outputRecordCount: @escaping @Sendable (Output) -> Int = { _ in 0 },
        work: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        guard policies[operation] != nil,
            let budget = budgets[operation],
            let gate = gates[operation]
        else {
            throw ProductionOperationBoundaryError.missingPolicy(operation)
        }

        try await gate.acquire()
        let startedAt = Date.now
        let output: Output
        do {
            try Task.checkCancellation()
            output = try await work()
        } catch {
            let measurement = makeMeasurement(
                operation: operation, startedAt: startedAt, inputRecordCount: inputRecordCount, outputRecordCount: 0, budget: budget,
                wasCancelled: Task.isCancelled, outcome: Task.isCancelled ? .cancelled : .failed
            )
            await gate.release()
            await measurementRecorder.enqueue(measurement)
            throw error
        }

        let measurement = makeMeasurement(
            operation: operation,
            startedAt: startedAt,
            inputRecordCount: inputRecordCount,
            outputRecordCount: outputRecordCount(output),
            budget: budget,
            wasCancelled: false,
            outcome: .succeeded
        )
        await gate.release()
        // A performance budget is an observed acceptance signal, not a safe
        // post-commit failure boundary. Returning an error after a sync or
        // import has already committed would turn success into a lost-response
        // condition. The sink records `.budgetExceeded` for enforcement by
        // deployment monitoring without changing the accepted result.
        let recorder = measurementRecorder
        Task { await recorder.enqueue(measurement) }
        return output
    }

    private func makeMeasurement(
        operation: BoundedOperationKind, startedAt: Date, inputRecordCount: Int, outputRecordCount: Int, budget: OperationPerformanceBudget,
        wasCancelled: Bool, outcome: PrivacySafeOperationOutcome
    ) -> PrivacySafeOperationMeasurement {
        let measurement = OperationMeasurement(
            operation: operation,
            startedAt: startedAt,
            finishedAt: .now,
            inputRecordCount: max(0, inputRecordCount),
            outputRecordCount: max(0, outputRecordCount),
            wasCancelled: wasCancelled
        )
        let evaluation = budget.evaluate(measurement)
        let recordedOutcome: PrivacySafeOperationOutcome
        switch evaluation {
        case .withinBudget:
            recordedOutcome = outcome
        case .cancelled:
            recordedOutcome = .cancelled
        case .exceededWallClock, .exceededResidentMemory:
            recordedOutcome = .budgetExceeded
        }
        return PrivacySafeOperationMeasurement(measurement: measurement, outcome: recordedOutcome, budgetEvaluation: evaluation)
    }
}

/// Keeps a stalled deployment sink away from operation completion while
/// retaining a bounded aggregate-only backlog.
private actor OperationMeasurementRecorder {
    private static let maximumPendingMeasurements = 256
    private let sink: any PrivacySafeOperationMeasurementRecording
    private var pending: [PrivacySafeOperationMeasurement] = []
    private var isDelivering = false

    init(sink: any PrivacySafeOperationMeasurementRecording) {
        self.sink = sink
    }

    func enqueue(_ measurement: PrivacySafeOperationMeasurement) {
        if pending.count == Self.maximumPendingMeasurements {
            pending.removeFirst()
        }
        pending.append(measurement)
        guard !isDelivering else { return }
        isDelivering = true
        Task { await drain() }
    }

    private func drain() async {
        while !pending.isEmpty {
            let measurement = pending.removeFirst()
            await sink.record(measurement)
        }
        isDelivering = false
    }
}

private actor OperationConcurrencyGate {
    private let maximumConcurrentOperations: Int
    private var inFlight = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    init(maximumConcurrentOperations: Int) {
        self.maximumConcurrentOperations = maximumConcurrentOperations
    }

    func acquire() async throws {
        try Task.checkCancellation()
        if inFlight < maximumConcurrentOperations {
            inFlight += 1
            return
        }
        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append((waiterID, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
        guard acquired else { throw CancellationError() }
        if Task.isCancelled {
            release()
            try Task.checkCancellation()
        }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.continuation.resume(returning: true)
        } else {
            inFlight -= 1
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }
}
