import XCTest
@testable import JECore

final class UsageLedgerTests: XCTestCase {
    func testDuplicateSameEntryDoesNotDoubleCount() throws {
        var ledger = UsageLedger()
        let entry = trace(runID: "run-1")
        XCTAssertTrue(try ledger.append(entry))
        XCTAssertFalse(try ledger.append(entry))
        XCTAssertEqual(ledger.entries.count, 1)
        XCTAssertEqual(ledger.aggregates().first?.runCount, 1)
    }

    func testConflictingRunIDIsRejected() throws {
        var ledger = try UsageLedger(entries: [trace(runID: "run-1", durationMs: 10)])
        XCTAssertThrowsError(try ledger.append(trace(runID: "run-1", durationMs: 11))) { error in
            XCTAssertEqual(error as? UsageLedgerError, .conflictingRunID("run-1"))
        }
    }

    func testEstimateRequiresSourceAndStaysSeparateFromActual() throws {
        var ledger = UsageLedger()
        XCTAssertThrowsError(try ledger.append(trace(
            runID: "missing-source",
            estimatedCost: CostAmount(currency: "USD", minorUnits: 12)
        )))

        try ledger.append(trace(
            runID: "actual",
            actualCost: CostAmount(currency: "USD", minorUnits: 30)
        ))
        try ledger.append(trace(
            runID: "estimate",
            estimatedCost: CostAmount(currency: "USD", minorUnits: 12),
            estimateSource: "provider price table checked 2026-11-04"
        ))
        let aggregate = try XCTUnwrap(ledger.aggregates().first)
        XCTAssertEqual(aggregate.actualCostMinorUnitsByCurrency, ["USD": 30])
        XCTAssertEqual(aggregate.estimatedCostMinorUnitsByCurrency, ["USD": 12])
    }

    func testUnknownMeasurementsStayUnknownInAggregates() throws {
        let ledger = try UsageLedger(entries: [
            trace(runID: "known", durationMs: 100, inputTokens: 10, outputTokens: 5),
            trace(runID: "unknown")
        ])
        let aggregate = try XCTUnwrap(ledger.aggregates().first)
        XCTAssertEqual(aggregate.runCount, 2)
        XCTAssertEqual(aggregate.knownInputTokens, 10)
        XCTAssertEqual(aggregate.knownOutputTokens, 5)
        XCTAssertEqual(aggregate.unknownTokenRuns, 1)
        XCTAssertEqual(aggregate.knownDurationMs, 100)
        XCTAssertEqual(aggregate.unknownDurationRuns, 1)
    }

    func testDetailedTraceJSONHasNoContentFields() throws {
        let json = try StableJSON.encode(trace(runID: "run-1"))
        for forbidden in ["prompt", "output_text", "tool_arguments", "tool_results", "file_contents", "memory_text"] {
            XCTAssertFalse(json.contains(forbidden), forbidden)
        }
        XCTAssertTrue(json.contains("assignmentID"))
    }

    func testAggregatesAreDeterministicAcrossInputOrder() throws {
        let entries = [
            trace(runID: "b", day: "2026-11-05"),
            trace(runID: "a", day: "2026-11-04")
        ]
        XCTAssertEqual(
            UsageLedger.aggregate(entries: entries),
            UsageLedger.aggregate(entries: Array(entries.reversed()))
        )
        XCTAssertEqual(UsageLedger.aggregate(entries: entries).map(\.key.day), ["2026-11-04", "2026-11-05"])
    }

    private func trace(
        runID: String,
        day: String = "2026-11-04",
        durationMs: Int64? = nil,
        inputTokens: Int64? = nil,
        outputTokens: Int64? = nil,
        actualCost: CostAmount? = nil,
        estimatedCost: CostAmount? = nil,
        estimateSource: String? = nil
    ) -> DetailedUsageTrace {
        DetailedUsageTrace(
            runID: runID,
            recordedDay: day,
            personID: "alice",
            harness: .codex,
            launchMode: .interactive,
            role: .fast,
            engine: .ollama,
            executionPlace: .personalMachine,
            providerKind: .local,
            assignmentID: "assignment-1",
            policyVersion: "routing-policy-v1",
            winningLayer: "explicit",
            durationMs: durationMs,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            actualCost: actualCost,
            estimatedCost: estimatedCost,
            costEstimateSource: estimateSource,
            outcome: .succeeded
        )
    }
}
