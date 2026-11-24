import GrammarParsing
import Parsing
import Position

public extension Loa {
    /// A parse failure with its 1-based line and column when the source is known.
    struct SyntaxFailure: Error, Sendable, CustomStringConvertible {
        public let message: String
        public let offset: Int?
        public var line: Int?
        public var column: Int?

        public init(message: String, offset: Int? = nil) {
            self.message = message
            self.offset = offset
        }

        public var description: String {
            guard let line, let column else { return message }
            return "\(line):\(column): \(message)"
        }

        func located(in source: String) -> Self {
            guard let offset else { return self }
            var failure = self
            let before = source.utf8.prefix(offset)
            let lineStart = before.lastIndex(of: UInt8(ascii: "\n")).map { before.index(after: $0) } ?? before.startIndex
            failure.line = before.filter { $0 == UInt8(ascii: "\n") }.count + 1
            failure.column = String(decoding: before[lineStart...], as: UTF8.self).count + 1
            return failure
        }
    }

    /// The concrete syntax tree of a Loa source, or the first syntax failure.
    static func syntax(_ source: String, filePath: String? = nil) throws -> GrammarParser.Node {
        let parser = try native.get()
        do {
            return try parser.parse(source, filePath: filePath)
        } catch GrammarParser.Failure.syntax(let diagnostic) {
            throw SyntaxFailure(
                message: diagnostic.message,
                offset: diagnostic.utf8Range?.lowerBound.offset
            ).located(in: source)
        } catch GrammarParser.Failure.lexical(let error) {
            throw SyntaxFailure(
                message: error.message,
                offset: error.range.lowerBound.offset
            ).located(in: source)
        }
    }

    private static let native: Result<GrammarParser, any Error> = Result {
        try GrammarParser(language: language())
    }
}
