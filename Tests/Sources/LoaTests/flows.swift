import GrammarParsing
import Loa
import Testing

enum LoaTestSuite {
    static let suite = TestSuite("loa", title: "Loa language") {
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
