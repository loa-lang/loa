import Foundation
import Position

public extension Loa {
    /// A run waiting for the owner. Nothing is lost: answer through the ledger, then run the
    /// program again with it. Everything before the suspension is answered from the ledger,
    /// so the run resumes at the same place without repeating a call.
    struct Suspension: Error, Sendable, CustomStringConvertible {
        public enum Reason: Sendable, Hashable {
            /// `ask(…)`: answer with `Ledger.answer(_:with:)`.
            case question(Question)
            /// `suspend(…)`: continue with `Ledger.answer(_:with: .null)`.
            case pause(Question)
            /// The host holds a call for an approval; run again once it is decided.
            case approval(String)
            /// A guarded call started and nothing could tell whether it took effect:
            /// decide with `Ledger.settle(_:done:value:)`.
            case unknown_outcome(String)
        }

        public let reason: Reason
        /// The call, question or pause it waits on.
        public let call: CallRecord
        public let page: String?
        public let range: SourceRange
        public var line: Int?
        public var column: Int?

        public init(reason: Reason, call: CallRecord, page: String?, range: SourceRange) {
            self.reason = reason
            self.call = call
            self.page = page
            self.range = range
        }

        public var message: String {
            switch reason {
            case .question(let question): "Waiting for an answer: \(question.prompt)"
            case .pause(let question): "Paused: \(question.prompt)"
            case .approval(let message): "\(call.function) waits for approval: \(message)"
            case .unknown_outcome(let reason): "\(call.function): outcome unknown (\(reason)); it must be settled before the page continues"
            }
        }

        public var description: String {
            let position = line.flatMap { line in column.map { "\(line):\($0): " } } ?? ""
            return "\(position)\(message)"
        }

        func located(in map: Position.TextMap) -> Self {
            var located = self
            let location = Loa.location(of: range.lowerBound, in: map)
            located.line = location?.line
            located.column = location?.column
            return located
        }
    }

    /// Why a run stopped before its end.
    struct RuntimeFailure: Error, Sendable, CustomStringConvertible {
        public let message: String
        public let range: SourceRange
        /// The page that stopped; nil for top-level statements.
        public let page: String?
        public var line: Int?
        public var column: Int?

        public init(message: String, range: SourceRange, page: String?) {
            self.message = message
            self.range = range
            self.page = page
        }

        public var description: String {
            let position = line.flatMap { line in column.map { "\(line):\($0): " } } ?? ""
            let page = page.map { " (page \($0))" } ?? ""
            return "\(position)\(message)\(page)"
        }

        func located(in map: Position.TextMap) -> Self {
            var located = self
            let location = Loa.location(of: range.lowerBound, in: map)
            located.line = location?.line
            located.column = location?.column
            return located
        }
    }

    /// A program that did not pass the checker; it is not run.
    struct CheckFailure: Error, Sendable, CustomStringConvertible {
        public let diagnostics: [Diagnostic]

        public var description: String {
            diagnostics.map(\.description).joined(separator: "\n")
        }
    }

    struct RunResult: Sendable {
        /// Each page's bindings, in the order they were bound, for pages that ran (completely
        /// or up to their failure).
        public let pages: [String: RecordValue]
        /// Bindings of top-level statements.
        public let bindings: RecordValue
        /// Pages that ran to the end, in order.
        public let completed: [String]
        public let failure: RuntimeFailure?
        /// Set when the run waits for the owner; the program has not failed.
        public let suspension: Suspension?
        /// An error the executor threw (a pending approval, cancellation). The call it was
        /// running is recorded as `pending`, so a later run tries it again.
        public let interruption: (any Error)?
        /// The ledger with this run's entries appended.
        public let ledger: Ledger
        /// This run's number in the ledger.
        public let run: Int

        /// Ran to the end.
        public var succeeded: Bool { failure == nil && suspension == nil && interruption == nil }

        /// The value bound to `name` on `page`, or at top level when `page` is nil.
        public func value(_ name: String, page: String? = nil) -> Value? {
            guard let page else { return bindings[name] }
            return pages[page]?[name]
        }
    }

    /// Runs a checked program. Catalog calls go to `executor`, unless `ledger` already answers
    /// them (see `RunOptions`); everything else is evaluated here. A failure stops the run and
    /// is returned with the values computed so far. Pass the returned ledger to the next run.
    static func run(
        _ program: Program,
        catalog: Catalog,
        executor: any Executor,
        globals: [String: Value] = [:],
        ledger: Ledger = .init(),
        options: RunOptions = .init()
    ) async -> RunResult {
        let interpreter = Interpreter(
            catalog: catalog,
            executor: executor,
            globals: globals,
            ledger: ledger,
            options: options
        )
        return await interpreter.run(program)
    }

    /// Parses, checks and runs a source. Throws a `SyntaxFailure` or `CheckFailure` when the
    /// program does not get as far as running; runtime failures are in the result.
    static func run(
        _ source: String,
        catalog: Catalog,
        executor: any Executor,
        globals: [String: Value] = [:],
        ledger: Ledger = .init(),
        options: RunOptions = .init(),
        filePath: String? = nil
    ) async throws -> RunResult {
        let program = try parse(source, filePath: filePath)
        let checked = check(program, catalog: catalog)
        let map = Position.TextMap(source: source)
        guard checked.isValid else {
            throw CheckFailure(diagnostics: checked.errors.map { $0.located(in: map) })
        }
        let result = await run(
            program,
            catalog: catalog,
            executor: executor,
            globals: globals,
            ledger: ledger,
            options: options
        )
        return RunResult(
            pages: result.pages,
            bindings: result.bindings,
            completed: result.completed,
            failure: result.failure?.located(in: map),
            suspension: result.suspension?.located(in: map),
            interruption: result.interruption,
            ledger: result.ledger,
            run: result.run
        )
    }
}

/// Evaluates statements and expressions. One instance runs one program once.
final class Interpreter {
    typealias Value = Loa.Value

    struct Variable {
        var value: Value
        let mutable: Bool
    }

    /// A block's variables, in the order they were bound.
    struct Scope {
        var variables: [String: Variable] = [:]
        var order: [String] = []

        var record: Loa.RecordValue {
            .init(nil, order.compactMap { name in variables[name].map { .init(name, $0.value) } })
        }
    }

    enum Flow {
        case normal
        case breakLoop
        case continueLoop
        case returned(Value?)
    }

    struct Stop: Error {
        let message: String
        let range: Loa.SourceRange
    }

    /// An error the executor threw; the run stops and hands it to the host.
    struct HostInterruption: Error {
        let error: any Error
    }

    let catalog: Loa.Catalog
    let executor: any Loa.Executor
    let globals: [String: Value]
    var programTypes: [String: Loa.TypeExpression] = [:]
    var pageNames: Set<String> = []
    var pageValues: [String: Loa.RecordValue] = [:]
    var scopes: [Scope] = [Scope()]
    var currentPage: String?

    var ledger: Loa.Ledger
    let options: Loa.RunOptions
    var runNumber = 0
    /// The binding the current statement anchors its calls to (`prepare.found`), if any.
    var anchor: String?
    /// Names of the enclosing steps.
    var steps: [String] = []
    /// One key per enclosing loop iteration.
    var iterations: [String] = []
    /// Call sites of the current page by source offset, named once on first use.
    var sites: [Int: String] = [:]
    var siteCounts: [String: Int] = [:]

    init(
        catalog: Loa.Catalog,
        executor: any Loa.Executor,
        globals: [String: Value],
        ledger: Loa.Ledger,
        options: Loa.RunOptions
    ) {
        self.catalog = catalog
        self.executor = executor
        self.globals = globals
        self.ledger = ledger
        self.options = options
    }

    // MARK: Program

    func run(_ program: Loa.Program) async -> Loa.RunResult {
        for declaration in program.types {
            programTypes[declaration.name] = declaration.type
        }
        pageNames = Set(program.pages.map(\.name))
        runNumber = ledger.beginRun()
        var completed: [String] = []
        var failure: Loa.RuntimeFailure?
        var suspension: Loa.Suspension?
        var interruption: (any Error)?

        items: for item in program.items {
            switch item {
            case .page(let page):
                currentPage = page.name
                sites = [:]
                siteCounts = [:]
                scopes.append(Scope())
                do {
                    _ = try await execute(page.body)
                    completed.append(page.name)
                } catch let stop as Stop {
                    failure = .init(message: stop.message, range: stop.range, page: page.name)
                } catch let waiting as Loa.Suspension {
                    suspension = waiting
                } catch let host as HostInterruption {
                    interruption = host.error
                } catch {
                    failure = .init(message: "\(error)", range: page.range, page: page.name)
                }
                // The page's own scope is the second; blocks above it are discarded on a stop.
                pageValues[page.name] = scopes[1].record
                scopes = [scopes[0]]
                currentPage = nil
                sites = [:]
                siteCounts = [:]
                if failure != nil || suspension != nil || interruption != nil { break items }
            case .statement(let statement):
                do {
                    if case .returned = try await execute(statement) { break items }
                } catch let stop as Stop {
                    failure = .init(message: stop.message, range: stop.range, page: nil)
                    scopes = [scopes[0]]
                    break items
                } catch let waiting as Loa.Suspension {
                    suspension = waiting
                    scopes = [scopes[0]]
                    break items
                } catch let host as HostInterruption {
                    interruption = host.error
                    scopes = [scopes[0]]
                    break items
                } catch {
                    failure = .init(message: "\(error)", range: statement.range, page: nil)
                    break items
                }
            case .import, .type:
                break
            }
        }

        return Loa.RunResult(
            pages: pageValues,
            bindings: scopes[0].record,
            completed: completed,
            failure: failure,
            suspension: suspension,
            interruption: interruption,
            ledger: ledger,
            run: runNumber
        )
    }

    // MARK: Statements

    func execute(_ statements: [Loa.Statement]) async throws -> Flow {
        for statement in statements {
            let flow = try await execute(statement)
            if case .normal = flow { continue }
            return flow
        }
        return .normal
    }

    func scoped(_ statements: [Loa.Statement], with variables: [String: Variable] = [:]) async throws -> Flow {
        scopes.append(Scope(variables: variables, order: Array(variables.keys)))
        defer { scopes.removeLast() }
        return try await execute(statements)
    }

    func execute(_ statement: Loa.Statement) async throws -> Flow {
        let enclosing = anchor
        defer { anchor = enclosing }
        if case .binding(let binding) = statement.kind {
            anchor = (steps + [binding.name]).joined(separator: ".")
        } else {
            anchor = nil
        }

        switch statement.kind {
        case .binding(let binding):
            var value = try await evaluate(binding.value)
            if let type = binding.type {
                value = try await coerce(value, to: type)
            }
            declare(binding.name, value, mutable: binding.mutable)
            ledger.append(.bound(name: binding.name, value: value), run: runNumber, page: currentPage, range: statement.range)
            return .normal

        case .assignment(let target, let op, let value):
            let name = try await assign(target, op, try await evaluate(value), at: statement.range)
            if let updated = lookup(name)?.variable.value {
                ledger.append(.bound(name: name, value: updated), run: runNumber, page: currentPage, range: statement.range)
            }
            return .normal

        case .expression(let expression):
            // A failure nobody looks at stops the page; bind it to handle it.
            if case .failure(let failure) = try await evaluate(expression) {
                throw Stop(message: failure.description, range: expression.range)
            }
            return .normal

        case .for(let element, let sequence, let body):
            let elements: [Value]
            switch try await evaluate(sequence) {
            case .array(let items):
                elements = items
            case .dictionary(let entries):
                elements = entries.map { .record(.init(nil, [.init("key", $0.key), .init("value", $0.value)])) }
            case .failure(let failure):
                throw Stop(message: failure.description, range: sequence.range)
            case let other:
                throw Stop(message: "'for' needs a list, got \(other)", range: sequence.range)
            }
            for item in elements {
                iterations.append("\(element)=\(iterationKey(item))")
                defer { iterations.removeLast() }
                let flow = try await scoped(body, with: [element: Variable(value: item, mutable: false)])
                switch flow {
                case .normal, .continueLoop: continue
                case .breakLoop: return .normal
                case .returned: return flow
                }
            }
            return .normal

        case .if(let condition, let then, let otherwise):
            guard case .bool(let holds) = try await evaluate(condition) else {
                throw Stop(message: "A condition must be bool", range: condition.range)
            }
            if holds { return try await scoped(then) }
            if let otherwise { return try await scoped(otherwise) }
            return .normal

        case .return(let value):
            guard let value else { return .returned(nil) }
            return .returned(try await evaluate(value))

        case .break:
            return .breakLoop

        case .continue:
            return .continueLoop

        case .step(let name, let body):
            // Steps structure a page; their bindings belong to the page.
            steps.append(name)
            defer { steps.removeLast() }
            return try await execute(body)
        }
    }

    /// A loop element's key in call identities: its `id` or `name` when it has one, short
    /// values as written, anything else by hash.
    func iterationKey(_ value: Value) -> String {
        if case .record(let record) = value {
            for field in ["id", "name"] {
                if let key = record[field], key.text.count <= 40 { return key.text }
            }
        }
        let text = value.text
        return text.count <= 40 ? text : "#" + Loa.stableHash(text)
    }

    /// The identity of a call at `range`, named once per page on first use.
    func identity(of function: String, at range: Loa.SourceRange, arguments: [Loa.ArgumentValue]) -> Loa.CallIdentity {
        let site: String
        if let named = sites[range.lowerBound] {
            site = named
        } else {
            let prefix = "\(anchor ?? "_")/\(function)"
            let ordinal = siteCounts[prefix, default: 0]
            siteCounts[prefix] = ordinal + 1
            site = "\(prefix)#\(ordinal)"
            sites[range.lowerBound] = site
        }
        return Loa.CallIdentity(
            page: currentPage,
            site: site,
            iteration: iterations,
            arguments: Loa.stableHash(arguments.map(\.description).joined(separator: ", "))
        )
    }

    func declare(_ name: String, _ value: Value, mutable: Bool) {
        if scopes[scopes.count - 1].variables[name] == nil {
            scopes[scopes.count - 1].order.append(name)
        }
        scopes[scopes.count - 1].variables[name] = Variable(value: value, mutable: mutable)
    }

    func lookup(_ name: String) -> (scope: Int, variable: Variable)? {
        for index in scopes.indices.reversed() {
            if let variable = scopes[index].variables[name] { return (index, variable) }
        }
        return nil
    }

    // MARK: Assignment

    enum PathStep {
        case field(String)
        case index(Value)
    }

    /// Applies an assignment; returns the name of the variable it changed.
    @discardableResult
    func assign(_ target: Loa.Expression, _ op: Loa.AssignmentOperator, _ value: Value, at range: Loa.SourceRange) async throws -> String {
        var path: [PathStep] = []
        var root = target
        while true {
            switch root.kind {
            case .member(let base, let name):
                path.insert(.field(name), at: 0)
                root = base
                continue
            case .subscript(let base, let arguments):
                guard let index = arguments.first else { throw Stop(message: "A subscript needs an index", range: root.range) }
                path.insert(.index(try await evaluate(index.value)), at: 0)
                root = base
                continue
            default:
                break
            }
            break
        }
        guard case .identifier(let name) = root.kind, let found = lookup(name) else {
            throw Stop(message: "Only variables and their fields can be assigned", range: target.range)
        }
        guard found.variable.mutable else {
            throw Stop(message: "'\(name)' is a constant (let)", range: target.range)
        }
        let updated = try update(found.variable.value, path[...], at: range) { current in
            try self.combine(current, op, value, at: range)
        }
        scopes[found.scope].variables[name]?.value = updated
        return name
    }

    func update(
        _ container: Value,
        _ path: ArraySlice<PathStep>,
        at range: Loa.SourceRange,
        _ change: (Value) throws -> Value
    ) throws -> Value {
        guard let step = path.first else { return try change(container) }
        let rest = path.dropFirst()
        switch (container, step) {
        case (.record(var record), .field(let name)):
            guard let current = record[name] else {
                throw Stop(message: "\(container) has no field '\(name)'", range: range)
            }
            record[name] = try update(current, rest, at: range, change)
            return .record(record)
        case (.array(var elements), .index(.int(let index))):
            guard elements.indices.contains(index) else {
                throw Stop(message: "Index \(index) is out of range (count \(elements.count))", range: range)
            }
            elements[index] = try update(elements[index], rest, at: range, change)
            return .array(elements)
        case (.dictionary(var entries), .index(let key)):
            if let position = entries.firstIndex(where: { equal($0.key, key) }) {
                entries[position].value = try update(entries[position].value, rest, at: range, change)
            } else {
                entries.append(.init(key, try update(.null, rest, at: range, change)))
            }
            return .dictionary(entries)
        default:
            throw Stop(message: "Cannot assign into \(container)", range: range)
        }
    }

    func combine(_ current: Value, _ op: Loa.AssignmentOperator, _ value: Value, at range: Loa.SourceRange) throws -> Value {
        if case .failure(let failure) = value, op != .assign {
            throw Stop(message: failure.description, range: range)
        }
        switch op {
        case .assign:
            return value
        case .add:
            switch (current, value) {
            case (.array(let elements), .array(let more)):
                return .array(elements + more)
            case (.array(let elements), let element):
                return .array(elements + [element])
            case (.string(let text), .string(let more)):
                return .string(text + more)
            // A missing dictionary entry counts from zero (`counts[key] += 1`).
            case (.null, .array), (.null, .string):
                return value
            case (.null, .int), (.null, .double):
                return try arithmetic(.add, .int(0), value, at: range)
            default:
                return try arithmetic(.add, current, value, at: range)
            }
        case .subtract:
            if case .null = current { return try arithmetic(.subtract, .int(0), value, at: range) }
            return try arithmetic(.subtract, current, value, at: range)
        }
    }

    // MARK: Types

    /// Applies a declared type: records get their name and missing defaults, ints become
    /// doubles where a double is declared.
    func coerce(_ value: Value, to type: Loa.TypeExpression) async throws -> Value {
        switch (type, value) {
        case (.optional, .null):
            return value
        case (.optional(let wrapped), _):
            return try await coerce(value, to: wrapped)
        case (.array(let element), .array(let elements)):
            var coerced: [Value] = []
            for item in elements { coerced.append(try await coerce(item, to: element)) }
            return .array(coerced)
        case (.named(let path), .int(let number)) where path == ["double"] || path == ["Double"]:
            return .double(Double(number))
        case (.named(let path), .record(var record)) where path.count == 1:
            let name = path[0]
            if case .object(let fields) = programTypes[name] {
                for field in fields where record[field.name] == nil {
                    if let defaultValue = field.defaultValue {
                        record[field.name] = try await evaluate(defaultValue)
                    } else if case .optional = field.type {
                        record[field.name] = .null
                    }
                }
                // Declared order, then anything extra.
                let declared = fields.compactMap { field in record[field.name].map { Loa.FieldValue(field.name, $0) } }
                let extra = record.fields.filter { value in !fields.contains { $0.name == value.name } }
                record.fields = declared + extra
            }
            if record.name == nil, programTypes[name] != nil || catalog.types[name] != nil {
                record.name = name
            }
            return .record(record)
        default:
            return value
        }
    }

    // MARK: Expressions

    func evaluate(_ expression: Loa.Expression, root: Value? = nil) async throws -> Value {
        let range = expression.range
        switch expression.kind {
        case .identifier(let name):
            if let found = lookup(name) { return found.variable.value }
            if pageNames.contains(name) {
                guard let page = pageValues[name] else {
                    throw Stop(message: "Page '\(name)' has not run yet", range: range)
                }
                return .record(Loa.RecordValue(name, page.fields))
            }
            if let global = globals[name] { return global }
            if catalog.domain(named: name) != nil {
                throw Stop(message: "'\(name)' is a domain; call one of its functions", range: range)
            }
            throw Stop(message: "Cannot find '\(name)'", range: range)

        case .string(let literal):
            var text = ""
            for segment in literal.segments {
                switch segment {
                case .text(let part):
                    text += part
                case .interpolation(let part):
                    let value = try await evaluate(part, root: root)
                    if case .failure(let failure) = value {
                        throw Stop(message: failure.description, range: part.range)
                    }
                    text += value.text
                }
            }
            return .string(text)

        case .number(.integer(let number)):
            return .int(number)

        case .number(.decimal(let number)):
            return .double(NSDecimalNumber(decimal: number).doubleValue)

        case .boolean(let flag):
            return .bool(flag)

        case .null:
            return .null

        case .implicit_member(let name):
            // A field of the element inside a key path (`.where(.unread)`); otherwise a case.
            if let root {
                if case .record(let record) = root, record[name] == nil, name != "failed", name != "error" {
                    return .case(.init(name))
                }
                return try member(of: root, name, at: range)
            }
            return .case(.init(name))

        case .member(let base, let name):
            return try member(of: try await evaluate(base, root: root), name, at: range)

        case .call(let callee, let arguments):
            return try await call(callee, arguments, root: root, at: range)

        case .subscript(let base, let arguments):
            let container = try await evaluate(base, root: root)
            guard let first = arguments.first else { throw Stop(message: "A subscript needs an index", range: range) }
            let index = try await evaluate(first.value, root: root)
            switch (container, index) {
            case (.array(let elements), .int(let position)):
                guard elements.indices.contains(position) else {
                    throw Stop(message: "Index \(position) is out of range (count \(elements.count))", range: range)
                }
                return elements[position]
            case (.dictionary(let entries), _):
                return entries.first { equal($0.key, index) }?.value ?? .null
            case (.null, _):
                return .null
            case (.failure(let failure), _):
                throw Stop(message: failure.description, range: base.range)
            default:
                throw Stop(message: "\(container) cannot be subscripted with \(index)", range: range)
            }

        case .object(let fields):
            var values: [Loa.FieldValue] = []
            for field in fields {
                values.append(.init(field.name, try await evaluate(field.value, root: root)))
            }
            return .record(.init(nil, values))

        case .array(let elements):
            var values: [Value] = []
            for element in elements { values.append(try await evaluate(element, root: root)) }
            return .array(values)

        case .empty_dictionary:
            return .dictionary([])

        case .prefix(.again, let operand):
            guard case .call(let callee, let arguments) = operand.kind else {
                throw Stop(message: "'again' applies to a call", range: range)
            }
            return try await call(callee, arguments, root: root, at: operand.range, again: true)

        case .prefix(let op, let operand):
            let value = try await evaluate(operand, root: root)
            switch (op, value) {
            case (.try, .failure(let failure)):
                throw Stop(message: failure.description, range: range)
            case (.try, _):
                return value
            case (.not, .bool(let flag)):
                return .bool(!flag)
            case (.negate, .int(let number)):
                let (negated, overflow) = (0).subtractingReportingOverflow(number)
                if overflow { throw Stop(message: "Integer overflow", range: range) }
                return .int(negated)
            case (.negate, .double(let number)):
                return .double(-number)
            case (_, .failure(let failure)):
                throw Stop(message: failure.description, range: operand.range)
            default:
                throw Stop(message: "'\(op.rawValue)' does not apply to \(value)", range: range)
            }

        case .binary(let op, let lhs, let rhs):
            return try await binary(op, lhs, rhs, root: root, at: range)
        }
    }

    func binary(_ op: Loa.BinaryOperator, _ lhs: Loa.Expression, _ rhs: Loa.Expression, root: Value?, at range: Loa.SourceRange) async throws -> Value {
        switch op {
        case .pipe:
            // `value |> f(…)` calls f with the value as its first argument.
            let value = try await evaluate(lhs, root: root)
            if case .call(let callee, let arguments) = rhs.kind {
                return try await call(callee, arguments, root: root, at: range, prepending: value)
            }
            return try await call(rhs, [], root: root, at: range, prepending: value)

        case .coalesce:
            let value = try await evaluate(lhs, root: root)
            if case .null = value { return try await evaluate(rhs, root: root) }
            return value

        case .or, .and:
            guard case .bool(let left) = try await evaluate(lhs, root: root) else {
                throw Stop(message: "'\(op.rawValue)' needs bools", range: lhs.range)
            }
            if op == .or, left { return .bool(true) }
            if op == .and, !left { return .bool(false) }
            guard case .bool(let right) = try await evaluate(rhs, root: root) else {
                throw Stop(message: "'\(op.rawValue)' needs bools", range: rhs.range)
            }
            return .bool(right)

        default:
            let left = try await evaluate(lhs, root: root)
            let right = try await evaluate(rhs, root: root)
            for (side, value) in [(lhs, left), (rhs, right)] {
                if case .failure(let failure) = value {
                    throw Stop(message: failure.description, range: side.range)
                }
            }
            switch op {
            case .equal:
                return .bool(equal(left, right))
            case .not_equal:
                return .bool(!equal(left, right))
            case .less, .less_equal, .greater, .greater_equal:
                guard let order = compare(left, right) else {
                    throw Stop(message: "Cannot compare \(left) with \(right)", range: range)
                }
                switch op {
                case .less: return .bool(order == .orderedAscending)
                case .less_equal: return .bool(order != .orderedDescending)
                case .greater: return .bool(order == .orderedDescending)
                default: return .bool(order != .orderedAscending)
                }
            case .closed_range, .half_open_range:
                guard case .int(let lower) = left, case .int(let upper) = right else {
                    throw Stop(message: "A range needs int bounds", range: range)
                }
                let end = op == .closed_range ? upper + 1 : upper
                return .array(end > lower ? (lower..<end).map(Value.int) : [])
            default:
                return try arithmetic(op, left, right, at: range)
            }
        }
    }

    func arithmetic(_ op: Loa.BinaryOperator, _ left: Value, _ right: Value, at range: Loa.SourceRange) throws -> Value {
        switch (left, right) {
        case (.string(let a), .string(let b)) where op == .add:
            return .string(a + b)
        case (.int(let a), .int(let b)):
            let result: (partialValue: Int, overflow: Bool)
            switch op {
            case .add: result = a.addingReportingOverflow(b)
            case .subtract: result = a.subtractingReportingOverflow(b)
            case .multiply: result = a.multipliedReportingOverflow(by: b)
            case .divide, .remainder:
                guard b != 0 else { throw Stop(message: "Division by zero", range: range) }
                result = op == .divide ? a.dividedReportingOverflow(by: b) : a.remainderReportingOverflow(dividingBy: b)
            default:
                throw Stop(message: "'\(op.rawValue)' does not apply to numbers", range: range)
            }
            if result.overflow { throw Stop(message: "Integer overflow", range: range) }
            return .int(result.partialValue)
        default:
            guard let a = double(left), let b = double(right) else {
                throw Stop(message: "'\(op.rawValue)' needs numbers, got \(left) and \(right)", range: range)
            }
            switch op {
            case .add: return .double(a + b)
            case .subtract: return .double(a - b)
            case .multiply: return .double(a * b)
            case .divide:
                guard b != 0 else { throw Stop(message: "Division by zero", range: range) }
                return .double(a / b)
            case .remainder:
                guard b != 0 else { throw Stop(message: "Division by zero", range: range) }
                return .double(a.truncatingRemainder(dividingBy: b))
            default:
                throw Stop(message: "'\(op.rawValue)' does not apply to numbers", range: range)
            }
        }
    }

    func double(_ value: Value) -> Double? {
        switch value {
        case .int(let number): Double(number)
        case .double(let number): number
        default: nil
        }
    }

    /// Equality with ints and doubles compared by value.
    func equal(_ left: Value, _ right: Value) -> Bool {
        if let a = double(left), let b = double(right) { return a == b }
        return left == right
    }

    func compare(_ left: Value, _ right: Value) -> ComparisonResult? {
        if let a = double(left), let b = double(right) {
            return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
        }
        switch (left, right) {
        case (.string(let a), .string(let b)):
            return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
        case (.bool(let a), .bool(let b)):
            return a == b ? .orderedSame : (!a ? .orderedAscending : .orderedDescending)
        default:
            return nil
        }
    }

    // MARK: Members

    func member(of value: Value, _ name: String, at range: Loa.SourceRange) throws -> Value {
        if case .failure(let failure) = value {
            switch name {
            case "failed": return .bool(true)
            case "error":
                var fields: [Loa.FieldValue] = [.init("message", .string(failure.message))]
                if let function = failure.function { fields.append(.init("function", .string(function))) }
                return .record(.init("Error", fields))
            default:
                throw Stop(message: failure.description, range: range)
            }
        }
        switch (value, name) {
        case (.record(let record), _) where record[name] != nil:
            return record[name]!
        case (_, "failed"):
            return .bool(false)
        case (_, "error"):
            return .null
        // Members read through a missing optional value.
        case (.null, _):
            return .null
        case (.array(let elements), "count"):
            return .int(elements.count)
        case (.array(let elements), "is_empty"):
            return .bool(elements.isEmpty)
        case (.dictionary(let entries), "count"):
            return .int(entries.count)
        case (.dictionary(let entries), "keys"):
            return .array(entries.map(\.key))
        case (.dictionary(let entries), "values"):
            return .array(entries.map(\.value))
        case (.string(let text), "count"):
            return .int(text.count)
        case (.record(let record), _):
            throw Stop(message: "\(record.name ?? "The record") has no field '\(name)'", range: range)
        default:
            throw Stop(message: "\(value) has no member '\(name)'", range: range)
        }
    }

    // MARK: Calls

    func call(
        _ callee: Loa.Expression,
        _ arguments: [Loa.Argument],
        root: Value?,
        at range: Loa.SourceRange,
        prepending first: Value? = nil,
        again: Bool = false
    ) async throws -> Value {
        switch callee.kind {
        // `.minutes(30)`: a case with associated values.
        case .implicit_member(let name) where root == nil:
            var values: [Loa.ArgumentValue] = first.map { [.init(nil, $0)] } ?? []
            for argument in arguments {
                values.append(.init(argument.label, try await evaluate(argument.value)))
            }
            return .case(.init(name, values))

        // `.contains("x")` inside a key path: a method of the element itself.
        case .implicit_member(let name):
            return try await method(name, on: root!, arguments, root: root, at: range)

        case .member(let base, let name):
            if case .identifier(let domainName) = base.kind, lookup(domainName) == nil,
               let domain = catalog.domain(named: domainName) {
                guard let function = domain.function(named: name) else {
                    throw Stop(message: "\(domain.name) has no function '\(name)'", range: callee.range)
                }
                return try await call(function, in: domain, arguments, root: root, at: range, prepending: first, again: again)
            }
            let receiver = try await evaluate(base, root: root)
            if first != nil {
                throw Stop(message: "'|>' can only pass a value to a function", range: range)
            }
            return try await method(name, on: receiver, arguments, root: root, at: range)

        case .identifier(let name) where lookup(name) == nil && Checker.builtins.contains(name):
            return try await builtin(name, arguments, root: root, at: range)

        default:
            throw Stop(message: "This is not callable", range: callee.range)
        }
    }

    func call(
        _ function: Loa.Function,
        in domain: Loa.Domain,
        _ arguments: [Loa.Argument],
        root: Value?,
        at range: Loa.SourceRange,
        prepending first: Value?,
        again: Bool
    ) async throws -> Value {
        let qualified = "\(domain.name).\(function.name)"
        var values: [Loa.ArgumentValue] = first.map { [.init(nil, $0)] } ?? []
        for argument in arguments {
            let value = try await evaluate(argument.value, root: root)
            // A failed result cannot be passed on; the page stops with its reason.
            if case .failure(let failure) = value {
                let label = argument.label.map { "'\($0)' of " } ?? ""
                throw Stop(message: "Argument \(label)\(qualified): \(failure.description)", range: argument.value.range)
            }
            values.append(.init(argument.label, value))
        }
        let callIdentity = identity(of: qualified, at: range, arguments: values)
        let call = Loa.Call(
            domain: domain.name,
            function: function.name,
            arguments: values,
            effect: function.effect,
            page: currentPage,
            range: range,
            identity: callIdentity
        )
        func record(generation: Int) -> Loa.CallRecord {
            .init(
                identity: callIdentity,
                function: qualified,
                effect: function.effect,
                repeats: function.repeats,
                arguments: values,
                generation: generation,
                again: again
            )
        }

        // Safe calls may run again; a read already answered for this exact call is reused.
        if function.repeats == .safe {
            if options.reuse == .reads, function.effect <= .read, let answer = ledger.answer(for: callIdentity) {
                let value: Value
                switch answer.kind {
                case .completed(_, let answered), .reused(_, let answered, _): value = answered
                default: value = .null
                }
                ledger.append(.reused(record(generation: 1), value, from: answer.sequence), run: runNumber, page: currentPage, range: range)
                return value
            }
            return try await perform(call, record(generation: 1), function: function)
        }

        // Guarded and never-repeating calls run once per generation.
        let generation = ledger.generation(of: callIdentity)
        switch ledger.state(of: callIdentity) {
        case .done(let value, let entry):
            let previous = entry.call ?? record(generation: generation)
            // `again` is satisfied once a run that asked for it has completed.
            guard again, !previous.again else {
                ledger.append(.reused(record(generation: generation), value, from: entry.sequence), run: runNumber, page: currentPage, range: range)
                return value
            }
            if function.repeats == .never {
                throw Stop(message: "\(qualified) never repeats within a goal", range: range)
            }
            switch await executor.release(call, previous: previous) {
            case .approved(let reason):
                ledger.append(.released(previous, by: .owner, reason: reason), run: runNumber, page: currentPage, range: range)
                return try await perform(call, record(generation: generation + 1), function: function)
            case .denied:
                throw Stop(
                    message: "\(qualified) already ran (run \(entry.run)) and the owner did not release it",
                    range: range
                )
            }

        case .unknown(let entry):
            let previous = entry.call ?? record(generation: generation)
            switch try await settle(call, previous, function: function, reason: "an earlier run stopped before its outcome was known") {
            case .some(let value): return value
            case .none: return try await perform(call, record(generation: generation), function: function)
            }

        case .new, .runnable:
            return try await perform(call, record(generation: generation), function: function)
        }
    }

    /// `ask` and `suspend`: answered from the ledger when the owner has answered, otherwise
    /// the run suspends with the question.
    func builtin(_ name: String, _ arguments: [Loa.Argument], root: Value?, at range: Loa.SourceRange) async throws -> Value {
        guard name == "ask" || name == "suspend" else {
            throw Stop(message: "'\(name)' needs a host that runs it, which is not available yet", range: range)
        }
        var values: [Loa.ArgumentValue] = []
        for argument in arguments {
            let value = try await evaluate(argument.value, root: root)
            if case .failure(let failure) = value {
                throw Stop(message: failure.description, range: argument.value.range)
            }
            values.append(.init(argument.label, value))
        }
        var options: [Value]?
        if let given = values.first(where: { $0.label == "options" })?.value {
            guard case .array(let list) = given else {
                throw Stop(message: "The options of ask must be a list", range: range)
            }
            options = list
        }
        let question = Loa.Question(
            kind: name == "ask" ? .question : .pause,
            prompt: values.first { $0.label == nil }?.value.text ?? "",
            options: options,
            multiple: values.first { $0.label == "multiple" }?.value == .bool(true)
        )
        let callIdentity = identity(of: name, at: range, arguments: values)
        let record = Loa.CallRecord(
            identity: callIdentity,
            function: name,
            effect: name == "ask" ? .ask : .pure,
            repeats: .guarded,
            arguments: values
        )
        if let answer = ledger.answer(to: callIdentity), case .answered(_, let value) = answer.kind {
            ledger.append(.reused(record, value, from: answer.sequence), run: runNumber, page: currentPage, range: range)
            return name == "suspend" ? .null : value
        }
        if ledger.question(at: callIdentity) == nil {
            ledger.append(.asked(record, question), run: runNumber, page: currentPage, range: range)
        }
        // A host with an interface answers now; otherwise the run waits for the owner.
        if name == "ask" {
            let call = Loa.Call(
                domain: "loa",
                function: name,
                arguments: values,
                effect: .ask,
                page: currentPage,
                range: range,
                identity: callIdentity
            )
            let answer: Value?
            do {
                answer = try await executor.ask(question, call: call)
            } catch {
                throw HostInterruption(error: error)
            }
            if let answer {
                do {
                    try question.validate(answer)
                } catch {
                    throw Stop(message: "The answer to '\(question.prompt)' does not fit: \(error)", range: range)
                }
                ledger.append(.answered(record, answer), run: runNumber, page: currentPage, range: range)
                return answer
            }
        }
        throw Loa.Suspension(
            reason: name == "ask" ? .question(question) : .pause(question),
            call: record,
            page: currentPage,
            range: range
        )
    }

    /// Hands a call to the executor between an `intended` entry and its outcome.
    func perform(_ call: Loa.Call, _ record: Loa.CallRecord, function: Loa.Function) async throws -> Value {
        ledger.append(.intended(record), run: runNumber, page: currentPage, range: call.range)
        let outcome: Loa.CallOutcome
        do {
            outcome = try await executor.call(call)
        } catch {
            // The host stopped before the call ran (an approval it holds): it may run later.
            ledger.append(.pending(record, "\(error)"), run: runNumber, page: currentPage, range: call.range)
            throw HostInterruption(error: error)
        }
        switch outcome {
        case .value(let value):
            ledger.append(.completed(record, value), run: runNumber, page: currentPage, range: call.range)
            return value
        case .failure(let message):
            ledger.append(.failed(record, message), run: runNumber, page: currentPage, range: call.range)
            return .failure(.init(message, function: record.function))
        case .not_run(let message):
            ledger.append(.not_run(record, message), run: runNumber, page: currentPage, range: call.range)
            return .failure(.init(message, function: record.function))
        case .unknown(let message):
            ledger.append(.unknown(record, message), run: runNumber, page: currentPage, range: call.range)
            // A safe call can simply be tried again later.
            if record.repeats == .safe { return .failure(.init(message, function: record.function)) }
            switch try await settle(call, record, function: function, reason: message) {
            case .some(let value): return value
            case .none: return .failure(.init("not done: \(message)", function: record.function))
            }
        case .pending(let message):
            ledger.append(.pending(record, message), run: runNumber, page: currentPage, range: call.range)
            throw Loa.Suspension(reason: .approval(message), call: record, page: currentPage, range: call.range)
        }
    }

    /// Resolves an unknown outcome with the domain's check. Returns the value when the call
    /// took effect, nil when it did not; stops the page when nobody can tell yet.
    func settle(_ call: Loa.Call, _ record: Loa.CallRecord, function: Loa.Function, reason: String) async throws -> Value? {
        let blocked = Loa.Suspension(reason: .unknown_outcome(reason), call: record, page: currentPage, range: call.range)
        guard function.settles else { throw blocked }
        switch await executor.settle(call) {
        case .done(let value):
            ledger.append(.settled(record, done: true, value: value, by: .check), run: runNumber, page: currentPage, range: call.range)
            return value
        case .not_done:
            ledger.append(.settled(record, done: false, value: nil, by: .check), run: runNumber, page: currentPage, range: call.range)
            return nil
        case .cannot_tell:
            throw blocked
        }
    }

    // MARK: Methods

    func method(_ name: String, on receiver: Value, _ arguments: [Loa.Argument], root: Value?, at range: Loa.SourceRange) async throws -> Value {
        if case .failure(let failure) = receiver {
            throw Stop(message: failure.description, range: range)
        }
        if case .null = receiver { return .null }

        /// Evaluates the argument with `label` against the outer key-path root.
        func argument(_ label: String?) async throws -> Value? {
            guard let argument = arguments.first(where: { $0.label == label }) else { return nil }
            return try await evaluate(argument.value, root: root)
        }
        /// The expression of an argument evaluated per element (`.where(.unread)`).
        func keyPath(_ label: String?) throws -> Loa.Expression {
            guard let argument = arguments.first(where: { $0.label == label }) else {
                throw Stop(message: "\(name) needs \(label.map { "'\($0):'" } ?? "an argument")", range: range)
            }
            return argument.value
        }

        switch receiver {
        case .array(let elements):
            switch name {
            case "where":
                let condition = try keyPath(nil)
                var kept: [Value] = []
                for element in elements {
                    guard case .bool(let holds) = try await evaluate(condition, root: element) else {
                        throw Stop(message: "'where' needs a bool condition", range: condition.range)
                    }
                    if holds { kept.append(element) }
                }
                return .array(kept)
            case "map":
                let transform = try keyPath(nil)
                var mapped: [Value] = []
                for element in elements { mapped.append(try await evaluate(transform, root: element)) }
                return .array(mapped)
            case "first", "last":
                if let count = try await argument(nil) {
                    guard case .int(let n) = count, n >= 0 else { throw Stop(message: "\(name)(n) needs a count of 0 or more", range: range) }
                    return .array(Array(name == "first" ? elements.prefix(n) : elements.suffix(n)))
                }
                return (name == "first" ? elements.first : elements.last) ?? .null
            case "only":
                guard elements.count == 1 else {
                    return .failure(.init("expected exactly one, got \(elements.count)", function: "only"))
                }
                return elements[0]
            case "contains":
                guard let needle = try await argument(nil) else { throw Stop(message: "contains needs a value", range: range) }
                return .bool(elements.contains { equal($0, needle) })
            case "sorted":
                let key = try keyPath("by")
                let descending = try await argument("descending") == .bool(true)
                var keyed: [(key: Value, element: Value)] = []
                for element in elements { keyed.append((try await evaluate(key, root: element), element)) }
                for pair in keyed where compare(pair.key, pair.key) == nil {
                    throw Stop(message: "Cannot sort by \(pair.key)", range: key.range)
                }
                // Stable: equal keys keep their order.
                let sorted = keyed.enumerated().sorted { a, b in
                    let order = compare(a.element.key, b.element.key) ?? .orderedSame
                    if order == .orderedSame { return a.offset < b.offset }
                    return descending ? order == .orderedDescending : order == .orderedAscending
                }
                return .array(sorted.map(\.element.element))
            case "unique":
                let key = try keyPath("by")
                var seen: [Value] = []
                var kept: [Value] = []
                for element in elements {
                    let value = try await evaluate(key, root: element)
                    if !seen.contains(where: { equal($0, value) }) {
                        seen.append(value)
                        kept.append(element)
                    }
                }
                return .array(kept)
            case "sum":
                let key = try keyPath("by")
                var total: Value = .int(0)
                for element in elements {
                    total = try arithmetic(.add, total, try await evaluate(key, root: element), at: key.range)
                }
                return total
            case "group":
                let key = try keyPath("by")
                var groups: [Loa.Entry] = []
                for element in elements {
                    let value = try await evaluate(key, root: element)
                    if let index = groups.firstIndex(where: { equal($0.key, value) }),
                       case .array(let members) = groups[index].value {
                        groups[index].value = .array(members + [element])
                    } else {
                        groups.append(.init(value, .array([element])))
                    }
                }
                return .dictionary(groups)
            default:
                break
            }

        case .dictionary(let entries) where name == "sorted":
            let records = Value.array(entries.map { .record(.init(nil, [.init("key", $0.key), .init("value", $0.value)])) })
            return try await method(name, on: records, arguments, root: root, at: range)

        case .string(let text):
            switch name {
            case "contains", "has_prefix", "has_suffix", "split":
                guard case .string(let other) = try await argument(nil) else {
                    throw Stop(message: "\(name) needs a string", range: range)
                }
                switch name {
                case "contains": return .bool(text.contains(other))
                case "has_prefix": return .bool(text.hasPrefix(other))
                case "has_suffix": return .bool(text.hasSuffix(other))
                default: return .array(text.components(separatedBy: other).map(Value.string))
                }
            case "lowercased": return .string(text.lowercased())
            case "uppercased": return .string(text.uppercased())
            case "trimmed": return .string(text.trimmingCharacters(in: .whitespacesAndNewlines))
            default: break
            }

        default:
            break
        }
        throw Stop(message: "\(receiver) has no method '\(name)'", range: range)
    }
}
