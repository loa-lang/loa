public extension Loa {
    /// What a program may call and name, supplied by the host (Agentic renders it from its
    /// capability descriptors). Plain data, so Loa never depends on the host.
    struct Catalog: Sendable {
        public var domains: [Domain]
        /// Named types the functions take and return, by name.
        public var types: [String: ValueType]

        public init(domains: [Domain] = [], types: [String: ValueType] = [:]) {
            self.domains = domains
            self.types = types
        }

        public func domain(named name: String) -> Domain? {
            domains.first { $0.name == name || $0.aliases.contains(name) }
        }

        public var domainNames: [String] {
            domains.flatMap { [$0.name] + $0.aliases }
        }
    }

    struct Domain: Sendable {
        public let name: String
        public let aliases: [String]
        public let functions: [Function]

        public init(_ name: String, aliases: [String] = [], functions: [Function]) {
            self.name = name
            self.aliases = aliases
            self.functions = functions
        }

        public func function(named name: String) -> Function? {
            functions.first { $0.name == name }
        }
    }

    struct Function: Sendable {
        public let name: String
        public let parameters: [Parameter]
        public let result: ValueType
        public let effect: Effect
        public let repeats: Repeats
        /// Whether the host can tell, after an interrupted call, if it happened
        /// (`Executor.settle`). Required for `.never`.
        public let settles: Bool
        public let summary: String

        /// `repeats` defaults by effect: reads and pure calls are `.safe`, anything else
        /// `.guarded`, the restrictive default.
        public init(
            _ name: String,
            parameters: [Parameter] = [],
            result: ValueType = .any,
            effect: Effect,
            repeats: Repeats? = nil,
            settles: Bool = false,
            summary: String = ""
        ) {
            self.name = name
            self.parameters = parameters
            self.result = result
            self.effect = effect
            self.repeats = repeats ?? (effect <= .read ? .safe : .guarded)
            self.settles = settles
            self.summary = summary
        }

        /// One line, for diagnostics: `search(account: string?, text: string?) -> Search`.
        public func signature(domain: String) -> String {
            let parameters = parameters.map { parameter in
                let label = parameter.label.map { "\($0): " } ?? ""
                return label + parameter.type.description + (parameter.required ? "" : "?")
            }
            return "\(domain).\(name)(\(parameters.joined(separator: ", "))) -> \(result)"
        }
    }

    struct Parameter: Sendable {
        /// `nil` for a positional parameter.
        public let label: String?
        public let type: ValueType
        public let required: Bool

        public init(_ label: String?, _ type: ValueType, required: Bool = false) {
            self.label = label
            self.type = type
            self.required = required
        }
    }

    /// Whether running a call again is harmless.
    enum Repeats: String, Sendable, Hashable {
        /// Running it again gives the same state: reads, writing exact content.
        case safe
        /// Must not repeat by accident: it runs once per generation; `again` asks the owner
        /// for a new generation.
        case guarded
        /// Never repeats within the goal, not even with `again`.
        case never
    }

    /// What running a call does to the world, ordered from harmless to consequential.
    enum Effect: String, Sendable, Comparable, CaseIterable {
        case pure
        case read
        case ask
        case infer
        case delegate
        case process
        case mutate
        case external

        public static func < (lhs: Self, rhs: Self) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    /// The type of a value as the checker sees it. `any` is unknown and accepted everywhere:
    /// checking is gradual, so a missing catalog type never blocks a program.
    indirect enum ValueType: Sendable, Equatable, CustomStringConvertible {
        case any
        case string
        case int
        case double
        case bool
        case null
        case optional(ValueType)
        case array(ValueType)
        case dictionary(ValueType, ValueType)
        case record(Record)
        case cases(Cases)
        /// A catalog or program type, resolved by name when used.
        case named(String)

        public var description: String {
            switch self {
            case .any: "any"
            case .string: "string"
            case .int: "int"
            case .double: "double"
            case .bool: "bool"
            case .null: "null"
            case .optional(let wrapped): "\(wrapped)?"
            case .array(let element): "[\(element)]"
            case .dictionary(let key, let value): "[\(key): \(value)]"
            case .record(let record): record.name ?? ".{ \(record.fields.map { ".\($0.name): \($0.type)" }.joined(separator: ", ")) }"
            case .cases(let cases): cases.name ?? cases.names.map { ".\($0)" }.joined(separator: " | ")
            case .named(let name): name
            }
        }
    }

    struct Record: Sendable, Equatable {
        public let name: String?
        public let fields: [Field]

        public init(_ name: String? = nil, _ fields: [Field]) {
            self.name = name
            self.fields = fields
        }

        public func field(named name: String) -> Field? {
            fields.first { $0.name == name }
        }
    }

    struct Field: Sendable, Equatable {
        public let name: String
        public let type: ValueType
        public let hasDefault: Bool

        public init(_ name: String, _ type: ValueType, hasDefault: Bool = false) {
            self.name = name
            self.type = type
            self.hasDefault = hasDefault
        }
    }

    struct Cases: Sendable, Equatable {
        public let name: String?
        public let names: [String]

        public init(_ name: String? = nil, _ names: [String]) {
            self.name = name
            self.names = names
        }
    }
}
