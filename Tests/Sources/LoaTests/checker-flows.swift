import Loa
import Testing

/// A small stand-in for the catalog Agentic will render from its capability descriptors.
enum TestCatalog {
    static let catalog = Loa.Catalog(
        domains: [
            .init("mail", aliases: ["email"], functions: [
                .init("accounts", result: .array(.named("Account")), effect: .read),
                .init("request_access", parameters: [
                    .init("targets", .array(.string), required: true),
                    .init("level", .cases(.init(nil, ["read", "draft"]))),
                    .init("reason", .string, required: true),
                ], result: .named("Grant"), effect: .ask),
                .init("mailboxes", parameters: [
                    .init("account", .string, required: true),
                ], result: .array(.named("Mailbox")), effect: .read),
                .init("search", parameters: [
                    .init("account", .string),
                    .init("targets", .array(.string)),
                    .init("mailbox", .string),
                    .init("text", .string),
                    .init("since", .named("Day")),
                    .init("limit", .int),
                ], result: .named("Search"), effect: .read),
                .init("read", parameters: [
                    .init("message", .named("MessageSummary"), required: true),
                ], result: .named("Message"), effect: .read),
                .init("send", parameters: [
                    .init("to", .array(.string), required: true),
                    .init("body", .string, required: true),
                ], effect: .external),
            ]),
            .init("date", functions: [
                .init("today", result: .named("Day"), effect: .pure),
                .init("days_ago", parameters: [.init(nil, .int, required: true)], result: .named("Day"), effect: .pure),
            ]),
            .init("io", aliases: ["fs"], functions: [
                .init("mutate", parameters: [
                    .init("path", .string, required: true),
                    .init("edits", .array(.any), required: true),
                ], effect: .mutate),
            ]),
        ],
        types: [
            "Day": .string,
            "Grant": .record(.init("Grant", [.init("granted", .array(.string))])),
            "Account": .record(.init("Account", [
                .init("name", .string),
                .init("can_read", .bool),
            ])),
            "Mailbox": .record(.init("Mailbox", [.init("name", .string), .init("selectable", .bool)])),
            "Search": .record(.init("Search", [
                .init("messages", .array(.named("MessageSummary"))),
                .init("searched", .array(.string)),
            ])),
            "MessageSummary": .record(.init("MessageSummary", [
                .init("subject", .string),
                .init("from", .array(.string)),
                .init("unread", .bool),
            ])),
            "Message": .record(.init("Message", [
                .init("subject", .string),
                .init("body", .string),
            ])),
        ]
    )
}

/// The checker's errors for `source`, as "line: message" strings.
func checkErrors(_ source: String) throws -> [String] {
    try Loa.check(source, catalog: TestCatalog.catalog).errors.map { "\($0.line ?? 0): \($0.message)" }
}

extension LoaTestSuite {
    static let checkerSuite = TestSuite("checker", title: "Names, calls, types and effects") {
        Test("the mail example checks clean and reports its effects") {
            let result = try Loa.check(Fixtures.mail, catalog: TestCatalog.catalog)
            try Expect.equal(result.errors.map(\.description), [], "no errors")
            let effects = result.effects.map { "\($0.function) \($0.effect.rawValue)\($0.inLoop ? " loop" : "")" }
            try Expect.equal(effects, [
                "mail.accounts read",
                "mail.request_access ask",
                "date.days_ago pure loop",
                "mail.search read loop",
                "date.days_ago pure",
                "mail.search read",
                "mail.read read",
            ], "effects in source order")
            try Expect.equal(result.highestEffect(), .ask, "highest effect")
        }

        Test("unknown names come with the closest match") {
            try Expect.equal(try checkErrors("mial.search();"), [
                "1: Cannot find 'mial' in scope. Did you mean 'mail'?",
            ], "domain")
            try Expect.equal(try checkErrors("mail.serch();"), [
                "1: mail has no function 'serch'. Did you mean 'search'?",
            ], "function")
            try Expect.equal(try checkErrors("let hits = 1;\nlet n = hitz;"), [
                "2: Cannot find 'hitz' in scope. Did you mean 'hits'?",
            ], "variable")
            try Expect.equal(try checkErrors("var m: Mesage? = null;"), [
                "1: Unknown type 'Mesage'. Did you mean 'Message'?",
            ], "type")
            try Expect.equal(try checkErrors("let a = mail.accounts().first().nmae;"), [
                "1: Account has no field 'nmae'. Did you mean 'name'?",
            ], "field through an optional")
        }

        Test("calls check labels, required arguments and argument types against the signature") {
            let labelErrors = try Loa.check("mail.search(folder: \"INBOX\");", catalog: TestCatalog.catalog).errors
            try Expect.equal(labelErrors.first?.message, "mail.search has no argument 'folder'.", "unknown label")
            try Expect.equal(
                labelErrors.first?.note,
                "mail.search(account: string?, targets: [string]?, mailbox: string?, text: string?, since: Day?, limit: int?) -> Search",
                "signature as the note"
            )
            try Expect.equal(try checkErrors("mail.request_access(reason: \"x\");"), [
                "1: Missing argument 'targets' for mail.request_access",
            ], "required")
            try Expect.equal(try checkErrors("mail.search(limit: \"ten\");"), [
                "1: Argument 'limit' of mail.search expects int, got string",
            ], "type")
            try Expect.equal(try checkErrors("mail.search(\"x\");"), [
                "1: mail.search takes labeled arguments",
            ], "positional")
            try Expect.equal(try checkErrors("mail.request_access(targets: [\"a\"], level: .write, reason: \"x\");"), [
                "1: '.write' is not a case of .read | .draft (.read, .draft).",
            ], "case argument")
            try Expect.equal(try checkErrors("let d = date.days_ago(7);\nlet e = email.accounts();"), [], "positional parameter and domain alias")
        }

        Test("let is constant, var is not; scopes and loops are respected") {
            try Expect.equal(try checkErrors("let n = 1;\nn += 1;"), [
                "2: 'n' is a constant (let); declare it with var to change it",
            ], "let")
            try Expect.equal(try checkErrors("var n = 1;\nn += 1;\nvar names: [string] = [];\nnames += \"x\";"), [], "var")
            try Expect.equal(try checkErrors("let a = 1;\nlet a = 2;"), ["2: 'a' is already declared here"], "redeclaration")
            try Expect.equal(try checkErrors("break;"), ["1: 'break' outside a loop"], "break")
            try Expect.equal(try checkErrors("if 1 { }"), ["1: A condition must be bool, got int"], "condition")
            try Expect.equal(try checkErrors("for x in [1, 2] { let y = x; }\nlet z = y;"), [
                "2: Cannot find 'y' in scope.",
            ], "block scope")
            try Expect.equal(try checkErrors("let mail = 1;"), [
                "1: 'mail' shadows a domain; choose another name",
            ], "shadowing a domain")
        }

        Test("types: records, case unions, defaults, optionals and inference results") {
            let source = """
                type Priority = .low | .normal | .urgent;
                type Triage = .{
                    .priority: Priority,
                    .reason: string,
                    .follow_up: bool = false,
                };

                page triage {
                    let message = mail.read(
                        message: mail.search(text: "x").messages.only()
                    );

                    let result: Triage = infer(
                        task: "How urgent is this mail?",
                        input: message
                    );

                    let urgent = result.priority == .urgent;
                    let manual: Triage = .{ .priority = .low, .reason = "fine" };
                }
                """
            let result = try Loa.check(source, catalog: TestCatalog.catalog)
            try Expect.equal(result.errors.map(\.description), [], "no errors")
            try Expect.equal(result.effects.map(\.function), ["mail.search", "mail.read", "infer"], "effects")
            try Expect.equal(try checkErrors("""
                type Priority = .low | .high;
                let p: Priority = .urgent;
                let q: Triage = 1;
                type Triage = .{ .priority: Priority, .reason: string };
                let r: Triage = .{ .priority = .low };
                """), [
                "2: '.urgent' is not a case of Priority (.low, .high).",
                "3: 'q' is declared Triage but its value is int",
                "5: Missing field 'reason' for Triage",
            ], "case, record and missing field errors")
        }

        Test("pages expose their bindings; effects in loops are marked") {
            let source = """
                page survey {
                    let accounts = mail.accounts();
                    let readable = accounts.where(.can_read);
                }

                page change {
                    for account in survey.readable {
                        io.mutate(
                            path: account.name,
                            edits: []
                        );
                    }
                    let missing = survey.acounts;
                }
                """
            let result = try Loa.check(source, catalog: TestCatalog.catalog)
            try Expect.equal(result.errors.map { "\($0.line ?? 0): \($0.message)" }, [
                "13: Page 'survey' has no binding 'acounts'. Did you mean 'accounts'?",
            ], "page reference")
            try Expect.equal(result.highestEffect(page: "survey"), .read, "survey only reads")
            try Expect.equal(result.highestEffect(page: "change"), .mutate, "change mutates")
            try Expect.equal(result.effects.last?.inLoop, true, "the mutation runs in a loop")
        }

        Test("key paths, comparisons and list methods type through the element") {
            try Expect.equal(try checkErrors("""
                let hits = mail.search(text: "x").messages;
                let unread = hits.where(.unread);
                let subjects = hits.map(.subject);
                let first: string? = subjects.first();
                let mine = hits.where(.subject.contains("pakwerk") && !.unread);
                let wrong = hits.where(.subjct);
                let count: int = hits.count;
                """), [
                "6: MessageSummary has no field 'subjct'. Did you mean 'subject'?",
            ], "key paths")
        }
    }
}
