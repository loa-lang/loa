/// Compact renderings of the abstract syntax, for diagnostics and tests. Operators render as
/// prefix lists (`(+ 1 (* 2 3))`) so grouping is visible; the rest reads like the source.
extension Loa.Expression: CustomStringConvertible {
    public var description: String {
        switch kind {
        case .identifier(let name):
            return name
        case .string(let literal):
            return literal.description
        case .number(.integer(let value)):
            return String(value)
        case .number(.decimal(let value)):
            return "\(value)"
        case .boolean(let value):
            return String(value)
        case .null:
            return "null"
        case .implicit_member(let name):
            return ".\(name)"
        case .member(let base, let name):
            return "\(base).\(name)"
        case .call(let callee, let arguments):
            return "\(callee)(\(arguments.map(\.description).joined(separator: ", ")))"
        case .subscript(let base, let arguments):
            return "\(base)[\(arguments.map(\.description).joined(separator: ", "))]"
        case .object(let fields):
            return ".{ " + fields.map { ".\($0.name) = \($0.value)" }.joined(separator: ", ") + " }"
        case .array(let elements):
            return "[" + elements.map(\.description).joined(separator: ", ") + "]"
        case .empty_dictionary:
            return "[:]"
        case .prefix(let op, let operand):
            return "(\(op.rawValue) \(operand))"
        case .binary(let op, let lhs, let rhs):
            return "(\(op.rawValue) \(lhs) \(rhs))"
        }
    }
}

extension Loa.Argument: CustomStringConvertible {
    public var description: String {
        label.map { "\($0): \(value)" } ?? value.description
    }
}

extension Loa.StringLiteral: CustomStringConvertible {
    public var description: String {
        let body = segments.map { segment -> String in
            switch segment {
            case .text(let text):
                return text
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: "\\n")
            case .interpolation(let expression):
                return "\\(\(expression))"
            }
        }.joined()
        return "\"\(body)\""
    }
}

extension Loa.TypeExpression: CustomStringConvertible {
    public var description: String {
        switch self {
        case .named(let path):
            return path.joined(separator: ".")
        case .optional(let wrapped):
            return "\(wrapped)?"
        case .array(let element):
            return "[\(element)]"
        case .dictionary(let key, let value):
            return "[\(key): \(value)]"
        case .object(let fields):
            return ".{ " + fields.map { field in
                ".\(field.name): \(field.type)" + (field.defaultValue.map { " = \($0)" } ?? "")
            }.joined(separator: ", ") + " }"
        case .cases(let cases):
            return cases.map { item in
                guard !item.parameters.isEmpty else { return ".\(item.name)" }
                let parameters = item.parameters.map { parameter in
                    parameter.label.map { "\($0): \(parameter.type)" } ?? parameter.type.description
                }
                return ".\(item.name)(\(parameters.joined(separator: ", ")))"
            }.joined(separator: " | ")
        }
    }
}
