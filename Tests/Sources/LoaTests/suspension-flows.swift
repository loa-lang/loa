import Loa
import Testing

enum CommitFake {
    /// The commit example's shape: read state, ask about foreign files, commit.
    static let source = """
        page commit {
            let accounts = mail.accounts();

            let include = ask(
                "Include these files that this goal did not write?",
                options: ["a.md", "b.md"],
                multiple: true
            );

            let sent = mail.send(
                to: accounts.map(.name),
                body: "including \\(include.count) files"
            );
        }
        """

    static func answer(_ call: Loa.Call) -> Loa.CallOutcome {
        call.qualifiedName == "mail.send" ? .value(SendFake.receipt) : MailFake.answer(call)
    }
}

extension LoaTestSuite {
    static let suspensionSuite = TestSuite("suspension", title: "Suspension: questions, pauses, approvals; resuming by replay") {
        Test("ask suspends with a typed question; the answer resumes the run without repeating calls") {
            let first = try await Loa.run(CommitFake.source, catalog: TestCatalog.catalog, executor: FakeExecutor(CommitFake.answer))
            try Expect.equal(first.failure?.description, nil, "not a failure")
            try Expect.equal(first.succeeded, false, "not finished either")
            guard let suspension = first.suspension, case .question(let question) = suspension.reason else {
                throw Loa.SyntaxFailure(message: "expected a question")
            }
            try Expect.equal(question.prompt, "Include these files that this goal did not write?", "prompt")
            try Expect.equal(question.options, ["a.md", "b.md"], "options")
            try Expect.equal(question.multiple, true, "several may be chosen")
            try Expect.equal(suspension.line, 4, "where it waits")
            try Expect.equal(first.value("accounts", page: "commit")?.description.isEmpty, false, "values before it are kept")
            try Expect.equal(first.ledger.open.map(\.question.prompt), [question.prompt], "listed as open")

            var ledger = first.ledger
            var refusal = ""
            do {
                try ledger.answer(suspension.call.identity, with: ["c.md"])
            } catch {
                refusal = "\(error)"
            }
            try Expect.equal(refusal, "\"c.md\" is not one of the options of '\(question.prompt)'", "answers are validated")
            try ledger.answer(suspension.call.identity, with: ["a.md"])

            let executor = FakeExecutor(CommitFake.answer)
            let second = try await Loa.run(CommitFake.source, catalog: TestCatalog.catalog, executor: executor, ledger: ledger)
            try Expect.equal(second.succeeded, true, "finished")
            try Expect.equal(second.value("include", page: "commit"), ["a.md"], "the answer is the value")
            let names = await executor.names
            try Expect.equal(names, ["mail.send"], "accounts came from the ledger; only the send ran")
            try Expect.equal(second.ledger.open.isEmpty, true, "nothing open")
        }

        Test("an ask inside a loop is one question per element") {
            let source = """
                var approved: [string] = [];
                for name in ["levi", "team"] {
                    let ok = ask(
                        "Write to \\(name)?",
                        options: ["yes", "no"]
                    );
                    if ok == "yes" {
                        approved += name;
                    }
                }
                """
            let first = try await Loa.run(source, catalog: TestCatalog.catalog, executor: FakeExecutor())
            guard let firstQuestion = first.suspension else { throw Loa.SyntaxFailure(message: "expected a question") }
            try Expect.equal(firstQuestion.call.identity.place, "_:ok/ask#0[name=levi]", "per element")

            var ledger = first.ledger
            try ledger.answer(firstQuestion.call.identity, with: "yes")
            let second = try await Loa.run(source, catalog: TestCatalog.catalog, executor: FakeExecutor(), ledger: ledger)
            guard let secondQuestion = second.suspension else { throw Loa.SyntaxFailure(message: "expected a second question") }
            try Expect.equal(secondQuestion.call.identity.place, "_:ok/ask#0[name=team]", "the next element asks")

            ledger = second.ledger
            try ledger.answer(secondQuestion.call.identity, with: "no")
            let third = try await Loa.run(source, catalog: TestCatalog.catalog, executor: FakeExecutor(), ledger: ledger)
            try Expect.equal(third.succeeded, true, "finished")
            try Expect.equal(third.value("approved"), ["levi"], "both answers used")
        }

        Test("suspend pauses until the owner continues") {
            let source = """
                let draft = "Tuesday works";
                suspend("Check the draft before it goes out");
                let sent = mail.send(
                    to: ["Client A"],
                    body: draft
                );
                """
            let first = try await Loa.run(source, catalog: TestCatalog.catalog, executor: FakeExecutor { _ in .value(SendFake.receipt) })
            guard let pause = first.suspension, case .pause(let question) = pause.reason else {
                throw Loa.SyntaxFailure(message: "expected a pause")
            }
            try Expect.equal(question.prompt, "Check the draft before it goes out", "the reason")
            try Expect.equal(pause.description, "2:1: Paused: Check the draft before it goes out", "description")

            var ledger = first.ledger
            try ledger.answer(pause.call.identity, with: .null)
            let executor = FakeExecutor { _ in .value(SendFake.receipt) }
            let second = try await Loa.run(source, catalog: TestCatalog.catalog, executor: executor, ledger: ledger)
            try Expect.equal(second.succeeded, true, "continued")
            let names = await executor.names
            try Expect.equal(names, ["mail.send"], "sent after the pause")
        }

        Test("a call the host holds for approval suspends the run; it runs once approved") {
            let waiting = FakeExecutor { _ in .pending("the owner has not approved the send yet") }
            let first = try await SendFake.run(waiting)
            try Expect.equal(
                first.suspension?.description,
                "1:12: mail.send waits for approval: the owner has not approved the send yet",
                "suspended"
            )
            let approved = FakeExecutor { _ in .value(SendFake.receipt) }
            let second = try await SendFake.run(ledger: first.ledger, approved)
            try Expect.equal(second.value("sent"), SendFake.receipt, "sent")
            let calls = await approved.calls
            try Expect.equal(calls.count, 1, "the held call ran once")
        }
    }
}
