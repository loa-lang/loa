public extension Loa {
    /// One call of a catalog function, as the interpreter hands it to the host.
    struct Call: Sendable {
        /// The domain's canonical name, also when the source used an alias.
        public let domain: String
        public let function: String
        public let arguments: [ArgumentValue]
        public let effect: Effect
        /// The page the call is in; nil for top-level statements.
        public let page: String?
        public let range: SourceRange

        public init(
            domain: String,
            function: String,
            arguments: [ArgumentValue],
            effect: Effect,
            page: String?,
            range: SourceRange
        ) {
            self.domain = domain
            self.function = function
            self.arguments = arguments
            self.effect = effect
            self.page = page
            self.range = range
        }

        /// `mail.search`.
        public var qualifiedName: String { "\(domain).\(function)" }

        /// The value passed for a labeled argument.
        public func argument(_ label: String) -> Value? {
            arguments.first { $0.label == label }?.value
        }

        /// The positional arguments, in order.
        public var positional: [Value] {
            arguments.filter { $0.label == nil }.map(\.value)
        }
    }

    enum CallOutcome: Sendable {
        case value(Value)
        /// The call ran and failed; the program receives it as a failure value.
        case failure(String)
    }

    /// Runs catalog calls for the interpreter. Agentic implements it on its capability
    /// dispatcher, so approval, preflight and recovery stay where they are; tests use a fake.
    protocol Executor: Sendable {
        func call(_ call: Call) async -> CallOutcome
    }
}
