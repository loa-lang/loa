import GrammarParsing
import Loa
import Testing

enum LoaTestSuite {
    static let suite = TestSuite("loa", title: "Loa language") {
        syntaxSuite
        checkerSuite
        interpreterSuite
        ledgerSuite
    }

    static let syntaxSuite = TestSuite("syntax", title: "Syntax and abstract syntax") {
        Test("the grammar is valid and compiles to a native parser") {
            let language = try Loa.language()
            try Expect.equal(language.word, "identifier", "keywords lex as whole words")
            _ = try Loa.syntax("")
        }

        Test("every design example parses") {
            for fixture in Fixtures.all {
                do {
                    _ = try Loa.syntax(fixture.source, filePath: "\(fixture.name).loa")
                } catch {
                    throw Loa.SyntaxFailure(message: "\(fixture.name).loa: \(error)")
                }
            }
        }

        Test("a binding keeps its name, call, labels and values") {
            let tree = try Loa.syntax(#"let found = mail.search(account: "levi", limit: 20);"#)
            try Expect.equal(tree.first("binding")?.child(field: "name")?.text, "found", "binding name")
            let labels = tree.all("argument").compactMap { $0.child(field: "label")?.leafText }
            try Expect.equal(labels, ["account", "limit"], "argument labels in order")
            let members = tree.all("member_suffix").compactMap { $0.child(field: "name")?.leafText }
            try Expect.equal(members, ["search"], "member after the domain")
        }

        Test("keywords are names after a dot and as labels; identifiers containing them stay whole") {
            let source = """
                let index = hits.where(.type == .page);
                let format = types.for(in: 1);
                let stepped = steps.if;
                """
            let tree = try Loa.syntax(source)
            let names = tree.all("binding").compactMap { $0.child(field: "name")?.text }
            try Expect.equal(names, ["index", "format", "stepped"], "identifiers that start with keywords")
        }

        Test("every Frame value form is a Loa expression") {
            _ = try Loa.syntax("""
                let value = .{
                    .text = "plain",
                    .body = \"\"\"
                        block
                        \"\"\",
                    .count = -2,
                    .ratio = 1.25,
                    .on = true,
                    .nothing = null,
                    .mode = .review,
                    .limit = .gigabytes(2.5),
                    .pair = .range(1, 2),
                    .list = [.{ .id = "a" }, .{ .id = "b", },],
                    .reference = settings.paths.deny,
                };
                """)
        }

        Test("operators layer from pipe down to postfix") {
            _ = try Loa.syntax("""
                let a = x ?? y |> f();
                let b = !done && count > 0 || force;
                let c = 1...60;
                let d = .severity == .error;
                let e = (total - used) * 2 / 3 % 4;
                let f = try swift.build();
                calls[call.tool] += 1;
                hits -= 1;
                """)
        }

        Test("types: named, optional, collections, dictionaries and objects") {
            _ = try Loa.syntax("""
                var message: Message? = null;
                var hits: [MessageSummary] = [];
                var counts: [String: Int] = [:];
                type Window = .{ .start: Time, .end: Time?, .tags: [String], };
                """)
        }

        Test("failures name the line and column") {
            let cases: [(source: String, line: Int)] = [
                ("let a = 1", 1),
                ("page p {\n    let = 1;\n}", 2),
                ("let a = f(\n    x: 1,,\n);", 2),
                ("page p {\n    if x {\n        y();\n}", 4),
            ]
            for (index, fixture) in cases.enumerated() {
                do {
                    _ = try Loa.syntax(fixture.source)
                    throw Loa.SyntaxFailure(message: "fixture \(index) parsed")
                } catch let failure as Loa.SyntaxFailure {
                    try Expect.equal(failure.line, fixture.line, "line of fixture \(index): \(failure)")
                }
            }
        }

        Test("every design example builds its abstract syntax") {
            for fixture in Fixtures.all {
                do {
                    _ = try Loa.parse(fixture.source, filePath: "\(fixture.name).loa")
                } catch {
                    throw Loa.SyntaxFailure(message: "\(fixture.name).loa: \(error)")
                }
            }
            let mail = try Loa.parse(Fixtures.mail)
            try Expect.equal(mail.pages.map(\.name), ["find"], "pages")
            try Expect.equal(mail.pages[0].body.count, 6, "statements in page find")
        }

        Test("operators group by precedence and fold to the left") {
            let cases: [(String, String)] = [
                ("1 + 2 * 3", "(+ 1 (* 2 3))"),
                ("a - b - c", "(- (- a b) c)"),
                ("x ?? y |> f()", "(|> (?? x y) f())"),
                ("!done && count > 0 || force", "(|| (&& (! done) (> count 0)) force)"),
                ("1...60", "(... 1 60)"),
                (".severity == .error", "(== .severity .error)"),
                ("try swift.build(package: \"Loa\")", "(try swift.build(package: \"Loa\"))"),
                ("-(a + b)", "(- (+ a b))"),
            ]
            for (source, expected) in cases {
                let value = try expressionValue(source)
                try Expect.equal(value, expected, source)
            }
        }

        Test("postfix chains: members, calls with labels, subscripts, implicit members") {
            try Expect.equal(
                try expressionValue("mail.search(account: \"levi\", limit: 20).messages[0].subject"),
                "mail.search(account: \"levi\", limit: 20).messages[0].subject",
                "chain"
            )
            try Expect.equal(
                try expressionValue("hits.where(!.path.contains(\"/Testing/\"))"),
                "hits.where((! .path.contains(\"/Testing/\")))",
                "implicit member chain under a prefix"
            )
            try Expect.equal(
                try expressionValue(".{ .a = 1, .b = [.x, \"y\"], .c = [:], }"),
                ".{ .a = 1, .b = [.x, \"y\"], .c = [:] }",
                "objects, arrays, empty dictionaries"
            )
        }

        Test("strings decode escapes, split interpolation and dedent block strings") {
            try Expect.equal(try expressionValue(#""tab\there \"q\" \u{e9}""#), "\"tab\there \\\"q\\\" é\"", "escapes")
            let interpolated = try Loa.parse(#"let p = "\(area)/\(date.today())-x.md";"#)
            guard case .binding(let binding)? = interpolated.statements.first?.kind,
                  case .string(let literal) = binding.value.kind else {
                throw Loa.SyntaxFailure(message: "expected a string binding")
            }
            try Expect.equal(literal.segments.count, 4, "interpolation, text, interpolation, text")
            try Expect.equal(literal.description, #""\(area)/\(date.today())-x.md""#, "segments")
            try Expect.equal(literal.constant, nil, "not constant")
            let block = try Loa.parse("""
                let body = \"\"\"
                    Beste Client A,

                      ingesprongen
                    \"\"\";
                """)
            guard case .binding(let text)? = block.statements.first?.kind,
                  case .string(let blockLiteral) = text.value.kind else {
                throw Loa.SyntaxFailure(message: "expected a block string binding")
            }
            try Expect.equal(blockLiteral.constant, "Beste Client A,\n\n  ingesprongen", "dedented")
        }

        Test("statements: bindings, assignment, for, if / else if / else, step, return") {
            let program = try Loa.parse("""
                page p {
                    var total: Int = 0;
                    for x in [1, 2] {
                        total += x;
                    }
                    if total > 2 {
                        return total;
                    } else if total == 0 {
                        break;
                    } else {
                        continue;
                    }
                    step tail {
                        done();
                    }
                }
                """)
            let body = program.pages[0].body
            try Expect.equal(body.count, 4, "four statements")
            guard case .binding(let binding) = body[0].kind else {
                throw Loa.SyntaxFailure(message: "expected binding")
            }
            try Expect.equal(binding.mutable, true, "var")
            try Expect.equal(binding.type, .named(["Int"]), "type")
            guard case .if(_, _, let otherwise?) = body[2].kind,
                  case .if(_, _, let last?) = otherwise.first?.kind,
                  case .continue = last.first?.kind else {
                throw Loa.SyntaxFailure(message: "expected if / else if / else")
            }
            guard case .step(let name, let steps) = body[3].kind else {
                throw Loa.SyntaxFailure(message: "expected step")
            }
            try Expect.equal(name, "tail", "step name")
            try Expect.equal(steps.count, 1, "step body")
        }

        Test("types: case unions with associated values, field defaults, optionals") {
            let program = try Loa.parse("""
                type Priority = .low | .normal | .urgent;
                type Edit = .replace(old: string, new: string) | .insert(string) | .remove;
                type Search = .{
                    .text: string,
                    .limit: int = 20,
                    .since: Day? = null,
                    .mode: .fast | .careful = .fast,
                };
                """)
            let rendered = program.types.map { "\($0.name) = \($0.type)" }
            try Expect.equal(rendered, [
                "Priority = .low | .normal | .urgent",
                "Edit = .replace(old: string, new: string) | .insert(string) | .remove",
                "Search = .{ .text: string, .limit: int = 20, .since: Day? = null, .mode: .fast | .careful = .fast }",
            ], "types")
        }

        Test("ranges point at the source") {
            let source = "let found = mail.search(account: \"levi\");"
            let program = try Loa.parse(source)
            guard case .binding(let binding)? = program.statements.first?.kind else {
                throw Loa.SyntaxFailure(message: "expected binding")
            }
            let bytes = Array(source.utf8)[binding.value.range]
            try Expect.equal(String(decoding: bytes, as: UTF8.self), "mail.search(account: \"levi\")", "call range")
        }

        Test("outside the P1 grammar: trailing closures and for-expressions") {
            try Expect.throwsError("trailing closure") {
                _ = try Loa.syntax("let x = hits.where { hit in hit.ok };")
            }
            try Expect.throwsError("for as an expression") {
                _ = try Loa.syntax("let s = for r in repos concurrently { git.status(); };")
            }
        }
    }
}

/// The rendering of `source` parsed as the value of a binding.
func expressionValue(_ source: String) throws -> String {
    let program = try Loa.parse("let value = \(source);")
    guard case .binding(let binding)? = program.statements.first?.kind else {
        throw Loa.SyntaxFailure(message: "expected a binding for \(source)")
    }
    return binding.value.description
}

extension GrammarParser.Node {
    func child(field name: String) -> GrammarParser.Node? {
        children.first { $0.field == name }
    }

    /// The text of the first token under this node.
    var leafText: String? {
        text ?? children.lazy.compactMap(\.leafText).first
    }

    func first(_ production: String) -> GrammarParser.Node? {
        if name == production { return self }
        return children.lazy.compactMap { $0.first(production) }.first
    }

    func all(_ production: String) -> [GrammarParser.Node] {
        (name == production ? [self] : []) + children.flatMap { $0.all(production) }
    }
}
