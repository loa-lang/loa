/// Syntax fixtures from the design examples (plans: code/agentic/proposals/loa-examples/),
/// rewritten from operations that recur in real sessions. Candidates outside the P1 grammar
/// (trailing closures, `for` as an expression with `concurrently`) are left out here and marked
/// in the examples.
enum Fixtures {
    static let all: [(name: String, source: String)] = [
        ("one-liners", oneLiners),
        ("code-search-and-read", codeSearch),
        ("exact-edit", exactEdit),
        ("build-test-diagnose", buildTest),
        ("multi-repo-loop", multiRepo),
        ("commit-own-files", commit),
        ("mail-find-and-read", mail),
        ("schedule-slot", schedule),
        ("session-log-analysis", sessionLogs),
        ("plans-note-and-commit", plansNote),
        ("context-lookup-and-remember", context),
        ("delegate-and-infer", delegate),
    ]

    static let oneLiners = #"""
        git.repository_state();

        io.read(
            path: "Sources/Agentic/tool/tool-registry.swift",
            lines: 1...60
        );

        swift.test(
            group: "mail"
        );

        context.search(
            queries: ["roots"]
        );
        """#

    static let codeSearch = #"""
        page find_usages {
            let hits = io.search(
                pattern: "HistorySelection|history\\.retained",
                roots: [
                    "Agentic/Sources",
                    "AgenticRuntime/Sources",
                ],
                include: "*.swift"
            );

            let outside_tests = hits.where(
                !.path.contains("/Testing/")
            );

            for file in outside_tests.files {
                let slices = io.read(
                    path: file.path,
                    around: file.lines,
                    context: 15
                );
            }
        }

        page declarations {
            let symbols = swift.list_symbols(
                path: "Writers/Sources/Writers/mutations/standard-mutation-coordination.swift",
                visibility: .public
            );

            let first = symbols.first(40);

            let first_b = swift.list_symbols(
                path: "Writers/Sources/Writers/mutations/standard-mutation-coordination.swift",
                visibility: .public,
                view: .first(40)
            );
        }
        """#

    static let exactEdit = #"""
        page rename_field {
            let file = "AgenticHost/Sources/AgenticTUI/conversation/agentic-conversation-session.swift";

            io.mutate(
                path: file,
                edits: [
                    .replace(
                        old: """
                            private var liveRunState: AgentRunStateSnapshot?
                            private var liveAssistantText: String?
                            """,
                        new: """
                            private var liveRun: LiveRun?
                            """
                    ),
                    .replace(
                        old: "self.liveRunState = nil",
                        new: "self.liveRun = nil",
                        count: .all
                    ),
                ]
            );
        }

        page sweep {
            let users = io.search(
                pattern: "liveRunState",
                roots: ["AgenticHost/Sources"],
                include: "*.swift"
            );

            for file in users.files {
                io.mutate(
                    path: file.path,
                    edits: [
                        .replace(
                            old: "liveRunState",
                            new: "liveRun",
                            count: .all
                        ),
                    ]
                );
            }
        }
        """#

    static let buildTest = #"""
        page verify {
            let build = swift.build(
                package: "AgenticRuntime"
            );

            let errors = build.diagnostics.where(
                .severity == .error
            );

            if errors.count > 0 {
                let causes = errors.unique(
                    by: .location
                ).first(10);

                suspend(causes);
            }

            let tests = swift.test(
                package: "AgenticRuntime"
            );

            let failed = tests.results.where(
                .failed
            );
        }

        page fix_and_rebuild {
            io.mutate(
                path: "Sources/AgenticRuntime/runtime/history/history-store.swift",
                edits: [
                    .replace(
                        old: "let retained = selection.retained",
                        new: "let retained = selection.kept"
                    ),
                ]
            );

            let build = try swift.build(
                package: "AgenticRuntime"
            );
        }
        """#

    static let multiRepo = #"""
        page status_everywhere {
            let repos = [
                "Agentic",
                "AgenticRuntime",
                "AgenticHost",
                "AgenticDomains",
            ];

            var dirty: [RepositoryState] = [];

            for repo in repos {
                let state = git.repository_state(
                    path: repo
                );

                if state.changes.count > 0 {
                    dirty += state;
                }
            }
        }

        page pack_in_order {
            let order = [
                "Agentic",
                "AgenticRuntime",
                "AgenticDomains",
                "AgenticHost",
            ];

            for package in order {
                try swift.package_update(
                    path: package
                );

                try swift.build(
                    path: package
                );
            }
        }
        """#

    static let commit = #"""
        page commit {
            let state = git.repository_state(
                path: "~/main/plans"
            );

            let ours = goal.written_files;

            let foreign = state.changes.where(
                !ours.contains(.path)
            );

            if foreign.count > 0 {
                let include = ask(
                    "Include these files that this goal did not write?",
                    options: foreign.paths,
                    multiple: true
                );

                ours += include;
            }

            git.commit(
                only: ours,
                message: "agentic: loa syntax examples",
                push: true
            );
        }
        """#

    static let mail = #"""
        page find {
            let accounts = mail.accounts().where(
                .can_read
            );

            mail.request_access(
                targets: accounts.names,
                reason: "find the mail about pakwerk"
            );

            var hits: [MessageSummary] = [];

            for account in accounts {
                let found = mail.search(
                    targets: ["\(account.name):*"],
                    text: "pakwerk",
                    since: date.days_ago(14)
                );

                if found.failed {
                    continue;
                }

                hits += found.messages;
            }

            let found_b = mail.search(
                targets: ["*"],
                text: "pakwerk",
                since: date.days_ago(14)
            );

            let message = mail.read(
                message: hits.only()
            );
        }
        """#

    static let schedule = #"""
        page book_reply {
            let window = date.days(
                from: date.today(),
                count: 7
            );

            let agenda = schedule.agenda(
                participants: ["levi"],
                window: window
            );

            let slot = schedule.find_slots(
                participants: ["levi"],
                window: window,
                duration: .minutes(30),
                prefer: .mornings
            ).first();

            schedule.book(
                calendar: "Internal",
                title: "Reply: pakwerk",
                start: slot.start,
                duration: .minutes(30),
                participants: ["levi"]
            );

            let calendar = package.defaults.calendar ?? ask(
                "Which calendar?",
                options: schedule.calendars().names
            );
        }
        """#

    static let sessionLogs = #"""
        page tool_usage {
            let recent = sessions.list(
                since: date.days_ago(7)
            );

            var calls: [String: Int] = [:];
            var failures: [String: Int] = [:];

            for session in recent {
                let log = sessions.read_log(
                    session: session.id
                );

                for call in log.calls {
                    calls[call.tool] += 1;

                    if call.failed {
                        failures[call.tool] += 1;
                    }
                }
            }

            let top = calls.sorted(
                by: .value,
                descending: true
            ).first(25);

            let top_b = sessions.calls(
                since: date.days_ago(7)
            )
                |> group(
                    by: .tool
                )
                |> count()
                |> top(25);

            let usage = sessions.usage(
                since: date.days_ago(7)
            ).sum(
                by: .part
            );
        }
        """#

    static let plansNote = #"""
        page note {
            let area = "~/main/plans/code/agentic/proposals";

            let path = "\(area)/\(date.today())-harness-shape-autonomy-and-interface.md";

            io.write(
                path: path,
                text: """
                    # Harness shape: autonomy and interface

                    Date: \(date.today()).
                    Status: open question from Levi, to think through. Not decided.
                    """,
                mode: .create_only
            );

            git.commit(
                repository: "~/main/plans",
                only: [path],
                message: "agentic: note harness shape question",
                push: true
            );
        }
        """#

    static let context = #"""
        page lookup {
            let entries = context.search(
                queries: [
                    "calendar defaults",
                    "reply tone sports clubs",
                ]
            );

            let tone = context.read(
                id: entries.best().id
            );
        }

        page remember {
            context.remember(
                id: "hondenmeesters.calendar.reply_slots",
                title: "Reply slots go in Internal",
                summary: "Time blocked to answer mail is booked in the Internal calendar, not Personal.",
                source: goal.session
            );
        }
        """#

    static let delegate = #"""
        type ReplyPoints = .{
            .answer_first: string,      // the direct answer to their question
            .points: [string],          // what else the reply must cover
            .tone: Tone,                // existing type from the context domain
        };

        page draft_reply {
            let message = mail.read(
                message: find.message
            );

            let tone = context.read(
                id: "hondenmeesters.tone"
            );

            let points: ReplyPoints = infer(
                task: "What must Levi's reply to this message cover?",
                input: .{
                    .message = message,
                    .tone = tone,
                },
                using: .purpose(.analysis),
                budget: .tokens(1500)
            );

            mail.draft(
                reply_to: message,
                body: render(
                    template: "reply",
                    values: points
                )
            );
        }

        page research {
            let findings = delegate(
                agent: "researcher",
                task: "Which KNPV clubs near Utrecht train decoy work on weekdays?",
                tools: [
                    "web",
                ],
                budget: .{
                    .requests = 10,
                    .tokens = 60000,
                }
            );
        }
        """#
}
