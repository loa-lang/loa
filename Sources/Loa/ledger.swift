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
        public let arguments: [ArgumentValue]
    }

    struct LedgerEntry: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            /// Written before the call is handed to the executor.
            case intended(CallRecord)
            case completed(CallRecord, Value)
            case failed(CallRecord, String)
            /// A read answered from an earlier entry (its sequence number) instead of calling.
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
            case .intended(let call), .completed(let call, _), .failed(let call, _), .reused(let call, _, _): call
            case .bound: nil
            }
        }
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
