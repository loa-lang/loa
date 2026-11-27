import Foundation

public extension Loa {
    /// A value at run time. Records and dictionaries keep their order, so output reads in the
    /// order it was written or returned.
    indirect enum Value: Sendable, Hashable, CustomStringConvertible {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case array([Value])
        case dictionary([Entry])
        case record(RecordValue)
        /// `.urgent`, `.minutes(30)`, `.text(value: "x")`.
        case `case`(CaseValue)
        /// A call that failed, kept as a value: `.failed` reads true and `.error` describes it.
        /// Using it any other way stops the page.
        case failure(Failure)

        /// How the value reads inside an interpolated string: strings without quotes.
        public var text: String {
            if case .string(let string) = self { return string }
            return description
        }

        public var description: String {
            switch self {
            case .null:
                return "null"
            case .bool(let value):
                return String(value)
            case .int(let value):
                return String(value)
            case .double(let value):
                return String(value)
            case .string(let value):
                return "\"\(value)\""
            case .array(let elements):
                return "[\(elements.map(\.description).joined(separator: ", "))]"
            case .dictionary(let entries):
                if entries.isEmpty { return "[:]" }
                return "[\(entries.map { "\($0.key): \($0.value)" }.joined(separator: ", "))]"
            case .record(let record):
                return record.description
            case .case(let value):
                return value.description
            case .failure(let failure):
                return failure.description
            }
        }

        /// A field of a record, or nil.
        public subscript(field name: String) -> Value? {
            guard case .record(let record) = self else { return nil }
            return record[name]
        }
    }

    struct Entry: Sendable, Hashable {
        public var key: Value
        public var value: Value

        public init(_ key: Value, _ value: Value) {
            self.key = key
            self.value = value
        }
    }

    struct FieldValue: Sendable, Hashable {
        public let name: String
        public var value: Value

        public init(_ name: String, _ value: Value) {
            self.name = name
            self.value = value
        }
    }

    /// A record: the fields of `.{ … }`, a tool result, or a page's bindings.
    struct RecordValue: Sendable, Hashable, CustomStringConvertible {
        /// The declared type, when known (`Triage`, `Account`).
        public var name: String?
        public var fields: [FieldValue]

        public init(_ name: String? = nil, _ fields: [FieldValue]) {
            self.name = name
            self.fields = fields
        }

        public subscript(name: String) -> Value? {
            get { fields.first { $0.name == name }?.value }
            set {
                if let index = fields.firstIndex(where: { $0.name == name }) {
                    if let newValue {
                        fields[index].value = newValue
                    } else {
                        fields.remove(at: index)
                    }
                } else if let newValue {
                    fields.append(.init(name, newValue))
                }
            }
        }

        public var description: String {
            if fields.isEmpty { return ".{}" }
            return ".{ \(fields.map { ".\($0.name) = \($0.value)" }.joined(separator: ", ")) }"
        }
    }

    struct CaseValue: Sendable, Hashable, CustomStringConvertible {
        public let name: String
        public let arguments: [ArgumentValue]

        public init(_ name: String, _ arguments: [ArgumentValue] = []) {
            self.name = name
            self.arguments = arguments
        }

        public var description: String {
            if arguments.isEmpty { return ".\(name)" }
            return ".\(name)(\(arguments.map(\.description).joined(separator: ", ")))"
        }
    }

    struct ArgumentValue: Sendable, Hashable, CustomStringConvertible {
        /// nil for a positional argument.
        public let label: String?
        public let value: Value

        public init(_ label: String?, _ value: Value) {
            self.label = label
            self.value = value
        }

        public var description: String {
            label.map { "\($0): \(value)" } ?? value.description
        }
    }

    /// Why a call failed, as the program sees it.
    struct Failure: Sendable, Hashable, CustomStringConvertible {
        public let message: String
        /// `mail.search`, or a method such as `only`.
        public let function: String?

        public init(_ message: String, function: String? = nil) {
            self.message = message
            self.function = function
        }

        public var description: String {
            function.map { "\($0) failed: \(message)" } ?? message
        }
    }
}

// Literals, so hosts and tests can write results directly: `"levi"`, `14`, `["a", "b"]`.
extension Loa.Value: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension Loa.Value: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .int(value)
    }
}

extension Loa.Value: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension Loa.Value: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension Loa.Value: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: Loa.Value...) {
        self = .array(elements)
    }
}
