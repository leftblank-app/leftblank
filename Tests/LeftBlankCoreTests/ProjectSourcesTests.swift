import Foundation
@testable import LeftBlankCore
import LeftBlankTestSupport
import Testing

private func projectSourceFixture() throws -> URL {
    let root = TestPaths.temporaryDirectory.appendingPathComponent("project-sources-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func projectSourcesBrowseNestedFilesAndRejectEscapes() throws {
    let root = try projectSourceFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("Book")
    let chapter = project.appendingPathComponent("chapters/intro.typ")
    try FileManager.default.createDirectory(at: chapter.deletingLastPathComponent(), withIntermediateDirectories: true)
    let entry = project.appendingPathComponent("book.typ")
    let outside = root.appendingPathComponent("private.typ")
    try Data("#include \"chapters/intro.typ\"".utf8).write(to: entry)
    try Data("= Introduction".utf8).write(to: chapter)
    try Data("private".utf8).write(to: outside)
    try Data("image".utf8).write(to: project.appendingPathComponent("image.png"))
    let linked = project.appendingPathComponent("linked.typ")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
    #expect(try ProjectSources.list(in: project).map(\.lastPathComponent) == ["book.typ", "intro.typ"])
    #expect(try ProjectSources.relativePath(of: chapter, in: project) == "chapters/intro.typ")
    #expect(throws: LibraryError.self) { try ProjectSources.relativePath(of: outside, in: project) }
    #expect(throws: LibraryError.self) { try ProjectSources.relativePath(of: linked, in: project) }
    #expect(throws: LibraryError.self) {
        try ProjectSources.relativePath(of: project.appendingPathComponent("image.png"), in: project)
    }
}

@Test func importedNonMainEntryAndIncludedHistoryStayIndependent() async throws {
    let root = try projectSourceFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("Book")
    let chapter = project.appendingPathComponent("chapters/intro.typ")
    try FileManager.default.createDirectory(at: chapter.deletingLastPathComponent(), withIntermediateDirectories: true)
    let entry = project.appendingPathComponent("book.typ")
    let main = "#include \"chapters/intro.typ\""
    try Data(main.utf8).write(to: entry)
    try Data("= Introduction".utf8).write(to: chapter)
    let library = DocumentLibrary(rootURL: root.appendingPathComponent("Library"))
    let item = try await library.importProject(at: project, mainFile: entry)
    let included = item.sourceURL.deletingLastPathComponent().appendingPathComponent("chapters/intro.typ")
    let (source, baseline) = try DocumentStorage.read(included)
    _ = try DocumentStorage.write("= Edited chapter", to: included, baseline: baseline)
    #expect(try await library.read(item.id).text == main)
    let entryKey = try ProjectSources.historyKey(
        documentID: item.id, source: item.sourceURL, entry: item.sourceURL, root: item.folderURL,
    )
    let chapterKey = try ProjectSources.historyKey(
        documentID: item.id, source: included, entry: item.sourceURL, root: item.folderURL,
    )
    #expect(entryKey == item.id.uuidString)
    #expect(chapterKey != entryKey)
    let history = DocumentHistory(root: root.appendingPathComponent("History"))
    let revision = try await history.preserveBeforeRestore(source, key: chapterKey, at: Date())
    #expect(try await history.revisions(for: entryKey).isEmpty)
    #expect(try await history.source(for: revision, key: chapterKey) == "= Introduction")
    #expect(throws: DocumentStorageError.self) {
        try DocumentStorage.write("stale editor", to: included, baseline: baseline)
    }
    #expect(try DocumentStorage.read(included).0 == "= Edited chapter")
}

@Test func recoveryProjectCopyRetainsActiveChapterAndAssets() async throws {
    let root = try projectSourceFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("Book")
    let chapter = project.appendingPathComponent("chapters/intro.typ")
    try FileManager.default.createDirectory(at: chapter.deletingLastPathComponent(), withIntermediateDirectories: true)
    let entry = project.appendingPathComponent("book.typ")
    try Data("#include \"chapters/intro.typ\"".utf8).write(to: entry)
    try Data("old".utf8).write(to: chapter)
    try Data("image data".utf8).write(to: project.appendingPathComponent("figure.png"))
    let library = DocumentLibrary(rootURL: root.appendingPathComponent("Library"))
    let original = try await library.importProject(at: project, mainFile: entry)
    let active = original.sourceURL.deletingLastPathComponent().appendingPathComponent("chapters/intro.typ")
    let relative = try ProjectSources.relativePath(of: active, in: original.folderURL)
    let recovered = try await library.importProject(
        at: original.folderURL, mainFile: original.sourceURL, title: "Recovered",
    )
    let recoveredSource = recovered.folderURL.appendingPathComponent("Project").appendingPathComponent(relative)
    _ = try DocumentStorage.write(
        "unsaved draft",
        to: recoveredSource,
        baseline: DocumentStorage.read(recoveredSource).1,
    )
    #expect(try DocumentStorage.read(recoveredSource).0 == "unsaved draft")
    #expect(try DocumentStorage.read(active).0 == "old")
    #expect(
        try Data(contentsOf: recovered.sourceURL.deletingLastPathComponent().appendingPathComponent("figure.png")) ==
            Data("image data".utf8),
    )
}
