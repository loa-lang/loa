import Loa
import Testing

/// Records every call and answers from a handler, as Agentic's dispatcher will.
actor FakeExecutor: Loa.Executor {
    typealias Handler = @Sendable (Loa.Call) -> Loa.CallOutcome

    let handler: Handler
    let settlement: Loa.Settlement
    let release: Loa.ReleaseDecision
    /// The host's own answer to every `ask`; nil suspends.
    let answer: Loa.Value?
    /// Calls to this function throw, as a host holding an approval does.
    let interrupting: String?
    private(set) var calls: [Loa.Call] = []
    private(set) var settled: [Loa.Call] = []
    private(set) var releases: [Loa.CallRecord] = []

    struct HeldForApproval: Error {}

    init(
        settlement: Loa.Settlement = .cannot_tell,
        release: Loa.ReleaseDecision = .denied,
        answer: Loa.Value? = nil,
        interrupting: String? = nil,
        _ handler: @escaping Handler = { _ in .value(.null) }
    ) {
        self.handler = handler
        self.settlement = settlement
        self.release = release
        self.answer = answer
        self.interrupting = interrupting
    }

    func call(_ call: Loa.Call) async throws -> Loa.CallOutcome {
        if call.qualifiedName == interrupting { throw HeldForApproval() }
        calls.append(call)
        return handler(call)
    }

    func ask(_ question: Loa.Question, call: Loa.Call) async throws -> Loa.Value? {
        answer
    }

    func settle(_ call: Loa.Call) async -> Loa.Settlement {
        settled.append(call)
        return settlement
    }

    func release(_ call: Loa.Call, previous: Loa.CallRecord) async -> Loa.ReleaseDecision {
        releases.append(previous)
        return release
    }

    var names: [String] { calls.map(\.qualifiedName) }
}

func record(_ name: String?, _ fields: KeyValuePairs<String, Loa.Value>) -> Loa.Value {
    .record(.init(name, fields.map { .init($0.key, $0.value) }))
}

func record(_ fields: KeyValuePairs<String, Loa.Value>) -> Loa.Value {
    record(nil, fields)
}

/// Runs a source that needs no catalog calls; fails the test on any failure.
func evaluate(_ source: String) async throws -> Loa.RunResult {
    let result = try await Loa.run(source, catalog: TestCatalog.catalog, executor: FakeExecutor())
    if let failure = result.failure { throw failure }
    return result
}

enum MailFake {
    static let summary = record("MessageSummary", [
        "subject": "Pakwerk: planning",
        "from": ["Client A"],
        "unread": true,
    ])

    static func answer(_ call: Loa.Call) -> Loa.CallOutcome {
        switch call.qualifiedName {
        case "mail.accounts":
            return .value([
                record("Account", ["name": "levi", "can_read": true]),
                record("Account", ["name": "team", "can_read": true]),
                record("Account", ["name": "old", "can_read": false]),
            ])
        case "mail.request_access":
            return .value(record("Grant", ["granted": call.argument("targets") ?? []]))
        case "date.days_ago":
            return .value("2026-11-13")
        case "mail.search":
            switch call.argument("targets") {
            case ["team:*"]:
                return .failure("team: authentication failed")
            default:
                return .value(record("Search", ["messages": [summary], "searched": ["INBOX"]]))
            }
        case "mail.read":
            return .value(record("Message", ["subject": "Pakwerk: planning", "body": "See you Tuesday."]))
        default:
            return .failure("not in the fake: \(call.qualifiedName)")
        }
    }
}

extension LoaTestSuite {
    static let interpreterSuite = TestSuite("interpreter", title: "Evaluation and calls") {
        Test("expressions: arithmetic, strings, interpolation, ranges, optionals") {
            let result = try await evaluate("""
                let a = 2 + 3 * 4;
                let b = 7 / 2;
                let c = 7.0 / 2;
                let name = "loa";
                let s = "hi \\(name), \\(a + 1)";
                let r = 1..<4;
                let n: string? = null;
                let d = n ?? "none";
                let big = a > 10 && !false;
                """)
            try Expect.equal(result.value("a"), 14, "precedence")
            try Expect.equal(result.value("b"), 3, "int division")
            try Expect.equal(result.value("c"), 3.5, "double division")
            try Expect.equal(result.value("s"), "hi loa, 15", "interpolation")
            try Expect.equal(result.value("r"), [1, 2, 3], "half-open range")
            try Expect.equal(result.value("d"), "none", "coalesce")
            try Expect.equal(result.value("big"), true, "logic")
        }

        Test("control flow: for, if, break, continue, accumulation and counting") {
            let result = try await evaluate("""
                var total = 0;
                var seen: [int] = [];
                for x in 1...10 {
                    if x % 2 == 0 {
                        continue;
                    }
                    if x > 7 {
                        break;
                    }
                    total += x;
                    seen += x;
                }

                var counts: [string: int] = [:];
                for word in "a b a c a".split(" ") {
                    counts[word] += 1;
                }

                let top = counts.sorted(
                    by: .value,
                    descending: true
                ).first();
                """)
            try Expect.equal(result.value("total"), 16, "1 + 3 + 5 + 7")
            try Expect.equal(result.value("seen"), [1, 3, 5, 7], "appended")
            try Expect.equal(
                result.value("counts"),
                .dictionary([.init("a", 3), .init("b", 1), .init("c", 1)]),
                "missing keys count from zero, in first-seen order"
            )
            try Expect.equal(result.value("top"), record(["key": "a", "value": 3]), "sorted entries")
        }

        Test("records, cases, declared defaults, key paths and list methods") {
            let result = try await evaluate("""
                type Priority = .low | .normal | .urgent;
                type Triage = .{
                    .priority: Priority,
                    .reason: string,
                    .follow_up: bool = false,
                };

                let t: Triage = .{ .reason = "deadline", .priority = .urgent };
                let urgent = t.priority == .urgent;
                let wait = .minutes(30);

                let people = [
                    .{ .name = "b", .age = 30 },
                    .{ .name = "a", .age = 40 },
                    .{ .name = "c", .age = 30 },
                ];
                let names = people.sorted(by: .name).map(.name);
                let thirty = people.where(.age == 30).map(.name);
                let total = people.sum(by: .age);
                let ages = people.group(by: .age).keys;
                let a_age = people.where(.name.has_prefix("a")).only().age;
                let unique = people.unique(by: .age).count;
                """)
            try Expect.equal(
                result.value("t"),
                record("Triage", ["priority": .case(.init("urgent")), "reason": "deadline", "follow_up": false]),
                "named, declared order, default filled"
            )
            try Expect.equal(result.value("urgent"), true, "case comparison")
            try Expect.equal(result.value("wait"), .case(.init("minutes", [.init(nil, 30)])), "case with a value")
            try Expect.equal(result.value("names"), ["a", "b", "c"], "sorted by a key path")
            try Expect.equal(result.value("thirty"), ["b", "c"], "where with a comparison")
            try Expect.equal(result.value("total"), 100, "sum")
            try Expect.equal(result.value("ages"), [30, 40], "group keys in first-seen order")
            try Expect.equal(result.value("a_age"), 40, "method on a key path, only")
            try Expect.equal(result.value("unique"), 2, "unique")
        }

        Test("the mail example runs against a fake executor") {
            let executor = FakeExecutor(MailFake.answer)
            let result = try await Loa.run(Fixtures.mail, catalog: TestCatalog.catalog, executor: executor)
            try Expect.equal(result.failure?.description, nil, "no failure")
            try Expect.equal(result.completed, ["find"], "page completed")
            let calls = await executor.calls
            try Expect.equal(calls.map(\.qualifiedName), [
                "mail.accounts",
                "mail.request_access",
                "date.days_ago",
                "mail.search",
                "date.days_ago",
                "mail.search",
                "date.days_ago",
                "mail.search",
                "mail.read",
            ], "one search per readable account, then the fan-out, then read")
            try Expect.equal(calls[1].argument("targets"), ["levi", "team"], "only readable accounts")
            try Expect.equal(calls[3].argument("targets"), ["levi:*"], "interpolated target")
            try Expect.equal(calls[8].argument("message"), MailFake.summary, "the only hit is read")
            try Expect.equal(calls.allSatisfy { $0.page == "find" }, true, "calls know their page")
            try Expect.equal(result.value("hits", page: "find")?.description, "[\(MailFake.summary)]", "the failed account was skipped")
            try Expect.equal(result.value("message", page: "find")?[field: "subject"], "Pakwerk: planning", "message read")
        }

        Test("failures are values until used; then the page stops at the use") {
            let failing = FakeExecutor { _ in .failure("offline") }
            let handled = try await Loa.run("""
                let r = mail.search(text: "x");
                let f = r.failed;
                let why = r.error.message;
                """, catalog: TestCatalog.catalog, executor: failing)
            try Expect.equal(handled.failure?.description, nil, "a bound failure is fine")
            try Expect.equal(handled.value("f"), true, "failed")
            try Expect.equal(handled.value("why"), "offline", "error message")

            let unused = try await Loa.run("let a = 1;\nmail.search(text: \"x\");", catalog: TestCatalog.catalog, executor: failing)
            try Expect.equal(unused.failure?.description, "2:1: mail.search failed: offline", "an unused failure stops")
            try Expect.equal(unused.value("a"), 1, "values before it are kept")

            let two = FakeExecutor { _ in .value(record("Search", ["messages": [MailFake.summary, MailFake.summary]])) }
            let only = try await Loa.run("""
                let m = mail.read(
                    message: mail.search(text: "x").messages.only()
                );
                """, catalog: TestCatalog.catalog, executor: two)
            try Expect.equal(
                only.failure?.description,
                "2:14: Argument 'message' of mail.read: only failed: expected exactly one, got 2",
                "a failed argument stops before the call"
            )
            let twoNames = await two.names
            try Expect.equal(twoNames, ["mail.search"], "mail.read was not called")

            let tried = try await Loa.run("let s = try mail.search(text: \"x\");", catalog: TestCatalog.catalog, executor: failing)
            try Expect.equal(tried.failure?.description, "1:9: mail.search failed: offline", "try stops at once")
        }

        Test("pages share their bindings forward; a failing page keeps what it computed") {
            let executor = FakeExecutor(MailFake.answer)
            let result = try await Loa.run("""
                page survey {
                    let accounts = mail.accounts();
                    let readable = accounts.where(.can_read);
                }

                page report {
                    let count = survey.readable.count;
                    let first = survey.readable.first().name;
                }
                """, catalog: TestCatalog.catalog, executor: executor)
            try Expect.equal(result.completed, ["survey", "report"], "both ran")
            try Expect.equal(result.value("count", page: "report"), 2, "a later page reads an earlier one")
            try Expect.equal(result.value("first", page: "report"), "levi", "through an optional")

            let offline = FakeExecutor { _ in .failure("offline") }
            let stopped = try await Loa.run("""
                page a {
                    let x = 1;
                    let y = mail.search(text: "x").messages;
                }

                page b {
                    let z = 2;
                }
                """, catalog: TestCatalog.catalog, executor: offline)
            try Expect.equal(stopped.failure?.page, "a", "page a stopped")
            try Expect.equal(stopped.failure?.line, 3, "at the use of the failed result")
            try Expect.equal(stopped.value("x", page: "a"), 1, "its earlier values are kept")
            try Expect.equal(stopped.pages["b"] == nil, true, "page b did not run")
            try Expect.equal(stopped.completed, [], "nothing completed")
        }
    }
}
