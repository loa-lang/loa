/// Loa: a small language in which an agent composes capabilities into programs.
///
/// Literal values (`.{ .field = value }`, `.case`, `.case(value)`, arrays, block strings)
/// are Frame's; Loa adds statements, calls, control flow and pages on top. Names resolve
/// through a catalog the host provides, so this package does not depend on any harness.
public enum Loa {
    /// The file extension of Loa sources.
    public static let fileExtension = "loa"
}
