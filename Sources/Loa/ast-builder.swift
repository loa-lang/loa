import Foundation
import GrammarParsing

public extension Loa {
    /// Parses a Loa source into its abstract syntax.
    static func parse(_ source: String, filePath: String? = nil) throws -> Program {
        let tree = try syntax(source, filePath: filePath)
        do {
            return try ASTBuilder().program(tree)
        } catch let failure as SyntaxFailure {
            throw failure.located(in: source)
        }
    }
}

/// Builds the abstract syntax from the concrete tree of `Loa.language()`. Shapes follow the
/// productions one to one; a production the builder does not expect is a bug in the grammar
/// or here, reported with its position.
struct ASTBuilder {
    typealias Node = GrammarParser.Node

    /// When set, every node gets this range: expressions parsed out of string interpolation
    /// point at the whole string.
    var fixedRange: Loa.SourceRange?

    func program(_ node: Node) throws -> Loa.Program {
        let items: [Loa.Item] = try node.children.map { child in
            switch child.name {
            case "import":
                return .import(.init(module: try text(child, field: "module"), range: range(child)))
            case "type_declaration":
                return .type(.init(
                    name: try text(child, field: "name"),
                    type: try type(try required(child, field: "type")),
                    range: range(child)
                ))
            case "page":
                return .page(.init(
                    name: try text(child, field: "name"),
                    body: try block(try required(child, field: "body")),
                    range: range(child)
                ))
            case "statement":
                return .statement(try statement(child))
            default:
                throw unexpected(child)
            }
        }
        return Loa.Program(items: items)
    }

    // MARK: Statements

    func block(_ node: Node) throws -> [Loa.Statement] {
        try node.children.filter { $0.name == "statement" }.map(statement)
    }

    func statement(_ node: Node) throws -> Loa.Statement {
        guard let inner = node.children.first else { throw unexpected(node) }
        let kind: Loa.Statement.Kind
        switch inner.name {
        case "binding":
            kind = .binding(.init(
                mutable: try required(inner, field: "mutability").name == "var_keyword",
                name: try text(inner, field: "name"),
                type: try inner.child(field: "type").map(type),
                value: try expression(try required(inner, field: "value"))
            ))
        case "step":
            kind = .step(
                name: try text(inner, field: "name"),
                body: try block(try required(inner, field: "body"))
            )
        case "for":
            kind = .for(
                element: try text(inner, field: "element"),
                sequence: try expression(try required(inner, field: "sequence")),
                body: try block(try required(inner, field: "body"))
            )
        case "if":
            kind = try conditional(inner)
        case "return":
            kind = .return(try inner.child(field: "value").map(expression))
        case "break":
            kind = .break
        case "continue":
            kind = .continue
        case "assignment":
            let symbol = try text(inner, field: "operator")
            guard let op = Loa.AssignmentOperator(rawValue: symbol) else { throw unexpected(inner) }
            kind = .assignment(
                target: try expression(try required(inner, field: "target")),
                operator: op,
                value: try expression(try required(inner, field: "value"))
            )
        case "expression_statement":
            kind = .expression(try expression(try required(inner, field: "value")))
        default:
            throw unexpected(inner)
        }
        return Loa.Statement(kind: kind, range: range(node))
    }

    func conditional(_ node: Node) throws -> Loa.Statement.Kind {
        var otherwise: [Loa.Statement]?
        if let branch = node.child(field: "else") {
            if branch.name == "if" {
                otherwise = [Loa.Statement(kind: try conditional(branch), range: range(branch))]
            } else {
                otherwise = try block(branch)
            }
        }
        return .if(
            condition: try expression(try required(node, field: "condition")),
            then: try block(try required(node, field: "then")),
            else: otherwise
        )
    }

    // MARK: Types

    func type(_ node: Node) throws -> Loa.TypeExpression {
        guard let base = node.children.first(where: { $0.field != "optional" }) else {
            throw unexpected(node)
        }
        let result: Loa.TypeExpression
        switch base.name {
        case "named_type":
            result = .named(base.children.filter { $0.name == "identifier" }.compactMap(\.text))
        case "collection_type":
            let element = try type(try required(base, field: "element"))
            if let value = base.child(field: "value") {
                result = .dictionary(key: element, value: try type(value))
            } else {
                result = .array(element)
            }
        case "object_type":
            result = .object(try items(of: base, item: "type_field", rest: "type_fields").map { field in
                Loa.TypeField(
                    name: try text(field, field: "name"),
                    type: try type(try required(field, field: "type")),
                    defaultValue: try field.child(field: "default").map(expression),
                    range: range(field)
                )
            })
        case "case_union":
            result = .cases(try base.children.filter { $0.name == "case_type" }.map { item in
                Loa.CaseType(
                    name: try text(item, field: "name"),
                    parameters: try items(of: item, item: "case_parameter", rest: "case_parameters").map {
                        Loa.CaseParameter(
                            label: $0.child(field: "label")?.leafText,
                            type: try type(try required($0, field: "type"))
                        )
                    }
                )
            })
        default:
            throw unexpected(base)
        }
        return node.child(field: "optional") == nil ? result : .optional(result)
    }

    // MARK: Expressions

    func expression(_ node: Node) throws -> Loa.Expression {
        switch node.name {
        case "expression":
            guard let inner = node.children.first else { throw unexpected(node) }
            return try expression(inner)
        case "pipe", "coalesce", "or", "and", "comparison", "range", "additive", "multiplicative":
            return try binary(node)
        case "prefix":
            if node.children.count == 2, let symbol = node.children[0].text,
               node.children[0].field == "operator" {
                guard let op = Loa.PrefixOperator(rawValue: symbol) else { throw unexpected(node) }
                return make(.prefix(op, try expression(node.children[1])), node)
            }
            guard let inner = node.children.first else { throw unexpected(node) }
            return try expression(inner)
        case "postfix":
            return try postfix(node)
        default:
            throw unexpected(node)
        }
    }

    /// `operand (operator operand)*`, folded to the left.
    func binary(_ node: Node) throws -> Loa.Expression {
        guard let first = node.children.first else { throw unexpected(node) }
        var result = try expression(first)
        var index = 1
        while index + 1 < node.children.count {
            let symbolNode = node.children[index]
            guard let symbol = symbolNode.text, let op = Loa.BinaryOperator(rawValue: symbol) else {
                throw unexpected(symbolNode)
            }
            let rhs = try expression(node.children[index + 1])
            result = Loa.Expression(
                kind: .binary(op, result, rhs),
                range: fixedRange ?? (result.range.lowerBound..<rhs.range.upperBound)
            )
            index += 2
        }
        return result
    }

    func postfix(_ node: Node) throws -> Loa.Expression {
        guard let first = node.children.first else { throw unexpected(node) }
        var result = try primary(first)
        for suffix in node.children.dropFirst() {
            let span = fixedRange ?? (result.range.lowerBound..<range(suffix).upperBound)
            switch suffix.name {
            case "member_suffix":
                result = .init(kind: .member(base: result, name: try text(suffix, field: "name")), range: span)
            case "call_suffix":
                result = .init(kind: .call(callee: result, arguments: try arguments(suffix)), range: span)
            case "subscript_suffix":
                result = .init(kind: .subscript(base: result, arguments: try arguments(suffix)), range: span)
            default:
                throw unexpected(suffix)
            }
        }
        return result
    }

    func arguments(_ suffix: Node) throws -> [Loa.Argument] {
        try items(of: suffix, item: "argument", rest: "arguments").map {
            Loa.Argument(
                label: $0.child(field: "label")?.leafText,
                value: try expression(try required($0, field: "value"))
            )
        }
    }

    func primary(_ node: Node) throws -> Loa.Expression {
        guard let child = node.children.first else { throw unexpected(node) }
        switch child.name {
        case "object":
            let fields = try items(of: child, item: "object_field", rest: "object_fields").map {
                Loa.ObjectField(
                    name: try text($0, field: "name"),
                    value: try expression(try required($0, field: "value"))
                )
            }
            return make(.object(fields), child)
        case "implicit_member":
            return make(.implicit_member(try text(child, field: "name")), child)
        case "empty_dictionary":
            return make(.empty_dictionary, child)
        case "array":
            var elements: [Loa.Expression] = []
            var cursor = child.children.first { $0.name == "array_items" }
            while let items = cursor {
                if let element = items.child(field: "element") {
                    elements.append(try expression(element))
                }
                cursor = items.children.first { $0.name == "array_items" }
            }
            return make(.array(elements), child)
        case "parenthesized":
            guard let inner = child.children.first(where: { $0.name == "expression" }) else {
                throw unexpected(child)
            }
            return try expression(inner)
        case "quoted", "block_quoted":
            let raw = child.text ?? ""
            return make(.string(try string(raw, block: child.name == "block_quoted", at: range(child))), child)
        case "number":
            let raw = child.text ?? ""
            if raw.contains("."), let value = Decimal(string: raw) {
                return make(.number(.decimal(value)), child)
            }
            guard let value = Int(raw) else { throw unexpected(child) }
            return make(.number(.integer(value)), child)
        case "boolean":
            return make(.boolean(child.text == "true"), child)
        case "null":
            return make(.null, child)
        case "identifier":
            return make(.identifier(child.text ?? ""), child)
        default:
            throw unexpected(child)
        }
    }

    // MARK: Strings

    /// Decodes escapes (`\n \t \r \0 \" \\ \u{…}`) and splits out `\(expression)`.
    /// Block strings drop the line after the opening quotes and the closing quotes' indentation.
    func string(_ raw: String, block: Bool, at span: Loa.SourceRange) throws -> Loa.StringLiteral {
        let body = block ? Self.dedent(raw) : String(raw.dropFirst().dropLast())
        var segments: [Loa.StringLiteral.Segment] = []
        var text = ""
        var index = body.startIndex
        func fail(_ message: String) -> Loa.SyntaxFailure {
            Loa.SyntaxFailure(message: message, offset: span.lowerBound)
        }
        while index < body.endIndex {
            let character = body[index]
            guard character == "\\" else {
                text.append(character)
                index = body.index(after: index)
                continue
            }
            let escape = body.index(after: index)
            guard escape < body.endIndex else { throw fail("String ends in a backslash") }
            switch body[escape] {
            case "n": text.append("\n")
            case "t": text.append("\t")
            case "r": text.append("\r")
            case "0": text.append("\0")
            case "\"": text.append("\"")
            case "\\": text.append("\\")
            case "u":
                guard let open = body.index(escape, offsetBy: 1, limitedBy: body.endIndex),
                      open < body.endIndex, body[open] == "{",
                      let close = body[open...].firstIndex(of: "}"),
                      let scalar = UInt32(body[body.index(after: open)..<close], radix: 16).flatMap(Unicode.Scalar.init) else {
                    throw fail("Invalid \\u{…} escape")
                }
                text.unicodeScalars.append(scalar)
                index = body.index(after: close)
                continue
            case "(":
                let start = body.index(after: escape)
                guard let end = Self.closingParenthesis(in: body, from: start) else {
                    throw fail("Unclosed \\( in string")
                }
                if !text.isEmpty {
                    segments.append(.text(text))
                    text = ""
                }
                segments.append(.interpolation(try interpolation(String(body[start..<end]), at: span)))
                index = body.index(after: end)
                continue
            default:
                throw fail("Unknown escape \\\(body[escape])")
            }
            index = body.index(after: escape)
        }
        if !text.isEmpty || segments.isEmpty {
            segments.append(.text(text))
        }
        return Loa.StringLiteral(segments: segments)
    }

    func interpolation(_ source: String, at span: Loa.SourceRange) throws -> Loa.Expression {
        let wrapped = "let interpolation = \(source);"
        let tree: Node
        do {
            tree = try Loa.syntax(wrapped)
        } catch let failure as Loa.SyntaxFailure {
            throw Loa.SyntaxFailure(message: "In \\(\(source)): \(failure.message)", offset: span.lowerBound)
        }
        let program = try ASTBuilder(fixedRange: span).program(tree)
        guard case .binding(let binding)? = program.statements.first?.kind else {
            throw Loa.SyntaxFailure(message: "Invalid interpolation", offset: span.lowerBound)
        }
        return binding.value
    }

    /// The index of the `)` closing an interpolation, skipping nested parentheses and strings.
    static func closingParenthesis(in body: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var index = start
        while index < body.endIndex {
            let character = body[index]
            if inString {
                if character == "\\" {
                    index = body.index(after: index)
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                if depth == 0 { return index }
                depth -= 1
            }
            guard index < body.endIndex else { break }
            index = body.index(after: index)
        }
        return nil
    }

    static func dedent(_ raw: String) -> String {
        let inner = raw.dropFirst(3).dropLast(3)
        var lines = inner.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let first = lines.first, first.allSatisfy(\.isWhitespace) { lines.removeFirst() }
        var indent = ""
        if let last = lines.last, last.allSatisfy(\.isWhitespace) {
            indent = last
            lines.removeLast()
        }
        return lines.map { line in
            if line.hasPrefix(indent) { return String(line.dropFirst(indent.count)) }
            return line.allSatisfy(\.isWhitespace) ? "" : line
        }.joined(separator: "\n")
    }

    // MARK: Helpers

    func make(_ kind: Loa.Expression.Kind, _ node: Node) -> Loa.Expression {
        Loa.Expression(kind: kind, range: range(node))
    }

    func range(_ node: Node) -> Loa.SourceRange {
        fixedRange ?? (node.range.lowerBound.offset..<node.range.upperBound.offset)
    }

    /// The items of a comma list `item ("," rest?)?`, in order.
    func items(of node: Node, item: String, rest: String) throws -> [Node] {
        var result: [Node] = []
        var cursor = node.children.first { $0.name == rest }
        while let list = cursor {
            result += list.children.filter { $0.name == item }
            cursor = list.children.first { $0.name == rest }
        }
        return result
    }

    func required(_ node: Node, field: String) throws -> Node {
        guard let child = node.child(field: field) else {
            throw Loa.SyntaxFailure(message: "Missing \(field) in \(node.name)",
                                    offset: node.range.lowerBound.offset)
        }
        return child
    }

    func text(_ node: Node, field: String) throws -> String {
        guard let text = try required(node, field: field).leafText else {
            throw Loa.SyntaxFailure(message: "Missing text for \(field) in \(node.name)",
                                    offset: node.range.lowerBound.offset)
        }
        return text
    }

    func unexpected(_ node: Node) -> Loa.SyntaxFailure {
        Loa.SyntaxFailure(message: "Unexpected \(node.name) in the syntax tree",
                          offset: node.range.lowerBound.offset)
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
}
