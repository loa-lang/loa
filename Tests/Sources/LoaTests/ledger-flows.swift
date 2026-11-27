import Loa
import Testing

extension LoaTestSuite {
    static let ledgerSuite = TestSuite("ledger", title: "Ledger: identities, entries and reuse") {
        Test("calls get identities from their binding, loop element and arguments") {
            let result = try await Loa.run(Fixtures.mail, catalog: TestCatalog.catalog, executor: FakeExecutor(MailFake.answer))
            let places = result.ledger.executed(run: 1).map(\.identity.place)
            try Expect.equal(places, [
                "find:accounts/mail.accounts#0",
                "find:_/mail.request_access#0",
                "find:found/date.days_ago#0[account=levi]",
                "find:found/mail.search#0[account=levi]",
                "find:found/date.days_ago#0[account=team]",
                "find:found/mail.search#0[account=team]",
                "find:found_b/date.days_ago#0",
                "find:found_b/mail.search#0",
                "find:message/mail.read#0",
            ], "places")
            let calls = result.ledger.executed(run: 1)
            try Expect.equal(
                calls[3].identity.arguments == calls[5].identity.arguments,
                false,
                "different arguments, different hash"
            )
        }

        Test("every call writes intended before the executor, then its outcome; bindings are recorded") {
            let result = try await Loa.run(Fixtures.mail, catalog: TestCatalog.catalog, executor: FakeExecutor(MailFake.answer))
            let kinds = result.ledger.entries.compactMap { entry -> String? in
                switch entry.kind {
                case .intended(let call) where call.function == "mail.search": "intended"
                case .completed(let call, _) where call.function == "mail.search": "completed"
                case .failed(let call, let message) where call.function == "mail.search": "failed: \(message)"
                default: nil
                }
            }
            try Expect.equal(kinds, [
                "intended", "completed",
                "intended", "failed: team: authentication failed",
                "intended", "completed",
            ], "search entries in order")
            try Expect.equal(
                result.ledger.lastValue(of: "hits", page: "find")?.description,
                "[\(MailFake.summary)]",
                "the last value bound to a var"
            )
            try Expect.equal(result.ledger.entries.map(\.sequence), Array(result.ledger.entries.indices), "sequence numbers")
            try Expect.equal(result.ledger.entries.allSatisfy { $0.run == 1 }, true, "all from run 1")
        }

        Test("a rerun answers completed reads from the ledger and retries failed ones") {
            let first = try await Loa.run(Fixtures.mail, catalog: TestCatalog.catalog, executor: FakeExecutor(MailFake.answer))
            let executor = FakeExecutor(MailFake.answer)
            let second = try await Loa.run(
                Fixtures.mail,
                catalog: TestCatalog.catalog,
                executor: executor,
                ledger: first.ledger
            )
            try Expect.equal(second.run, 2, "second run")
            try Expect.equal(second.failure?.description, nil, "no failure")
            let calls = await executor.calls
            try Expect.equal(
                calls.map(\.identity.place),
                ["find:found/mail.search#0[account=team]"],
                "only the failed search ran again; the granted access request (guarded) was not repeated"
            )
            let reused = second.ledger.entries(run: 2).filter { if case .reused = $0.kind { true } else { false } }
            try Expect.equal(reused.count, 8, "the other eight calls were answered from the ledger")
            try Expect.equal(second.value("message", page: "find"), first.value("message", page: "find"), "same result")
            try Expect.equal(second.ledger.entries.count > first.ledger.entries.count, true, "appended, not rewritten")
            try Expect.equal(Array(second.ledger.entries.prefix(first.ledger.entries.count)), first.ledger.entries, "earlier entries unchanged")
        }

        Test("edits elsewhere keep identities; changed arguments make a new call") {
            let source = """
                page survey {
                    let accounts = mail.accounts();
                    let found = mail.search(
                        text: "pakwerk"
                    );
                }
                """
            let first = try await Loa.run(source, catalog: TestCatalog.catalog, executor: FakeExecutor(MailFake.answer))

            let edited = """
                page survey {
                    let note = "checking again";
                    let boxes = mail.mailboxes(
                        account: "levi"
                    );
                    let accounts = mail.accounts();
                    let found = mail.search(
                        text: "factuur"
                    );
                }
                """
            let executor = FakeExecutor(MailFake.answer)
            _ = try await Loa.run(edited, catalog: TestCatalog.catalog, executor: executor, ledger: first.ledger)
            let calls = await executor.calls
            try Expect.equal(calls.map(\.qualifiedName), ["mail.mailboxes", "mail.search"], "accounts reused; the new call and the changed search ran")
        }

        Test("a completed mutation is not repeated; turning off reuse only affects reads") {
            let source = """
                io.mutate(
                    path: "notes.md",
                    edits: []
                );
                let accounts = mail.accounts();
                """
            let answer: FakeExecutor.Handler = { call in
                call.qualifiedName == "io.mutate" ? .value(.null) : MailFake.answer(call)
            }
            let first = try await Loa.run(source, catalog: TestCatalog.catalog, executor: FakeExecutor(answer))
            let executor = FakeExecutor(answer)
            _ = try await Loa.run(source, catalog: TestCatalog.catalog, executor: executor, ledger: first.ledger)
            let secondNames = await executor.names
            try Expect.equal(secondNames, [], "the mutation (guarded) and the read were both answered from the ledger")

            let fresh = FakeExecutor(answer)
            _ = try await Loa.run(
                source,
                catalog: TestCatalog.catalog,
                executor: fresh,
                ledger: first.ledger,
                options: .init(reuse: .none)
            )
            let freshNames = await fresh.names
            try Expect.equal(freshNames, ["mail.accounts"], "the read ran again; the mutation stayed guarded")
        }
    }
}
