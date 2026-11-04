import XCTest
@testable import JECore

final class RoutingPolicyTests: XCTestCase {
    private let policy = RoutingPolicy()

    func testHardFiltersRejectUnqualifiedWrongPersonAndWrongPlace() {
        let request = RouteRequest(
            personID: "alice",
            explicitRole: .fast,
            allowedExecutionPlaces: [.personalMachine]
        )
        let candidates = [
            candidate(id: "unqualified", qualification: .planned),
            candidate(id: "wrong-person", people: ["bob"]),
            candidate(id: "wrong-place", place: .studioWorkspace),
            candidate(id: "good")
        ]
        let decision = policy.evaluate(request: request, candidates: candidates)
        XCTAssertEqual(decision.selectedCandidateID, "good")
        XCTAssertEqual(reasons(in: decision, candidateID: "unqualified"), [.notQualified])
        XCTAssertEqual(reasons(in: decision, candidateID: "wrong-person"), [.personNotPermitted])
        XCTAssertEqual(reasons(in: decision, candidateID: "wrong-place"), [.executionPlaceNotAllowed])
    }

    func testCloudNeedsMatchingExplicitAuthorizationAndNeverCloudWins() {
        let cloud = candidate(
            id: "cloud",
            provider: .cloud,
            cloudReference: "profile:personal-cloud"
        )
        let unauthorized = policy.evaluate(
            request: RouteRequest(personID: "alice", explicitRole: .fast),
            candidates: [cloud]
        )
        XCTAssertNil(unauthorized.selectedCandidateID)
        XCTAssertEqual(reasons(in: unauthorized, candidateID: "cloud"), [.cloudNotAuthorized])

        let authorized = policy.evaluate(
            request: RouteRequest(
                personID: "alice",
                explicitRole: .fast,
                cloudAuthorization: .explicit(profileReference: "profile:personal-cloud")
            ),
            candidates: [cloud]
        )
        XCTAssertEqual(authorized.selectedCandidateID, "cloud")

        let blocked = policy.evaluate(
            request: RouteRequest(
                personID: "alice",
                explicitRole: .fast,
                neverCloud: true,
                cloudAuthorization: .explicit(profileReference: "profile:personal-cloud")
            ),
            candidates: [cloud]
        )
        XCTAssertNil(blocked.selectedCandidateID)
        XCTAssertEqual(reasons(in: blocked, candidateID: "cloud"), [.neverCloud])
    }

    func testPreferenceLayersResolveInSettledOrder() {
        let codex = candidate(id: "codex", harness: .codex, priority: 1)
        let claude = candidate(id: "claude", harness: .claudeCode, priority: 2)
        let muse = candidate(id: "muse", harness: .muse, priority: 3)
        let request = RouteRequest(
            personID: "alice",
            explicitRole: .fast,
            projectPreferences: RoutePreferences(harness: .claudeCode),
            personPreferences: RoutePreferences(harness: .muse),
            operatorPreferences: RoutePreferences(harness: .codex)
        )
        let decision = policy.evaluate(request: request, candidates: [codex, claude, muse])
        XCTAssertEqual(decision.selectedCandidateID, "claude")
        XCTAssertEqual(decision.winningLayer, "project")
    }

    func testExplicitSelectionCannotReviveHardFilteredCandidate() {
        let blocked = candidate(id: "blocked", qualification: .planned)
        let request = RouteRequest(
            personID: "alice",
            explicitRole: .fast,
            explicitPreferences: RoutePreferences(candidateID: "blocked")
        )
        let decision = policy.evaluate(request: request, candidates: [blocked, candidate(id: "good")])
        XCTAssertNil(decision.selectedCandidateID)
        XCTAssertEqual(decision.winningLayer, "none")
    }

    func testRoleLayersResolveExplicitThenProjectThenPersonThenOperator() {
        XCTAssertEqual(RouteRequest(
            personID: "alice",
            explicitRole: .strong,
            projectRole: .fast,
            personDefaultRole: .fast,
            operatorDefaultRole: .fast
        ).resolvedRole, .strong)
        XCTAssertEqual(RouteRequest(
            personID: "alice",
            projectRole: .strong,
            personDefaultRole: .fast,
            operatorDefaultRole: .fast
        ).resolvedRole, .strong)
        XCTAssertEqual(RouteRequest(
            personID: "alice",
            personDefaultRole: .strong,
            operatorDefaultRole: .fast
        ).resolvedRole, .strong)
        XCTAssertEqual(RouteRequest(
            personID: "alice",
            operatorDefaultRole: .strong
        ).resolvedRole, .strong)
    }

    func testAdvisoryScoresAreTracedButNeverAppliedInStarterPolicy() {
        let first = candidate(id: "first", priority: 1)
        let scored = candidate(id: "scored", priority: 2)
        let request = RouteRequest(
            personID: "alice",
            explicitRole: .fast,
            advisoryScores: [AdvisoryScore(candidateID: "scored", score: 0.99, scorerVersion: "triage-test")]
        )
        let decision = policy.evaluate(request: request, candidates: [scored, first])
        XCTAssertEqual(decision.selectedCandidateID, "first")
        XCTAssertFalse(decision.advisoryApplied)
        XCTAssertEqual(decision.advisoryScores.first?.scorerVersion, "triage-test")
    }

    func testEvaluationIsDeterministicForSameInputs() {
        let request = RouteRequest(personID: "alice", explicitRole: .fast, promptSizeBucket: .large)
        let candidates = [candidate(id: "b", priority: 5), candidate(id: "a", priority: 5)]
        XCTAssertEqual(
            policy.evaluate(request: request, candidates: candidates),
            policy.evaluate(request: request, candidates: Array(candidates.reversed()))
        )
    }

    private func reasons(in decision: RouteDecision, candidateID: String) -> [HardFilterReason] {
        decision.filterResults.first { $0.candidateID == candidateID }?.reasons ?? []
    }

    private func candidate(
        id: String,
        role: ModelRole = .fast,
        harness: HarnessKind = .codex,
        place: ExecutionPlace = .personalMachine,
        provider: ProviderKind = .local,
        qualification: QualificationStatus = .qualified,
        people: Set<String> = ["alice"],
        cloudReference: String? = nil,
        priority: Int = 100
    ) -> RouteCandidate {
        RouteCandidate(
            id: id,
            role: role,
            engine: .ollama,
            harness: harness,
            launchMode: .interactive,
            executionPlace: place,
            providerKind: provider,
            modelArtifact: "synthetic-model",
            qualificationStatus: qualification,
            allowedPersonIDs: people,
            cloudProfileReference: cloudReference,
            publishedPriority: priority
        )
    }
}
