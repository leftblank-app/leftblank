import LeftBlankCore

extension TabletWorkspace {
    /// Equations render in their own embedded Tinymist session, never the manuscript's, with the
    /// same fonts and package cache. The session stops after 30 idle seconds to return its memory.
    func makeInlineMathRenderer() -> EngineMathRenderer {
        EngineMathRenderer(typesetter: TinymistMathTypesetter(
            makeTransport: { EmbeddedTinymist() },
            workDirectory: stateDirectory.appendingPathComponent("InlineMath"),
            fontPaths: [EmbeddedTinymist.fontCacheURL],
            packageCache: packageCache,
            idleTimeout: .seconds(30),
        ))
    }
}
