public extension Loa {
    /// Which call a ledger entry is about, stable across edits elsewhere in the page.
    ///
    /// - `page`: the page's name (nil at top level).
    /// - `site`: the statement's anchor and the call's place in it: `found/mail.search#0`.
    ///   A binding anchors its calls by its name (qualified by steps: `prepare.found`);
    ///   other statements by `_`, with an ordinal among such call sites of the function.
    /// - `iteration`: one key per enclosing loop, from the element (`account=levi`).
    /// - `arguments`: a hash of the argument values.
    struct CallIdentity: Sendable, Hashable, CustomStringConvertible {
        public let page: String?
        public let site: String
        public let iteration: [String]
        public let arguments: String

        public init(page: String?, site: String, iteration: [String], arguments: String) {
            self.page = page
            self.site = site
            self.iteration = iteration
            self.arguments = arguments
        }

        /// The identity without its arguments: the same place in the program.
        public var place: String {
            let loop = iteration.isEmpty ? "" : "[\(iteration.joined(separator: ", "))]"
            return "\(page ?? "_"):\(site)\(loop)"
        }

        public var description: String { "\(place)@\(arguments)" }
    }

    /// One call as the ledger records it.
    struct CallRecord: Sendable, Hashable {
        public let identity: CallIdentity
        /// `mail.search`.
        public let function: String
        public let effect: Effect
        public let repeats: Repeats
        public let arguments: [ArgumentValue]
        /// 1, then one more for each release of this identity.
        public let generation: Int
        /// The source asked for this run with `again`.
        public let again: Bool

        public init(
            identity: CallIdentity,
            function: String,
            effect: Effect,
            repeats: Repeats,
            arguments: [ArgumentValue],
            generation: Int = 1,
            again: Bool = false
        ) {
            self.identity = identity
            self.function = function
            self.effect = effect
            self.repeats = repeats
            self.arguments = arguments
            self.generation = generation
            self.again = again
        }
    }

    /// Who settled an unknown outcome.
    enum SettledBy: String, Sendable, Hashable {
        /// The domain's settle check.
        case check
        /// The owner, from the interface.
        case owner
    }

    struct LedgerEntry: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            /// Written before the call is handed to the executor.
            case intended(CallRecord)
            case completed(CallRecord, Value)
            /// The tool did not apply it.
            case failed(CallRecord, String)
            /// It never reached the tool.
            case not_run(CallRecord, String)
            /// It may or may not have taken effect.
            case unknown(CallRecord, String)
            /// An unknown outcome decided: done (with the value found) or not done.
            case settled(CallRecord, done: Bool, value: Value?, by: SettledBy)
            /// The owner allowed a completed guarded call to run once more; the next run of
            /// this identity is generation `generation + 1`.
            case released(CallRecord, by: SettledBy, reason: String?)
            /// Answered from an earlier entry (its sequence number) instead of calling: a read
            /// already done, or a guarded call that is not repeated.
            case reused(CallRecord, Value, from: Int)
            /// A variable got a value: a binding or an assignment.
            case bound(name: String, value: Value)
        }

        /// Position in the ledger, from 0.
        public let sequence: Int
        /// The run that wrote it, from 1.
        public let run: Int
        public let page: String?
        public let range: SourceRange
        public let kind: Kind

        public var call: CallRecord? {
            switch kind {
            case .intended(let call), .completed(let call, _), .failed(let call, _), .not_run(let call, _),
                 .unknown(let call, _), .settled(let call, _, _, _), .released(let call, _, _), .reused(let call, _, _):
                call
            case .bound:
                nil
            }
        }
    }

    /// Where a call stands in its current generation.
    enum CallState: Sendable, Hashable {
        /// Never ran in this generation.
        case new
        /// Ran and did not take effect (failed, not run, settled as not done): may run.
        case runnable
        /// Took effect; `entry` holds the value.
        case done(Value, entry: LedgerEntry)
        /// Started without a known outcome; must be settled before anything repeats it.
        case unknown(LedgerEntry)
    }

    /// A ledger operation the state of the call does not allow.
    struct LedgerRefusal: Error, Sendable, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// The record of a program's runs: every call and every value bound, in order. Entries
    /// are only appended; a rerun adds to the same ledger.
    struct Ledger: Sendable {
        public private(set) var entries: [LedgerEntry] = []
        /// Runs started on this ledger.
        public private(set) var runs = 0

        public init() {}

        mutating func beginRun() -> Int {
            runs += 1
            return runs
        }

        mutating func append(_ kind: LedgerEntry.Kind, run: Int, page: String?, range: SourceRange) {
            entries.append(.init(sequence: entries.count, run: run, page: page, range: range, kind: kind))
        }

        /// The latest entry that answered this exact call (same place, same arguments).
        public func answer(for identity: CallIdentity) -> LedgerEntry? {
            entries.last { entry in
                switch entry.kind {
                case .completed(let call, _), .reused(let call, _, _): call.identity == identity
                default: false
                }
            }
        }

        /// The current generation of a call: 1, plus one per release.
        public func generation(of identity: CallIdentity) -> Int {
            1 + entries.filter { entry in
                if case .released(let call, _, _) = entry.kind { return call.identity == identity }
                return false
            }.count
        }

        /// Where the call stands in its current generation, from its latest entry.
        public func state(of identity: CallIdentity) -> CallState {
            let generation = generation(of: identity)
            for entry in entries.reversed() {
                guard let call = entry.call, call.identity == identity else { continue }
                switch entry.kind {
                case .released:
                    return .new
                case _ where call.generation != generation:
                    continue
                case .completed(_, let value), .reused(_, let value, _):
                    return .done(value, entry: entry)
                case .settled(_, true, let value, _):
                    return .done(value ?? .null, entry: entry)
                case .settled(_, false, _, _), .failed, .not_run:
                    return .runnable
                // An intent without an outcome: the process stopped in between.
                case .intended, .unknown:
                    return .unknown(entry)
                case .bound:
                    continue
                }
            }
            return .new
        }

        /// Calls whose outcome is unknown and waits for a settle check or the owner.
        public var unsettled: [CallRecord] {
            var seen: Set<CallIdentity> = []
            var result: [CallRecord] = []
            for entry in entries.reversed() {
                guard let call = entry.call, !seen.contains(call.identity) else { continue }
                seen.insert(call.identity)
                if case .unknown = state(of: call.identity) { result.insert(call, at: 0) }
            }
            return result
        }

        /// The owner decides an unknown outcome: it happened (with the value, if known) or it
        /// did not. Never available to the program itself.
        public mutating func settle(_ identity: CallIdentity, done: Bool, value: Value? = nil) throws {
            guard case .unknown(let entry) = state(of: identity), let call = entry.call else {
                throw LedgerRefusal(message: "\(identity.place) has no unknown outcome to settle")
            }
            append(.settled(call, done: done, value: value, by: .owner), run: runs, page: entry.page, range: entry.range)
        }

        /// The owner reopens a completed guarded call: its next run is a new generation.
        /// `.never` calls cannot be released within the goal.
        public mutating func release(_ identity: CallIdentity, reason: String? = nil) throws {
            guard case .done(_, let entry) = state(of: identity), let call = entry.call else {
                throw LedgerRefusal(message: "\(identity.place) has not completed; nothing to release")
            }
            if call.repeats == .never {
                throw LedgerRefusal(message: "\(call.function) never repeats within a goal")
            }
            append(.released(call, by: .owner, reason: reason), run: runs, page: entry.page, range: entry.range)
        }

        /// The entries of one run.
        public func entries(run: Int) -> [LedgerEntry] {
            entries.filter { $0.run == run }
        }

        /// The calls of one run that went to the executor, in order.
        public func executed(run: Int) -> [CallRecord] {
            entries(run: run).compactMap { if case .intended(let call) = $0.kind { call } else { nil } }
        }

        /// The last value bound to `name` (on `page`, nil for top level).
        public func lastValue(of name: String, page: String? = nil) -> Value? {
            entries.last { entry in
                if case .bound(let bound, _) = entry.kind { return bound == name && entry.page == page }
                return false
            }.flatMap { entry in
                if case .bound(_, let value) = entry.kind { return value }
                return nil
            }
        }
    }

    /// How a run uses what the ledger already holds.
    struct RunOptions: Sendable {
        public enum Reuse: Sendable {
            /// Reads and pure calls with the same identity are answered from the ledger.
            case reads
            /// Every call goes to the executor.
            case none
        }

        public var reuse: Reuse

        public init(reuse: Reuse = .reads) {
            self.reuse = reuse
        }
    }

    /// A short, stable hash (64-bit FNV-1a, hex) of a value's text. Stable across processes,
    /// unlike `Hasher`, so ledgers written in one run match in the next.
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}
