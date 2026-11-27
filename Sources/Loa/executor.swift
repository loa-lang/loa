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
        /// The call's ledger identity; a host can derive an idempotency key from it.
        public let identity: CallIdentity

        public init(
            domain: String,
            function: String,
            arguments: [ArgumentValue],
            effect: Effect,
            page: String?,
            range: SourceRange,
            identity: CallIdentity
        ) {
            self.domain = domain
            self.function = function
            self.arguments = arguments
            self.effect = effect
            self.page = page
            self.range = range
            self.identity = identity
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
        /// The tool says it did not apply the call; safe to run again.
        case failure(String)
        /// The call never reached the tool (preflight, invalid arguments, approval denied).
        case not_run(String)
        /// The request may or may not have taken effect (timeout, lost connection after
        /// sending). A guarded call in this state is never repeated on its own.
        case unknown(String)
        /// The host holds the call for a decision it cannot make now (an approval the owner
        /// has not given yet). The run suspends; the call is tried again when it resumes.
        case pending(String)
    }

    /// The answer to "did this interrupted call happen?".
    enum Settlement: Sendable {
        case done(Value)
        case not_done
        case cannot_tell
    }

    /// The owner's answer to `again` on a call that already ran.
    enum ReleaseDecision: Sendable {
        case approved(reason: String?)
        case denied
    }

    /// Runs catalog calls for the interpreter. Agentic implements it on its capability
    /// dispatcher, so approval, preflight and recovery stay where they are; tests use a fake.
    protocol Executor: Sendable {
        /// Runs one call. A thrown error is the host's, not the program's (a pending approval,
        /// cancellation): the call is recorded as `pending`, the run stops, and the error is in
        /// `RunResult.interruption` for the host to handle.
        func call(_ call: Call) async throws -> CallOutcome

        /// Answers an `ask` now (a host with an interface), or returns nil to suspend the run
        /// until the owner answers through the ledger.
        func ask(_ question: Question, call: Call) async throws -> Value?

        /// Looks whether a call whose outcome is unknown took effect (a Message-ID in Sent,
        /// a commit with that tree). Asked only for functions the catalog marks `settles`;
        /// it is a read, so it needs no approval.
        func settle(_ call: Call) async -> Settlement

        /// Asks the owner whether `call`, which already ran (`previous`), may run once more.
        /// Only the owner decides; the program cannot release itself.
        func release(_ call: Call, previous: CallRecord) async -> ReleaseDecision
    }
}

public extension Loa.Executor {
    func ask(_ question: Loa.Question, call: Loa.Call) async throws -> Loa.Value? {
        nil
    }

    func settle(_ call: Loa.Call) async -> Loa.Settlement {
        .cannot_tell
    }

    func release(_ call: Loa.Call, previous: Loa.CallRecord) async -> Loa.ReleaseDecision {
        .denied
    }
}
