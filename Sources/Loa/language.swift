import Frame
import enum Grammar.Grammar

public extension Loa {
    /// Keywords. Each lexes only as a whole word (`word: "identifier"`), so `index`, `format`
    /// and `types` stay identifiers; after `.` and as argument labels they are plain names
    /// (`hits.where(…)`, `.type`).
    static let keywords = [
        "import", "let", "var", "type", "page", "step",
        "for", "in", "if", "else", "return", "break", "continue", "try",
    ]

    /// The Loa grammar: statements and expressions around Frame's lexical layer.
    ///
    /// From Frame it takes strings, block strings, numbers, booleans, `null`, comments and
    /// whitespace, and every Frame value form is also a Loa expression (`.{ .a = 1 }`, `.case`,
    /// `.case(value)`, arrays, references). Loa's object fields, array items and call
    /// arguments hold expressions rather than values, and calls take labels, so the
    /// expression productions are Loa's own. Identifiers do not contain `-` (subtraction).
    ///
    /// Operator precedence, loosest first: `|>`, `??`, `||`, `&&`, comparison, range
    /// (`...`, `..<`), `+ -`, `* / %`, prefix `! - try`, then postfix `.name`, `(…)`, `[…]`.
    static func language() throws -> Grammar.Language {
        let values = Frame.valueGrammar()
        func t(_ name: String) -> Grammar.Expression { .symbol(.terminal(name)) }
        func p(_ name: String) -> Grammar.Expression { .symbol(.production(name)) }
        func keyword(_ name: String) -> Grammar.Expression { t("\(name)_keyword") }
        func list(_ item: String, _ rest: String) -> Grammar.Expression {
            .sequence([p(item), .optional(.sequence([.literal(","), .optional(p(rest))]))])
        }
        func binary(_ operand: String, _ operators: [String]) -> Grammar.Expression {
            .sequence([
                p(operand),
                .repeat0(.sequence([
                    .field("operator", .choice(operators.map { .literal($0) })),
                    p(operand)
                ]))
            ])
        }
        let identifier = t("identifier")
        let name = p("name")

        let productions: [Grammar.Production] = [
            // Top level: imports, type declarations, pages, and bare statements (one-liners).
            .init(name: "document", expression: .repeat0(.choice([
                p("import"), p("type_declaration"), p("page"), p("statement")
            ]))),
            .init(name: "import", expression: .sequence([
                keyword("import"), .field("module", identifier), .literal(";")
            ])),
            .init(name: "type_declaration", expression: .sequence([
                keyword("type"), .field("name", identifier), .literal("="),
                .field("type", p("type")), .literal(";")
            ])),
            .init(name: "page", expression: .sequence([
                keyword("page"), .field("name", identifier), .field("body", p("block"))
            ])),
            .init(name: "block", expression: .sequence([
                .literal("{"), .repeat0(p("statement")), .literal("}")
            ])),

            // Statements.
            .init(name: "statement", expression: .choice([
                p("binding"), p("step"), p("for"), p("if"), p("return"), p("break"),
                p("continue"), p("assignment"), p("expression_statement")
            ])),
            .init(name: "binding", expression: .sequence([
                .field("mutability", .choice([keyword("let"), keyword("var")])),
                .field("name", identifier),
                .optional(.sequence([.literal(":"), .field("type", p("type"))])),
                .literal("="),
                .field("value", p("expression")),
                .literal(";")
            ])),
            .init(name: "step", expression: .sequence([
                keyword("step"), .field("name", identifier), .field("body", p("block"))
            ])),
            .init(name: "for", expression: .sequence([
                keyword("for"), .field("element", identifier), keyword("in"),
                .field("sequence", p("expression")), .field("body", p("block"))
            ])),
            .init(name: "if", expression: .sequence([
                keyword("if"), .field("condition", p("expression")), .field("then", p("block")),
                .optional(.sequence([
                    keyword("else"), .field("else", .choice([p("if"), p("block")]))
                ]))
            ])),
            .init(name: "return", expression: .sequence([
                keyword("return"), .optional(.field("value", p("expression"))), .literal(";")
            ])),
            .init(name: "break", expression: .sequence([keyword("break"), .literal(";")])),
            .init(name: "continue", expression: .sequence([keyword("continue"), .literal(";")])),
            .init(name: "assignment", expression: .sequence([
                .field("target", p("postfix")),
                .field("operator", .choice([.literal("="), .literal("+="), .literal("-=")])),
                .field("value", p("expression")),
                .literal(";")
            ])),
            .init(name: "expression_statement", expression: .sequence([
                .field("value", p("expression")), .literal(";")
            ])),

            // Types: `Message`, `Message?`, `[String]`, `[String: Int]`, `.{ .name: Type = default }`,
            // and case unions `.low | .high`, `.text(string)`, `.replace(old: string, new: string)`.
            .init(name: "type", expression: .sequence([
                .choice([p("collection_type"), p("object_type"), p("case_union"), p("named_type")]),
                .optional(.field("optional", .literal("?")))
            ])),
            .init(name: "case_union", expression: .sequence([
                p("case_type"),
                .repeat0(.sequence([.literal("|"), p("case_type")]))
            ])),
            .init(name: "case_type", expression: .sequence([
                .literal("."), .field("name", name),
                .optional(.sequence([.literal("("), .optional(p("case_parameters")), .literal(")")]))
            ])),
            .init(name: "case_parameters", expression: list("case_parameter", "case_parameters")),
            .init(name: "case_parameter", expression: .sequence([
                .optional(.sequence([.field("label", name), .literal(":")])),
                .field("type", p("type"))
            ])),
            .init(name: "collection_type", expression: .sequence([
                .literal("["), .field("element", p("type")),
                .optional(.sequence([.literal(":"), .field("value", p("type"))])),
                .literal("]")
            ])),
            .init(name: "object_type", expression: .sequence([
                .literal("."), .literal("{"), .optional(p("type_fields")), .literal("}")
            ])),
            .init(name: "type_fields", expression: list("type_field", "type_fields")),
            .init(name: "type_field", expression: .sequence([
                .literal("."), .field("name", name), .literal(":"), .field("type", p("type")),
                .optional(.sequence([.literal("="), .field("default", p("expression"))]))
            ])),
            .init(name: "named_type", expression: .sequence([
                identifier, .repeat0(.sequence([.literal("."), identifier]))
            ])),

            // Expressions, loosest binding first.
            .init(name: "expression", expression: p("pipe")),
            .init(name: "pipe", expression: binary("coalesce", ["|>"])),
            .init(name: "coalesce", expression: binary("or", ["??"])),
            .init(name: "or", expression: binary("and", ["||"])),
            .init(name: "and", expression: binary("comparison", ["&&"])),
            .init(name: "comparison", expression: .sequence([
                p("range"),
                .optional(.sequence([
                    .field("operator", .choice(["==", "!=", "<=", ">=", "<", ">"].map { .literal($0) })),
                    p("range")
                ]))
            ])),
            .init(name: "range", expression: .sequence([
                p("additive"),
                .optional(.sequence([
                    .field("operator", .choice([.literal("..."), .literal("..<")])),
                    p("additive")
                ]))
            ])),
            .init(name: "additive", expression: binary("multiplicative", ["+", "-"])),
            .init(name: "multiplicative", expression: binary("prefix", ["*", "/", "%"])),
            .init(name: "prefix", expression: .choice([
                .sequence([.field("operator", .choice([.literal("!"), .literal("-"), keyword("try")])), p("prefix")]),
                p("postfix")
            ])),
            .init(name: "postfix", expression: .sequence([
                p("primary"),
                .repeat0(.choice([p("member_suffix"), p("call_suffix"), p("subscript_suffix")]))
            ])),
            .init(name: "member_suffix", expression: .sequence([.literal("."), .field("name", name)])),
            .init(name: "call_suffix", expression: .sequence([
                .literal("("), .optional(p("arguments")), .literal(")")
            ])),
            .init(name: "subscript_suffix", expression: .sequence([
                .literal("["), .optional(p("arguments")), .literal("]")
            ])),
            .init(name: "arguments", expression: list("argument", "arguments")),
            .init(name: "argument", expression: .sequence([
                .optional(.sequence([.field("label", name), .literal(":")])),
                .field("value", p("expression"))
            ])),

            .init(name: "primary", expression: .choice([
                p("object"), p("implicit_member"), p("empty_dictionary"), p("array"),
                p("parenthesized"),
                t("block_quoted"), t("quoted"), t("number"), t("boolean"), t("null"),
                identifier
            ])),
            // `.{ .name = expression, }`: Frame's object literal, holding expressions.
            .init(name: "object", expression: .sequence([
                .literal("."), .literal("{"), .optional(p("object_fields")), .literal("}")
            ])),
            .init(name: "object_fields", expression: list("object_field", "object_fields")),
            .init(name: "object_field", expression: .sequence([
                .literal("."), .field("name", name), .literal("="), .field("value", p("expression"))
            ])),
            // `.review`, `.minutes(30)` (with a call suffix), `.subject.contains("x")`.
            .init(name: "implicit_member", expression: .sequence([
                .literal("."), .field("name", name)
            ])),
            .init(name: "empty_dictionary", expression: .sequence([
                .literal("["), .literal(":"), .literal("]")
            ])),
            .init(name: "array", expression: .sequence([
                .literal("["), .optional(p("array_items")), .literal("]")
            ])),
            .init(name: "array_items", expression: .sequence([
                .field("element", p("expression")),
                .optional(.sequence([.literal(","), .optional(p("array_items"))]))
            ])),
            .init(name: "parenthesized", expression: .sequence([
                .literal("("), p("expression"), .literal(")")
            ])),

            // A member or label: any identifier, keywords included.
            .init(name: "name", expression: .choice([identifier] + keywords.map(keyword)))
        ]

        let terminals = values.terminals.filter { $0.name != "identifier" } + [
            .init(name: "identifier", pattern: .regex(#"[\p{L}_][\p{L}\p{N}_]*"#))
        ] + keywords.map {
            .init(name: "\($0)_keyword", pattern: .literal($0), lexicalPriority: 1, role: "keyword")
        }

        return try Grammar.Language(
            name: "loa",
            start: "document",
            productions: productions,
            terminals: terminals,
            extras: values.extras,
            word: "identifier",
            highlights: [
                .field(production: "page", name: "name", role: "namespace"),
                .field(production: "step", name: "name", role: "label"),
                .field(production: "binding", name: "name", role: "variable"),
                .field(production: "for", name: "element", role: "variable"),
                .field(production: "import", name: "module", role: "namespace"),
                .field(production: "type_declaration", name: "name", role: "type"),
                .symbol(.terminal("identifier"), within: "named_type", role: "type"),
                .field(production: "member_suffix", name: "name", role: "property"),
                .field(production: "implicit_member", name: "name", role: "constant"),
                .field(production: "object_field", name: "name", role: "property"),
                .field(production: "type_field", name: "name", role: "property"),
                .field(production: "case_type", name: "name", role: "constant"),
                .field(production: "case_parameter", name: "label", role: "property"),
                .literal("|", role: "operator"),
                .field(production: "argument", name: "label", role: "property"),
                .literal("=", role: "operator"),
                .literal("+=", role: "operator"),
                .literal("-=", role: "operator"),
                .literal("|>", role: "operator"),
                .literal("??", role: "operator"),
                .literal("==", role: "operator"),
                .literal("!=", role: "operator"),
                .literal("...", role: "operator"),
                .literal(".", role: "operator"),
                .literal(":", role: "punctuation.delimiter"),
                .literal(";", role: "punctuation.delimiter"),
                .literal(",", role: "punctuation.delimiter"),
                .literal("{", role: "punctuation.bracket"),
                .literal("}", role: "punctuation.bracket"),
                .literal("[", role: "punctuation.bracket"),
                .literal("]", role: "punctuation.bracket"),
                .literal("(", role: "punctuation.bracket"),
                .literal(")", role: "punctuation.bracket")
            ]
        )
    }
}
