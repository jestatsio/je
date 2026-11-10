import Foundation
import XCTest
@testable import JECore

final class TriageTests: XCTestCase {
    func testTemplateTitleFallbackIsDeterministicAndBounded() {
        XCTAssertEqual(
            TemplateTitler.title(for: "  Fix   the failing\nlogin tests please  "),
            "Fix the failing"
        )
        XCTAssertEqual(TemplateTitler.title(for: ""), "Untitled session")
        XCTAssertEqual(TemplateTitler.title(for: "   \n  "), "Untitled session")
        let long = TemplateTitler.title(
            for: "one two three four five six seven eight nine ten eleven"
        )
        XCTAssertEqual(long.split(separator: " ").count, 8)
    }

    func testTitlingEvaluationPassesWithFakeHelper() {
        let helper = FakeFoundationHelper(
            availability: FoundationAvailability(available: true, reason: nil),
            titles: [
                "Fix the failing login tests in the checkout service":
                    "Fix Checkout Login Tests",
                "Summarize the quarterly churn report for the board":
                    "Quarterly Churn Report Summary",
                "Rename the parser module and update every import":
                    "Rename Parser Module Imports"
            ]
        )
        let report = TitlingEvaluationRunner.run(helper: helper)
        XCTAssertTrue(report.available)
        XCTAssertTrue(report.passed, "\(report.cases)")
        XCTAssertEqual(report.passedCount, report.cases.count)
        XCTAssertEqual(report.identity.provider, "apple-foundation-models")
        XCTAssertFalse(report.identity.helperVersion.isEmpty)
        XCTAssertFalse(report.identity.operatingSystem.isEmpty)
    }

    func testTitlingEvaluationFailsOversizedOrOffTopicTitles() {
        let helper = FakeFoundationHelper(
            availability: FoundationAvailability(available: true, reason: nil),
            titles: [:],
            fallbackTitle: "a very long rambling title with far too many words inside"
        )
        let report = TitlingEvaluationRunner.run(helper: helper)
        XCTAssertTrue(report.available)
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.passedCount, 0)
    }

    func testUnavailableHelperFallsBackWithoutFailingClosed() {
        let helper = FakeFoundationHelper(
            availability: FoundationAvailability(available: false, reason: "modelNotReady"),
            titles: [:]
        )
        let report = TitlingEvaluationRunner.run(helper: helper)
        XCTAssertFalse(report.available)
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.identity.availability, "unavailable:modelNotReady")
        XCTAssertEqual(
            TitlingEvaluationRunner.title(helper: helper, text: "Fix the login tests"),
            "Fix the login tests"
        )
    }

    func testThrowingHelperTreatedAsUnavailable() {
        let helper = FakeFoundationHelper(
            availability: FoundationAvailability(available: true, reason: nil),
            titles: [:],
            throwsOnTitle: true
        )
        XCTAssertEqual(
            TitlingEvaluationRunner.title(helper: helper, text: "Write release notes for the patch"),
            "Write release notes for the patch"
        )
    }

    func testTriageAvailabilityCommandJSON() {
        let helper = FakeFoundationHelper(
            availability: FoundationAvailability(available: true, reason: nil),
            titles: [:]
        )
        let result = JECommandLine.run(
            ["triage", "availability", "--json"],
            environment: [:],
            foundationHelper: helper
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("\"availability\" : \"available\""))
        XCTAssertTrue(result.stdout.contains("apple-foundation-models"))
    }

    func testTriageEvaluateTitlingCommandExitCodes() throws {
        let passing = FakeFoundationHelper(
            availability: FoundationAvailability(available: true, reason: nil),
            titles: [
                "Fix the failing login tests in the checkout service":
                    "Fix Checkout Login Tests",
                "Summarize the quarterly churn report for the board":
                    "Quarterly Churn Report Summary",
                "Rename the parser module and update every import":
                    "Rename Parser Module Imports"
            ]
        )
        let passed = JECommandLine.run(
            ["triage", "evaluate-titling", "--json"],
            environment: [:],
            foundationHelper: passing
        )
        XCTAssertEqual(passed.code, 0, passed.stderr + passed.stdout)
        let object = try JSONSerialization.jsonObject(with: Data(passed.stdout.utf8)) as? [String: Any]
        XCTAssertEqual(object?["passed"] as? Bool, true)

        let unavailable = FakeFoundationHelper(
            availability: FoundationAvailability(available: false, reason: "deviceNotEligible"),
            titles: [:]
        )
        let skipped = JECommandLine.run(
            ["triage", "evaluate-titling"],
            environment: [:],
            foundationHelper: unavailable
        )
        XCTAssertEqual(skipped.code, 1)
        XCTAssertTrue((skipped.stdout + skipped.stderr).contains("unavailable"))

        let invalid = JECommandLine.run(
            ["triage", "bogus"],
            environment: [:],
            foundationHelper: passing
        )
        XCTAssertEqual(invalid.code, 2)
    }
}

private final class FakeFoundationHelper: FoundationHelping, @unchecked Sendable {
    private let storedAvailability: FoundationAvailability
    private let titles: [String: String]
    private let fallbackTitle: String
    private let throwsOnTitle: Bool

    init(
        availability: FoundationAvailability,
        titles: [String: String],
        fallbackTitle: String = "Synthetic Title",
        throwsOnTitle: Bool = false
    ) {
        self.storedAvailability = availability
        self.titles = titles
        self.fallbackTitle = fallbackTitle
        self.throwsOnTitle = throwsOnTitle
    }

    func availability() throws -> FoundationAvailability {
        storedAvailability
    }

    func title(for text: String) throws -> String {
        if throwsOnTitle {
            throw FoundationHelperError.operationFailed
        }
        return titles[text] ?? fallbackTitle
    }
}
