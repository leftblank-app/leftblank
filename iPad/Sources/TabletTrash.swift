import LeftBlankCore

extension TabletWorkspace {
    /// Delete only the exact trash generation that the user confirmed.
    func emptyTrash(_ snapshot: LibraryTrashSnapshot) async {
        guard !busy else {
            return
        }
        busy = true
        defer { busy = false }
        do {
            let result = try await library.emptyTrash(snapshot)
            try await reloadLibrary()
            trashedDocuments = try await library.list(includeTrashed: true).filter(\.isTrashed)
            if !result.issues.isEmpty {
                message = result.issues.map(\.message).joined(separator: "\n")
            }
        } catch { message = error.localizedDescription }
    }
}
