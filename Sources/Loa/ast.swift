import Foundation

/// The abstract syntax of a Loa source. Every node keeps its UTF-8 byte range in the source,
/// so the checker and the runtime can point at the exact text.
public extension Loa {
    typealias SourceRange = Range<Int>

    struct Program: Sendable {
        public let items: [Item]

        public var imports: [Import] {
            items.compactMap { if case .import(let value) = $0 { value } else { nil } }
        }

        public var types: [TypeDeclaration] {
            items.compactMap { if case .type(let value) = $0 { value } else { nil } }
        }

        public var pages: [Page] {
            items.compactMap { if case .page(let value) = $0 { value } else { nil } }
        }

        /// Statements outside any page: a one-liner, or a few lines run as an anonymous page.
        public var statements: [Statement] {
            items.compactMap { if case .statement(let value) = $0 { value } else { nil } }
        }
    }

    enum Item: Sendable {
        case `import`(Import)
        case type(TypeDeclaration)
        case page(Page)
        case statement(Statement)
    }

    struct Import: Sendable {
        public let module: String
        public let range: SourceRange
    }

    struct TypeDeclaration: Sendable {
        public let name: String
        public let type: TypeExpression
        public let range: SourceRange
    }

    struct Page: Sendable {
        public let name: String
        public let body: [Statement]
        public let range: SourceRange
    }

    // MARK: Types

    indirect enum TypeExpression: Sendable, Equatable {
        case named([String])
        case optional(TypeExpression)
        case array(TypeExpression)
        case dictionary(key: TypeExpression, value: TypeExpression)
        case object([TypeField])
        case cases([CaseType])
    }

    struct TypeField: Sendable, Equatable {
        public let name: String
        public let type: TypeExpression
        public let defaultValue: Expression?
        public let range: SourceRange

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.name == rhs.name && lhs.type == rhs.type
                && lhs.defaultValue?.description == rhs.defaultValue?.description
        }
    }

    struct CaseType: Sendable, Equatable {
        public let name: String
        public let parameters: [CaseParameter]
    }

    struct CaseParameter: Sendable, Equatable {
        public let label: String?
        public let type: TypeExpression
    }

    // MARK: Statements

    struct Statement: Sendable {
        public let kind: Kind
        public let range: SourceRange

        public indirect enum Kind: Sendable {
            case binding(Binding)
            case assignment(target: Expression, operator: AssignmentOperator, value: Expression)
            case expression(Expression)
            case `for`(element: String, sequence: Expression, body: [Statement])
            /// `else if` is an `else` holding a single `if` statement.
            case `if`(condition: Expression, then: [Statement], else: [Statement]?)
            case `return`(Expression?)
            case `break`
            case `continue`
            case step(name: String, body: [Statement])
        }
    }

    struct Binding: Sendable {
        public let mutable: Bool
        public let name: String
        public let type: TypeExpression?
        public let value: Expression
    }

    enum AssignmentOperator: String, Sendable {
        case assign = "="
        case add = "+="
        case subtract = "-="
    }

    // MARK: Expressions

    struct Expression: Sendable {
        public let kind: Kind
        public let range: SourceRange

        public indirect enum Kind: Sendable {
            case identifier(String)
            case string(StringLiteral)
            case number(Number)
            case boolean(Bool)
            case null
            /// `.review`, the start of `.minutes(30)` or `.subject.contains("x")`.
            case implicit_member(String)
            case member(base: Expression, name: String)
            case call(callee: Expression, arguments: [Argument])
            case `subscript`(base: Expression, arguments: [Argument])
            case object([ObjectField])
            case array([Expression])
            case empty_dictionary
            case prefix(PrefixOperator, Expression)
            case binary(BinaryOperator, Expression, Expression)
        }
    }

    struct Argument: Sendable {
        public let label: String?
        public let value: Expression
    }

    struct ObjectField: Sendable {
        public let name: String
        public let value: Expression
    }

    enum Number: Sendable, Equatable {
        case integer(Int)
        case decimal(Decimal)
    }

    struct StringLiteral: Sendable {
        public enum Segment: Sendable {
            case text(String)
            case interpolation(Expression)
        }

        public let segments: [Segment]

        /// The text when the string has no interpolation.
        public var constant: String? {
            var result = ""
            for segment in segments {
                guard case .text(let text) = segment else { return nil }
                result += text
            }
            return result
        }
    }

    enum PrefixOperator: String, Sendable {
        case not = "!"
        case negate = "-"
        case `try` = "try"
        /// Runs a guarded call that already ran once more, after the owner releases it.
        case again = "again"
    }

    enum BinaryOperator: String, Sendable {
        case pipe = "|>"
        case coalesce = "??"
        case or = "||"
        case and = "&&"
        case equal = "=="
        case not_equal = "!="
        case less = "<"
        case less_equal = "<="
        case greater = ">"
        case greater_equal = ">="
        case closed_range = "..."
        case half_open_range = "..<"
        case add = "+"
        case subtract = "-"
        case multiply = "*"
        case divide = "/"
        case remainder = "%"
    }
}
