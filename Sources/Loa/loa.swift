import Position

/// Loa: a small language in which an agent composes capabilities into programs.
///
/// Literal values (`.{ .field = value }`, `.case`, `.case(value)`, arrays, block strings)
/// are Frame's; Loa adds statements, calls, control flow and pages on top. Names resolve
/// through a catalog the host provides, so this package does not depend on any harness.
public enum Loa {
    /// The file extension of Loa sources.
    public static let fileExtension = "loa"

    /// The 1-based line and character column of a UTF-8 offset, or nil when the offset is
    /// not a character boundary in the mapped source.
    static func location(of offset: Int, in map: Position.TextMap) -> Position.Coordinate<Position.Unit.Character>? {
        guard let utf8 = try? Position.Offset<Position.Unit.UTF8>(offset),
              let coordinate = try? map.coordinate(at: utf8) else {
            return nil
        }
        return try? map.convert(coordinate, to: Position.Unit.Character.self)
    }
}
