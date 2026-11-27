import Position

public extension Loa {
    struct Diagnostic: Sendable, CustomStringConvertible {
        public enum Severity: String, Sendable {
            case error
            case warning
        }

        public let severity: Severity
        public let message: String
        public let range: SourceRange
        /// Extra context, such as the signature of the function a call failed against.
        public let note: String?
        public var line: Int?
        public var column: Int?

        public var description: String {
            let position = line.flatMap { line in column.map { "\(line):\($0): " } } ?? ""
            let note = note.map { "\n    \($0)" } ?? ""
            return "\(position)\(severity.rawValue): \(message)\(note)"
        }

        func located(in map: Position.TextMap) -> Self {
            var located = self
            let location = Loa.location(of: range.lowerBound, in: map)
            located.line = location?.line
            located.column = location?.column
            return located
        }
    }

    /// One call with an effect: what the page will do when it runs, known before it runs.
    struct EffectUse: Sendable {
        /// `mail.search`, or a built-in such as `ask`.
        public let function: String
        public let effect: Effect
        public let range: SourceRange
        public let page: String?
        /// Inside a `for`: the call may run many times under one approval.
        public let inLoop: Bool
    }

    struct CheckResult: Sendable {
        public let diagnostics: [Diagnostic]
        public let effects: [EffectUse]

        public var errors: [Diagnostic] { diagnostics.filter { $0.severity == .error } }
        public var isValid: Bool { errors.isEmpty }

        /// The most consequential effect in the program (or one page).
        public func highestEffect(page: String? = nil) -> Effect {
            effects.filter { page == nil || $0.page == page }.map(\.effect).max() ?? .pure
        }
    }

    static func check(_ program: Program, catalog: Catalog) -> CheckResult {
        let checker = Checker(catalog: catalog)
        checker.run(program)
        return CheckResult(diagnostics: checker.diagnostics, effects: checker.effects)
    }

    /// Parses and checks a source; diagnostics carry their line and column.
    static func check(_ source: String, catalog: Catalog, filePath: String? = nil) throws -> CheckResult {
        let program = try parse(source, filePath: filePath)
        let result = check(program, catalog: catalog)
        let map = Position.TextMap(source: source)
        return CheckResult(
            diagnostics: result.diagnostics.map { $0.located(in: map) },
            effects: result.effects
        )
    }
}

/// Resolves names, checks calls, labels, types and mutability, and records effects.
final class Checker {
    typealias ValueType = Loa.ValueType

    struct Variable {
        let type: ValueType
        let mutable: Bool
    }

    /// What an expression names before it is used as a value.
    indirect enum Symbol {
        case value(ValueType)
        case domain(Loa.Domain)
        case page(String)
        case function(Loa.Domain, Loa.Function)
        case builtin(String)
        case method(ValueType, String)
    }

    static let builtins = ["ask", "suspend", "infer", "delegate"]
    /// Runtime objects every program can read: the goal it belongs to and its package.
    static let globals = ["goal", "package"]
    static let primitives: [String: ValueType] = [
        "string": .string, "String": .string,
        "int": .int, "Int": .int,
        "double": .double, "Double": .double,
        "bool": .bool, "Bool": .bool,
        "any": .any, "Any": .any,
    ]

    let catalog: Loa.Catalog
    var programTypes: [String: ValueType] = [:]
    var pageBindings: [String: [String: ValueType]] = [:]
    var scopes: [[String: Variable]] = [[:]]
    var loopDepth = 0
    var currentPage: String?
    var diagnostics: [Loa.Diagnostic] = []
    var effects: [Loa.EffectUse] = []

    init(catalog: Loa.Catalog) {
        self.catalog = catalog
    }

    func run(_ program: Loa.Program) {
        for declaration in program.types {
            if programTypes[declaration.name] != nil || catalog.types[declaration.name] != nil
                || Self.primitives[declaration.name] != nil {
                error("Type '\(declaration.name)' is already defined", declaration.range)
            }
            programTypes[declaration.name] = .named(declaration.name)
        }
        for declaration in program.types {
            programTypes[declaration.name] = valueType(declaration.type, name: declaration.name, at: declaration.range)
        }
        for item in program.imports where catalog.domain(named: item.module) == nil {
            error("Unknown domain '\(item.module)'.\(suggest(item.module, catalog.domainNames))", item.range)
        }
        for page in program.pages {
            if pageBindings[page.name] != nil {
                error("Page '\(page.name)' is defined twice", page.range)
            }
            // Later pages are visible before they are checked; their bindings are `any` until then.
            pageBindings[page.name] = Dictionary(
                Self.bindingNames(page.body).map { ($0, ValueType.any) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        for item in program.items {
            switch item {
            case .page(let page):
                currentPage = page.name
                scopes.append([:])
                check(page.body)
                pageBindings[page.name] = scopes.removeLast().mapValues(\.type)
                currentPage = nil
            case .statement(let statement):
                check(statement)
            case .import, .type:
                break
            }
        }
    }

    static func bindingNames(_ statements: [Loa.Statement]) -> [String] {
        statements.flatMap { statement -> [String] in
            switch statement.kind {
            case .binding(let binding): [binding.name]
            case .step(_, let body): bindingNames(body)
            default: []
            }
        }
    }

    // MARK: Statements

    func check(_ statements: [Loa.Statement]) {
        statements.forEach(check)
    }

    func scoped(_ statements: [Loa.Statement], with variables: [String: Variable] = [:]) {
        scopes.append(variables)
        check(statements)
        scopes.removeLast()
    }

    func check(_ statement: Loa.Statement) {
        switch statement.kind {
        case .binding(let binding):
            if catalog.domain(named: binding.name) != nil || pageBindings[binding.name] != nil {
                error("'\(binding.name)' shadows a \(catalog.domain(named: binding.name) != nil ? "domain" : "page"); choose another name", statement.range)
            }
            let annotation = binding.type.map { valueType($0, at: statement.range) }
            let value = type(binding.value, expected: annotation)
            if let annotation, !assignable(value, to: annotation) {
                error("'\(binding.name)' is declared \(annotation) but its value is \(value)", binding.value.range)
            }
            declare(binding.name, type: annotation ?? value, mutable: binding.mutable, at: statement.range)
        case .assignment(let target, let op, let value):
            checkAssignment(target: target, operator: op, value: value, at: statement.range)
        case .expression(let expression):
            _ = type(expression)
        case .for(let element, let sequence, let body):
            let sequenceType = resolve(type(sequence))
            let elementType: ValueType
            switch sequenceType {
            case .array(let item): elementType = item
            case .dictionary(let key, let value): elementType = .record(.init(nil, [.init("key", key), .init("value", value)]))
            case .any: elementType = .any
            default:
                error("'for' needs a list, got \(sequenceType)", sequence.range)
                elementType = .any
            }
            loopDepth += 1
            scoped(body, with: [element: Variable(type: elementType, mutable: false)])
            loopDepth -= 1
        case .if(let condition, let then, let otherwise):
            let conditionType = resolve(type(condition, expected: .bool))
            if conditionType != .bool && conditionType != .any {
                error("A condition must be bool, got \(conditionType)", condition.range)
            }
            scoped(then)
            if let otherwise { scoped(otherwise) }
        case .return(let value):
            if let value { _ = type(value) }
        case .break, .continue:
            if loopDepth == 0 {
                error("'\(statement.kind.keyword)' outside a loop", statement.range)
            }
        case .step(_, let body):
            // Steps structure a page; their bindings belong to the page.
            check(body)
        }
    }

    func checkAssignment(target: Loa.Expression, operator op: Loa.AssignmentOperator, value: Loa.Expression, at range: Loa.SourceRange) {
        var root = target
        while true {
            switch root.kind {
            case .member(let base, _), .subscript(let base, _): root = base; continue
            default: break
            }
            break
        }
        guard case .identifier(let name) = root.kind else {
            error("Only variables and their fields can be assigned", target.range)
            return
        }
        guard let variable = lookup(name) else {
            error("Cannot find '\(name)' in scope.\(suggest(name, visibleNames))", root.range)
            return
        }
        if !variable.mutable {
            error("'\(name)' is a constant (let); declare it with var to change it", target.range)
        }
        let targetType = type(target)
        let resolved = resolve(targetType)
        switch op {
        case .assign:
            let valueType = type(value, expected: targetType)
            if !assignable(valueType, to: targetType) {
                error("Cannot assign \(valueType) to '\(name)' of type \(targetType)", value.range)
            }
        case .add, .subtract:
            let valueType = type(value, expected: targetType)
            switch resolved {
            case .array(let element) where op == .add:
                if !assignable(valueType, to: element) && !assignable(valueType, to: resolved) {
                    error("Cannot add \(valueType) to \(resolved)", value.range)
                }
            case .int, .double, .any:
                if !isNumeric(valueType) {
                    error("'\(op.rawValue)' needs a number, got \(valueType)", value.range)
                }
            case .string where op == .add:
                if !assignable(valueType, to: .string) {
                    error("Cannot add \(valueType) to a string", value.range)
                }
            default:
                error("'\(op.rawValue)' does not apply to \(resolved)", target.range)
            }
        }
    }

    // MARK: Expressions

    func type(_ expression: Loa.Expression, expected: ValueType? = nil, root: ValueType? = nil) -> ValueType {
        switch symbol(expression, expected: expected, root: root) {
        case .value(let type):
            return type
        case .page(let name):
            let bindings = pageBindings[name] ?? [:]
            return .record(.init(name, bindings.keys.sorted().map { .init($0, bindings[$0] ?? .any) }))
        case .domain(let domain):
            error("'\(domain.name)' is a domain; call one of its functions", expression.range)
            return .any
        case .function(let domain, let function):
            error("\(domain.name).\(function.name) is a function; call it with (…)", expression.range,
                  note: function.signature(domain: domain.name))
            return .any
        case .builtin(let name):
            error("'\(name)' is a built-in; call it with (…)", expression.range)
            return .any
        case .method(let base, let name):
            error("'\(name)' on \(base) is a method; call it with (…)", expression.range)
            return .any
        }
    }

    func symbol(_ expression: Loa.Expression, expected: ValueType? = nil, root: ValueType? = nil) -> Symbol {
        let range = expression.range
        switch expression.kind {
        case .identifier(let name):
            if let variable = lookup(name) { return .value(variable.type) }
            if pageBindings[name] != nil { return .page(name) }
            if let domain = catalog.domain(named: name) { return .domain(domain) }
            if Self.builtins.contains(name) { return .builtin(name) }
            if Self.globals.contains(name) { return .value(.any) }
            error("Cannot find '\(name)' in scope.\(suggest(name, visibleNames))", range)
            return .value(.any)
        case .string(let literal):
            for case .interpolation(let part) in literal.segments {
                _ = type(part)
            }
            return .value(.string)
        case .number(.integer):
            return .value(.int)
        case .number(.decimal):
            return .value(.double)
        case .boolean:
            return .value(.bool)
        case .null:
            return .value(.null)
        case .implicit_member(let name):
            // A case of the expected type wins (`.severity == .error`); otherwise a key path
            // into the element (`.where(.unread)`); otherwise unknown.
            if let expected, case .cases(let cases) = resolve(unwrapOptional(expected)) {
                if cases.names.contains(name) || root == nil {
                    if !cases.names.contains(name) {
                        error("'.\(name)' is not a case of \(expected) (\(cases.names.map { ".\($0)" }.joined(separator: ", "))).\(suggest(name, cases.names))", range)
                    }
                    return .value(expected)
                }
            }
            if let root {
                return member(of: root, name, at: range)
            }
            return .value(.any)
        case .member(let base, let name):
            switch symbol(base, root: root) {
            case .domain(let domain):
                guard let function = domain.function(named: name) else {
                    error("\(domain.name) has no function '\(name)'.\(suggest(name, domain.functions.map(\.name)))", range)
                    return .value(.any)
                }
                return .function(domain, function)
            case .page(let page):
                guard let binding = pageBindings[page]?[name] else {
                    error("Page '\(page)' has no binding '\(name)'.\(suggest(name, Array((pageBindings[page] ?? [:]).keys)))", range)
                    return .value(.any)
                }
                return .value(binding)
            case .value(let value):
                return member(of: value, name, at: range)
            case .function, .builtin, .method:
                error("'\(name)' needs a value on its left; call the function first", range)
                return .value(.any)
            }
        case .call(let callee, let arguments):
            if case .implicit_member(let name) = callee.kind, root == nil {
                // A case with associated values (`.minutes(30)`) or an enum-style value.
                for argument in arguments { _ = type(argument.value) }
                if let expected, case .cases(let cases) = resolve(unwrapOptional(expected)), !cases.names.contains(name) {
                    error("'.\(name)' is not a case of \(expected).\(suggest(name, cases.names))", callee.range)
                }
                return .value(expected ?? .any)
            }
            switch symbol(callee, root: root) {
            case .function(let domain, let function):
                return .value(call(function, in: domain, arguments, at: range))
            case .builtin(let name):
                return .value(builtin(name, arguments, expected: expected, at: range))
            case .method(let base, let name):
                return .value(method(name, on: base, arguments, at: range))
            case .value(let value):
                for argument in arguments { _ = type(argument.value) }
                if resolve(value) != .any {
                    error("\(value) is not callable", callee.range)
                }
                return .value(.any)
            case .domain(let domain):
                error("'\(domain.name)' is a domain; call one of its functions (\(domain.name).…)", callee.range)
                return .value(.any)
            case .page(let page):
                error("Page '\(page)' cannot be called", callee.range)
                return .value(.any)
            }
        case .subscript(let base, let arguments):
            let baseType = resolve(type(base, root: root))
            let index = arguments.first.map { type($0.value) } ?? .any
            switch baseType {
            case .array(let element):
                if !assignable(index, to: .int) { error("A list index must be int, got \(index)", range) }
                return .value(element)
            case .dictionary(let key, let value):
                if !assignable(index, to: key) { error("A key of \(baseType) must be \(key), got \(index)", range) }
                // Missing keys read as the value type's zero, so counting with `+= 1` works.
                return .value(value)
            case .any:
                return .value(.any)
            default:
                error("\(baseType) cannot be subscripted", range)
                return .value(.any)
            }
        case .object(let fields):
            if let expected, case .record(let record) = resolve(unwrapOptional(expected)) {
                for field in fields {
                    guard let declared = record.field(named: field.name) else {
                        error("\(expected) has no field '\(field.name)'.\(suggest(field.name, record.fields.map(\.name)))", field.value.range)
                        _ = type(field.value)
                        continue
                    }
                    let value = type(field.value, expected: declared.type)
                    if !assignable(value, to: declared.type) {
                        error("Field '\(field.name)' of \(expected) is \(declared.type), got \(value)", field.value.range)
                    }
                }
                for missing in record.fields where !missing.hasDefault && !fields.contains(where: { $0.name == missing.name }) {
                    if case .optional = missing.type { continue }
                    error("Missing field '\(missing.name)' for \(expected)", range)
                }
                return .value(expected)
            }
            return .value(.record(.init(nil, fields.map { .init($0.name, type($0.value)) })))
        case .array(let elements):
            var elementExpected: ValueType?
            if let expected, case .array(let element) = resolve(unwrapOptional(expected)) {
                elementExpected = element
            }
            let types = elements.map { type($0, expected: elementExpected, root: root) }
            if let elementExpected {
                for (element, found) in zip(elements, types) where !assignable(found, to: elementExpected) {
                    error("List element is \(found), expected \(elementExpected)", element.range)
                }
                return .value(.array(elementExpected))
            }
            return .value(.array(types.first(where: { $0 != .any }) ?? .any))
        case .empty_dictionary:
            if let expected, case .dictionary = resolve(unwrapOptional(expected)) { return .value(expected) }
            return .value(.dictionary(.any, .any))
        case .prefix(let op, let operand):
            switch op {
            case .not:
                let value = resolve(type(operand, expected: .bool, root: root))
                if value != .bool && value != .any { error("'!' needs a bool, got \(value)", operand.range) }
                return .value(.bool)
            case .negate:
                let value = type(operand, root: root)
                if !isNumeric(value) { error("'-' needs a number, got \(value)", operand.range) }
                return .value(value)
            case .try:
                return .value(type(operand, expected: expected, root: root))
            }
        case .binary(let op, let lhs, let rhs):
            return .value(binary(op, lhs, rhs, root: root))
        }
    }

    func binary(_ op: Loa.BinaryOperator, _ lhs: Loa.Expression, _ rhs: Loa.Expression, root: ValueType?) -> ValueType {
        switch op {
        case .pipe:
            _ = type(lhs, root: root)
            _ = type(rhs, root: root)
            return .any
        case .coalesce:
            let left = unwrapOptional(type(lhs, root: root))
            let right = type(rhs, expected: left, root: root)
            if !assignable(right, to: left) && resolve(left) != .any {
                error("'??' fallback is \(right), expected \(left)", rhs.range)
            }
            return left == .any ? right : left
        case .or, .and:
            for side in [lhs, rhs] {
                let value = resolve(type(side, expected: .bool, root: root))
                if value != .bool && value != .any { error("'\(op.rawValue)' needs bools, got \(value)", side.range) }
            }
            return .bool
        case .equal, .not_equal, .less, .less_equal, .greater, .greater_equal:
            let left = type(lhs, root: root)
            let right = type(rhs, expected: left, root: root)
            if !assignable(right, to: left) && !assignable(left, to: right) {
                error("Cannot compare \(left) with \(right)", rhs.range)
            }
            return .bool
        case .closed_range, .half_open_range:
            for side in [lhs, rhs] where !assignable(type(side, root: root), to: .int) {
                error("A range needs int bounds", side.range)
            }
            return .array(.int)
        case .add, .subtract, .multiply, .divide, .remainder:
            let left = type(lhs, root: root)
            let right = type(rhs, root: root)
            if op == .add, resolve(left) == .string || resolve(right) == .string {
                if !assignable(right, to: .string) || !assignable(left, to: .string) {
                    error("'+' joins strings only with strings", rhs.range)
                }
                return .string
            }
            for (side, value) in [(lhs, left), (rhs, right)] where !isNumeric(value) {
                error("'\(op.rawValue)' needs numbers, got \(value)", side.range)
            }
            if resolve(left) == .double || resolve(right) == .double { return .double }
            return resolve(left) == .any || resolve(right) == .any ? .any : .int
        }
    }

    // MARK: Members and methods

    static let listMethods = ["where", "map", "first", "last", "only", "contains", "sorted", "unique", "sum", "group"]
    static let stringMethods = ["contains", "has_prefix", "has_suffix", "lowercased", "uppercased", "trimmed", "split"]

    func member(of base: ValueType, _ name: String, at range: Loa.SourceRange) -> Symbol {
        let resolved = resolve(base)
        switch resolved {
        case .any:
            return .value(.any)
        case .optional(let wrapped):
            // Members read through an optional and stay optional.
            switch member(of: wrapped, name, at: range) {
            case .value(let value): return .value(value == .any ? .any : .optional(unwrapOptional(value)))
            case let other: return other
            }
        case .record(let record):
            if let field = record.field(named: name) { return .value(field.type) }
            // Every call result can be inspected for failure instead of stopping the page.
            if name == "failed" { return .value(.bool) }
            if name == "error" { return .value(.optional(.any)) }
            error("\(base) has no field '\(name)'.\(suggest(name, record.fields.map(\.name)))", range)
            return .value(.any)
        case .array:
            switch name {
            case "count": return .value(.int)
            case "is_empty": return .value(.bool)
            case _ where Self.listMethods.contains(name): return .method(resolved, name)
            default:
                error("\(base) has no member '\(name)'.\(suggest(name, Self.listMethods + ["count", "is_empty"]))", range)
                return .value(.any)
            }
        case .dictionary(let key, let value):
            switch name {
            case "count": return .value(.int)
            case "keys": return .value(.array(key))
            case "values": return .value(.array(value))
            case "sorted": return .method(resolved, name)
            default:
                error("\(base) has no member '\(name)'", range)
                return .value(.any)
            }
        case .string:
            if name == "count" { return .value(.int) }
            if Self.stringMethods.contains(name) { return .method(resolved, name) }
            error("string has no member '\(name)'.\(suggest(name, Self.stringMethods + ["count"]))", range)
            return .value(.any)
        default:
            error("\(base) has no member '\(name)'", range)
            return .value(.any)
        }
    }

    func method(_ name: String, on base: ValueType, _ arguments: [Loa.Argument], at range: Loa.SourceRange) -> ValueType {
        func expect(_ labels: [String?], required: Int) -> Bool {
            let given = arguments.map(\.label)
            if given.count < required || given.count > labels.count || zip(given, labels).contains(where: { $0 != $1 }) {
                let shape = labels.enumerated().map { index, label in
                    (label.map { "\($0): …" } ?? "…") + (index >= required ? "?" : "")
                }.joined(separator: ", ")
                error("\(name) takes (\(shape))", range)
                return false
            }
            return true
        }
        switch base {
        case .array(let element):
            switch name {
            case "where":
                guard expect([nil], required: 1) else { return base }
                let condition = resolve(type(arguments[0].value, expected: .bool, root: element))
                if condition != .bool && condition != .any {
                    error("'where' needs a bool condition, got \(condition)", arguments[0].value.range)
                }
                return base
            case "map":
                guard expect([nil], required: 1) else { return .array(.any) }
                return .array(type(arguments[0].value, root: element))
            case "first", "last":
                guard expect([nil], required: 0) else { return .any }
                if let count = arguments.first {
                    if !assignable(type(count.value), to: .int) { error("\(name)(n) needs an int", count.value.range) }
                    return base
                }
                return .optional(element)
            case "only":
                _ = expect([], required: 0)
                return element
            case "contains":
                guard expect([nil], required: 1) else { return .bool }
                _ = type(arguments[0].value, expected: element)
                return .bool
            case "sorted", "unique", "sum", "group":
                let labels: [String?] = name == "sorted" ? ["by", "descending"] : ["by"]
                guard expect(labels, required: 1) else { return .any }
                let key = type(arguments[0].value, root: element)
                if arguments.count > 1, !assignable(type(arguments[1].value), to: .bool) {
                    error("descending needs a bool", arguments[1].value.range)
                }
                switch name {
                case "sum": return key
                case "group": return .dictionary(key, base)
                default: return base
                }
            default:
                return .any
            }
        case .dictionary(let key, let value):
            guard expect(["by", "descending"], required: 1) else { return .any }
            let entry = ValueType.record(.init(nil, [.init("key", key), .init("value", value)]))
            _ = type(arguments[0].value, root: entry)
            return .array(entry)
        case .string:
            switch name {
            case "contains", "has_prefix", "has_suffix":
                guard expect([nil], required: 1) else { return .bool }
                if !assignable(type(arguments[0].value), to: .string) {
                    error("\(name) needs a string", arguments[0].value.range)
                }
                return .bool
            case "split":
                guard expect([nil], required: 1) else { return .array(.string) }
                _ = type(arguments[0].value, expected: .string)
                return .array(.string)
            default:
                _ = expect([], required: 0)
                return .string
            }
        default:
            return .any
        }
    }

    // MARK: Calls

    func call(_ function: Loa.Function, in domain: Loa.Domain, _ arguments: [Loa.Argument], at range: Loa.SourceRange) -> ValueType {
        let qualified = "\(domain.name).\(function.name)"
        let signature = function.signature(domain: domain.name)
        var supplied: Set<String> = []
        var positional = function.parameters.filter { $0.label == nil }[...]
        for argument in arguments {
            let parameter: Loa.Parameter
            if let label = argument.label {
                guard let match = function.parameters.first(where: { $0.label == label }) else {
                    error("\(qualified) has no argument '\(label)'.\(suggest(label, function.parameters.compactMap(\.label)))",
                          argument.value.range, note: signature)
                    _ = type(argument.value)
                    continue
                }
                if !supplied.insert(label).inserted {
                    error("Argument '\(label)' is given twice", argument.value.range)
                }
                parameter = match
            } else {
                guard let next = positional.popFirst() else {
                    error("\(qualified) takes labeled arguments", argument.value.range, note: signature)
                    _ = type(argument.value)
                    continue
                }
                parameter = next
            }
            let value = type(argument.value, expected: parameter.type)
            if !assignable(value, to: parameter.type) {
                let name = parameter.label.map { "'\($0)'" } ?? "the first argument"
                error("Argument \(name) of \(qualified) expects \(parameter.type), got \(value)",
                      argument.value.range, note: signature)
            }
        }
        for parameter in function.parameters where parameter.required {
            if let label = parameter.label, !supplied.contains(label) {
                error("Missing argument '\(label)' for \(qualified)", range, note: signature)
            }
        }
        if !positional.isEmpty, positional.contains(where: \.required) {
            error("Missing a positional argument for \(qualified)", range, note: signature)
        }
        record(qualified, function.effect, at: range)
        return function.result
    }

    func builtin(_ name: String, _ arguments: [Loa.Argument], expected: ValueType?, at range: Loa.SourceRange) -> ValueType {
        let specification: (labels: [String?], effect: Loa.Effect) = switch name {
        case "ask": ([nil, "options", "multiple"], .ask)
        case "suspend": ([nil], .pure)
        case "infer": (["task", "input", "using", "budget"], .infer)
        default: (["agent", "task", "tools", "budget"], .delegate)
        }
        var values: [String: Loa.Expression] = [:]
        for argument in arguments {
            let key = argument.label ?? "_"
            if !specification.labels.contains(argument.label) {
                let names = specification.labels.map { $0 ?? "_" }
                error("\(name) has no argument '\(key)'.\(suggest(key, names))", argument.value.range)
            }
            values[key] = argument.value
        }
        record(name, specification.effect, at: range)
        switch name {
        case "ask":
            if let prompt = values["_"] { _ = type(prompt, expected: .string) } else {
                error("ask needs a question", range)
            }
            guard let options = values["options"] else { return .string }
            let element: ValueType = if case .array(let item) = resolve(type(options)) { item } else { .any }
            if let multiple = values["multiple"], case .boolean(true) = multiple.kind {
                return .array(element)
            }
            return element
        case "infer":
            for (key, value) in values { _ = type(value, expected: key == "task" ? .string : nil) }
            if values["task"] == nil { error("infer needs a task", range) }
            // The result type is the contract: it comes from the binding's annotation.
            return expected ?? .any
        default:
            for value in values.values { _ = type(value) }
            return .any
        }
    }

    func record(_ function: String, _ effect: Loa.Effect, at range: Loa.SourceRange) {
        effects.append(.init(function: function, effect: effect, range: range,
                             page: currentPage, inLoop: loopDepth > 0))
    }

    // MARK: Types

    func valueType(_ expression: Loa.TypeExpression, name: String? = nil, at range: Loa.SourceRange) -> ValueType {
        switch expression {
        case .named(let path):
            let joined = path.joined(separator: ".")
            if let primitive = Self.primitives[joined] { return primitive }
            if programTypes[joined] != nil || catalog.types[joined] != nil { return .named(joined) }
            let known = Array(programTypes.keys) + Array(catalog.types.keys) + Array(Self.primitives.keys)
            error("Unknown type '\(joined)'.\(suggest(joined, known))", range)
            return .any
        case .optional(let wrapped):
            return .optional(valueType(wrapped, at: range))
        case .array(let element):
            return .array(valueType(element, at: range))
        case .dictionary(let key, let value):
            return .dictionary(valueType(key, at: range), valueType(value, at: range))
        case .object(let fields):
            return .record(.init(name, fields.map { field in
                let fieldType = valueType(field.type, at: field.range)
                if let value = field.defaultValue {
                    let found = type(value, expected: fieldType)
                    if !assignable(found, to: fieldType) {
                        error("Default of '\(field.name)' is \(found), expected \(fieldType)", value.range)
                    }
                }
                return .init(field.name, fieldType, hasDefault: field.defaultValue != nil)
            }))
        case .cases(let cases):
            return .cases(.init(name, cases.map(\.name)))
        }
    }

    func resolve(_ type: ValueType) -> ValueType {
        guard case .named(let name) = type else { return type }
        if let declared = programTypes[name], declared != type { return resolve(declared) }
        if let declared = catalog.types[name], declared != type { return resolve(declared) }
        return .any
    }

    func unwrapOptional(_ type: ValueType) -> ValueType {
        if case .optional(let wrapped) = type { return wrapped }
        return type
    }

    func isNumeric(_ type: ValueType) -> Bool {
        [.int, .double, .any].contains(resolve(type))
    }

    func assignable(_ value: ValueType, to target: ValueType) -> Bool {
        if value == target { return true }
        if case .named(let a) = value, case .named(let b) = target { return a == b }
        let from = resolve(value)
        let to = resolve(target)
        switch (from, to) {
        case (.any, _), (_, .any):
            return true
        case (.null, .optional):
            return true
        case (.optional(let a), .optional(let b)):
            return assignable(a, to: b)
        case (_, .optional(let wrapped)):
            return assignable(value, to: wrapped)
        case (.int, .double):
            return true
        case (.array(let a), .array(let b)):
            return assignable(a, to: b)
        case (.dictionary(let ak, let av), .dictionary(let bk, let bv)):
            return assignable(ak, to: bk) && assignable(av, to: bv)
        case (.record(let a), .record(let b)):
            if let left = a.name, let right = b.name { return left == right }
            // An anonymous object fits a record when every field fits and nothing required is missing.
            return a.fields.allSatisfy { field in b.field(named: field.name).map { assignable(field.type, to: $0.type) } ?? false }
                && b.fields.allSatisfy { field in field.hasDefault || a.field(named: field.name) != nil || {
                    if case .optional = field.type { return true } else { return false }
                }() }
        case (.cases(let a), .cases(let b)):
            if let left = a.name, let right = b.name { return left == right }
            return Set(a.names).isSubset(of: Set(b.names))
        default:
            return from == to
        }
    }

    // MARK: Scope and diagnostics

    func lookup(_ name: String) -> Variable? {
        for scope in scopes.reversed() {
            if let variable = scope[name] { return variable }
        }
        return nil
    }

    func declare(_ name: String, type: ValueType, mutable: Bool, at range: Loa.SourceRange) {
        if scopes[scopes.count - 1][name] != nil {
            error("'\(name)' is already declared here", range)
        }
        scopes[scopes.count - 1][name] = Variable(type: type, mutable: mutable)
    }

    var visibleNames: [String] {
        scopes.flatMap(\.keys) + Array(pageBindings.keys) + catalog.domainNames + Self.builtins + Self.globals
    }

    func error(_ message: String, _ range: Loa.SourceRange, note: String? = nil) {
        diagnostics.append(.init(severity: .error, message: message, range: range, note: note))
    }

    /// " Did you mean 'x'?" for the closest candidate, or nothing.
    func suggest(_ name: String, _ candidates: [String]) -> String {
        let scored = candidates.map { ($0, Self.distance(name.lowercased(), $0.lowercased())) }
        guard let best = scored.min(by: { $0.1 < $1.1 }),
              best.1 <= max(1, name.count / 3) else { return "" }
        return " Did you mean '\(best.0)'?"
    }

    /// Edit distance where swapping two adjacent letters counts once (`mial` → `mail`).
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { table[i][0] = i }
        for j in 0...b.count { table[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1, table[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    table[i][j] = min(table[i][j], table[i - 2][j - 2] + 1)
                }
            }
        }
        return table[a.count][b.count]
    }
}

extension Loa.Statement.Kind {
    var keyword: String {
        switch self {
        case .break: "break"
        case .continue: "continue"
        default: "statement"
        }
    }
}
