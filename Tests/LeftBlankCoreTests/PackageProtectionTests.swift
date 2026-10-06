import Foundation
import LeftBlankCore
import LeftBlankTestSupport
import Testing

@Test func packageWritesRejectAliasesButAllowProjectSourcesAndCopies() throws {
    let manager = FileManager.default
    let root = TestPaths.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? manager.removeItem(at: root) }
    let cache = root.appendingPathComponent("PackageCache")
    let package = cache.appendingPathComponent("preview/example/1.0.0/lib.typ")
    try manager.createDirectory(at: package.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#let original = 1".utf8).write(to: package)
    let alias = root.appendingPathComponent("library.typ")
    try manager.createSymbolicLink(at: alias, withDestinationURL: package)
    let directoryAlias = root.appendingPathComponent("dependencies")
    try manager.createSymbolicLink(at: directoryAlias, withDestinationURL: cache)
    let source = try DocumentStorage.read(package)
    for target in [package, alias, directoryAlias.appendingPathComponent("preview/example/1.0.0/lib.typ")] {
        #expect(PackageSource.isReadOnly(target, packageCache: cache))
        #expect(throws: DocumentStorageError.self) {
            try DocumentStorage.write("overwritten", to: target, baseline: nil, packageCache: cache)
        }
    }
    #expect(try DocumentStorage.read(package).0 == source.0)
    let project = root.appendingPathComponent("PackageCache-project")
    try manager.createDirectory(at: project, withIntermediateDirectories: true)
    try Data("[package]".utf8).write(to: project.appendingPathComponent("typst.toml"))
    let editable = project.appendingPathComponent("lib.typ")
    #expect(!PackageSource.isReadOnly(editable, packageCache: cache))
    _ = try DocumentStorage.write(source.0, to: editable, baseline: nil, packageCache: cache)
    #expect(try DocumentStorage.read(editable).0 == source.0)
}

@Test func bundledPackagesRepairCorruptionAndPreserveBackup() throws {
    let manager = FileManager.default
    let root = TestPaths.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? manager.removeItem(at: root) }
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let resources = repo.appendingPathComponent("Resources/Packages")
    let cache = root.appendingPathComponent("PackageCache")
    try BundledPackages.prepare(in: cache, resources: resources)
    let package = cache.appendingPathComponent("preview/cetz/0.5.2")
    let shapes = package.appendingPathComponent("src/draw/shapes.typ")
    let anchor = package.appendingPathComponent("src/anchor.typ")
    let originalDate = try shapes.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    try BundledPackages.prepare(in: cache, resources: resources)
    #expect(try shapes.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == originalDate)
    #expect(!manager.fileExists(atPath: root.appendingPathComponent("PackageBackups").path))

    try Data("= My drawing".utf8).write(to: shapes)
    try Data().write(to: anchor)
    try manager.removeItem(at: package.appendingPathComponent("src/canvas.typ"))
    let extra = package.appendingPathComponent("draft.typ")
    try Data("unsaved work".utf8).write(to: extra)
    let other = cache.appendingPathComponent("preview/custom/1.0.0/lib.typ")
    try manager.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("custom".utf8).write(to: other)

    try BundledPackages.prepare(in: cache, resources: resources)
    #expect(manager.contentsEqual(
        atPath: package.path,
        andPath: resources.appendingPathComponent("preview/cetz/0.5.2").path,
    ))
    let backups = try manager.contentsOfDirectory(
        at: root.appendingPathComponent("PackageBackups"),
        includingPropertiesForKeys: nil,
    )
    #expect(backups.count == 1)
    let backup = try #require(backups.first).appendingPathComponent("preview/cetz/0.5.2")
    #expect(try String(contentsOf: backup.appendingPathComponent("src/draw/shapes.typ"), encoding: .utf8) ==
        "= My drawing")
    #expect(try Data(contentsOf: backup.appendingPathComponent("src/anchor.typ")).isEmpty)
    #expect(try String(contentsOf: backup.appendingPathComponent("draft.typ"), encoding: .utf8) == "unsaved work")
    #expect(try String(contentsOf: other, encoding: .utf8) == "custom")
    try BundledPackages.prepare(in: cache, resources: resources)
    #expect(try manager.contentsOfDirectory(atPath: root.appendingPathComponent("PackageBackups").path).count == 1)
}
