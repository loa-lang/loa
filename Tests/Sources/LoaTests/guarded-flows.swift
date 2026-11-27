import Foundation
import Loa
import Testing

enum SendFake {
    static let source = """
        let sent = mail.send(
            to: ["Client A"],
            body: "Tuesday works"
        );
        """

    static let again = """
        let sent = again mail.send(
            to: ["Client A"],
            body: "Tuesday works"
        );
        """

    static let receipt = record("Receipt", ["id": "m1"])

    static func run(
        _ source: String,
        ledger: Loa.Ledger = .init(),
        _ executor: FakeExecutor
    ) async throws -> Loa.RunResult {
        try await Loa.run(source, catalog: TestCatalog.catalog, executor: executor, ledger: ledger)
    }

    static func run(ledger: Loa.Ledger, _ executor: FakeExecutor) async throws -> Loa.RunResult {
        try await run(source, ledger: ledger, executor)
    }

    static func run(_ executor: FakeExecutor) async throws -> Loa.RunResult {
        try await run(source, executor)
    }
}

/// The warnings the checker reports for `source`, as "line: message".
func checkWarnings(_ source: String) throws -> [String] {
    try Loa.check(source, catalog: TestCatalog.catalog).diagnostics
        .filter { $0.severity == .warning }
        .map { "\($0.line ?? 0): \($0.message)" }
}

extension LoaTestSuite {
    static let guardedSuite = TestSuite("guarded", title: "Guarded effects: once per generation, recovery, again") {
        Test("a completed guarded call is not repeated; changed arguments are a new call") {
            let first = try await SendFake.run(FakeExecutor { _ in .value(SendFake.receipt) })
            let executor = FakeExecutor { _ in .value(SendFake.receipt) }
            let second = try await SendFake.run(ledger: first.ledger, executor)
            let calls = await executor.calls
            try Expect.equal(calls.count, 0, "not sent twice")
            try Expect.equal(second.value("sent"), SendFake.receipt, "the recorded value is used")

            let changed = FakeExecutor { _ in .value(SendFake.receipt) }
            _ = try await SendFake.run(
                SendFake.source.replacingOccurrences(of: "Tuesday works", with: "Wednesday works"),
                ledger: second.ledger,
                changed
            )
            let changedCalls = await changed.calls
            try Expect.equal(changedCalls.count, 1, "a different message is a different send")
        }

        Test("an unknown outcome is never repeated on its own; the owner settles it") {
            let first = try await SendFake.run(FakeExecutor { _ in .unknown("timeout after sending") })
            try Expect.equal(
                first.suspension?.description,
                "1:12: mail.send: outcome unknown (timeout after sending); it must be settled before the page continues",
                "the run suspends"
            )
            try Expect.equal(first.failure == nil, true, "a suspension, not a failure")
            guard let call = first.suspension?.call else {
                throw Loa.SyntaxFailure(message: "expected a suspension")
            }
            try Expect.equal(first.ledger.unsettled.map(\.function), ["mail.send"], "listed as unsettled")

            // A rerun does not send again, and the check cannot tell either.
            let rerun = FakeExecutor { _ in .value(SendFake.receipt) }
            let second = try await SendFake.run(ledger: first.ledger, rerun)
            let rerunCalls = await rerun.calls
            try Expect.equal(rerunCalls.count, 0, "not repeated")
            try Expect.equal(second.suspension != nil, true, "still waiting")

            // The owner says it went out.
            var ledger = second.ledger
            try ledger.settle(call.identity, done: true, value: SendFake.receipt)
            let after = FakeExecutor { _ in .value(SendFake.receipt) }
            let third = try await SendFake.run(ledger: ledger, after)
            let afterCalls = await after.calls
            try Expect.equal(afterCalls.count, 0, "still not sent again")
            try Expect.equal(third.value("sent"), SendFake.receipt, "the owner's value is used")
            try Expect.equal(third.ledger.unsettled.isEmpty, true, "nothing unsettled")
        }

        Test("the domain's settle check decides: done uses the found value, not done runs it again") {
            let found = FakeExecutor(settlement: .done(SendFake.receipt)) { _ in .unknown("connection lost") }
            let done = try await SendFake.run(found)
            try Expect.equal(done.failure?.description, nil, "settled by the check")
            try Expect.equal(done.value("sent"), SendFake.receipt, "found in Sent")
            let settled = done.ledger.entries.contains { entry in
                if case .settled(_, true, _, .check) = entry.kind { return true }
                return false
            }
            try Expect.equal(settled, true, "recorded as settled by the check")

            let missing = FakeExecutor(settlement: .not_done) { _ in .unknown("connection lost") }
            let notDone = try await SendFake.run(missing)
            try Expect.equal(notDone.value("sent")?.description, "mail.send failed: not done: connection lost", "a failure value")
            let retry = FakeExecutor { _ in .value(SendFake.receipt) }
            let second = try await SendFake.run(ledger: notDone.ledger, retry)
            let retryCalls = await retry.calls
            try Expect.equal(retryCalls.count, 1, "not done, so it runs on the next run")
            try Expect.equal(second.value("sent"), SendFake.receipt, "sent")
        }

        Test("again asks the owner; approval opens a new generation, then again is satisfied") {
            let first = try await SendFake.run(FakeExecutor { _ in .value(SendFake.receipt) })

            let denied = FakeExecutor { _ in .value(SendFake.receipt) }
            let refused = try await SendFake.run(SendFake.again, ledger: first.ledger, denied)
            let deniedCalls = await denied.calls
            try Expect.equal(deniedCalls.count, 0, "not sent without a release")
            try Expect.equal(
                refused.failure?.description,
                "1:18: mail.send already ran (run 1) and the owner did not release it",
                "blocked"
            )

            let approving = FakeExecutor(release: .approved(reason: "client asked again")) { _ in .value(record(["id": "m2"])) }
            let resent = try await SendFake.run(SendFake.again, ledger: first.ledger, approving)
            let approvedCalls = await approving.calls
            try Expect.equal(approvedCalls.count, 1, "sent once more")
            try Expect.equal(resent.value("sent"), record(["id": "m2"]), "the new receipt")
            let generations = resent.ledger.entries.compactMap { entry -> String? in
                switch entry.kind {
                case .completed(let call, _): "completed #\(call.generation)"
                case .released(let call, _, let reason): "released #\(call.generation): \(reason ?? "")"
                default: nil
                }
            }
            try Expect.equal(generations, [
                "completed #1",
                "released #1: client asked again",
                "completed #2",
            ], "history by generation")

            let later = FakeExecutor(release: .approved(reason: nil)) { _ in .value(SendFake.receipt) }
            _ = try await SendFake.run(SendFake.again, ledger: resent.ledger, later)
            let laterCalls = await later.calls
            let laterReleases = await later.releases
            try Expect.equal(laterCalls.count + laterReleases.count, 0, "again is satisfied: no third send, no new question")

            // Written with `again` from the start, it simply runs once.
            let fresh = FakeExecutor(release: .approved(reason: nil)) { _ in .value(SendFake.receipt) }
            let once = try await SendFake.run(SendFake.again, fresh)
            let rerun = FakeExecutor(release: .approved(reason: nil)) { _ in .value(SendFake.receipt) }
            _ = try await SendFake.run(SendFake.again, ledger: once.ledger, rerun)
            let freshCalls = await fresh.calls
            let rerunCalls = await rerun.calls
            try Expect.equal([freshCalls.count, rerunCalls.count], [1, 0], "once, then satisfied")
        }

        Test("the owner can release from outside the program; never-repeating calls cannot be released") {
            let first = try await SendFake.run(FakeExecutor { _ in .value(SendFake.receipt) })
            var ledger = first.ledger
            let identity = try Expect.unwrapCall(ledger.executed(run: 1).first).identity
            try ledger.release(identity, reason: "send the corrected version")
            let executor = FakeExecutor { _ in .value(SendFake.receipt) }
            _ = try await SendFake.run(ledger: ledger, executor)
            let calls = await executor.calls
            try Expect.equal(calls.count, 1, "released by the owner: runs once more without again")

            let charged = try await Loa.run("let c = pay.charge(amount: 10);", catalog: TestCatalog.catalog, executor: FakeExecutor())
            var payLedger = charged.ledger
            let charge = try Expect.unwrapCall(payLedger.executed(run: 1).first).identity
            var refusal = ""
            do {
                try payLedger.release(charge)
            } catch {
                refusal = "\(error)"
            }
            try Expect.equal(refusal, "pay.charge never repeats within a goal", "a never-repeating call cannot be released")
        }

        Test("the checker: again on safe and never calls, never without a settle check, guarded calls in loops") {
            try Expect.equal(try checkErrors("again pay.charge(amount: 10);"), [
                "1: pay.charge never repeats within a goal; 'again' is not allowed",
            ], "again on never")
            try Expect.equal(try checkWarnings("let r = again mail.search(text: \"x\");"), [
                "1: mail.search can run again anyway; 'again' has no effect",
            ], "again on a safe call")
            try Expect.equal(try checkErrors("let x = 1;\nagain x;"), [
                "2: 'again' applies to a call of a catalog function",
            ], "again on a value")
            try Expect.equal(try checkErrors("pay.refund(amount: 5);"), [
                "1: pay.refund never repeats, but the catalog gives it no settle check, so an interrupted call could not be recovered",
            ], "never without a settle check")
            try Expect.equal(try checkWarnings("""
                for n in [1, 2] {
                    mail.send(
                        to: ["Client A"],
                        body: "same text"
                    );
                }
                """), [
                "2: mail.send runs in a loop with the same arguments in every iteration; as a guarded call it runs only once",
            ], "guarded call with loop-independent arguments")
            try Expect.equal(try checkWarnings("""
                for n in [1, 2] {
                    let text = "reminder \\(n)";
                    mail.send(
                        to: ["Client A"],
                        body: text
                    );
                }
                """), [], "arguments that depend on the loop are fine")
        }
    }
}

extension Expect {
    /// The call, or a test failure.
    static func unwrapCall(_ call: Loa.CallRecord?) throws -> Loa.CallRecord {
        guard let call else { throw Loa.SyntaxFailure(message: "expected a call in the ledger") }
        return call
    }
}
