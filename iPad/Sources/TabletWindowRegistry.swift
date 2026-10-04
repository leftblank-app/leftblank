import Foundation
import LeftBlankCore

/// Windows share history serialization, but keep editor and engine state separate.
@MainActor
enum TabletWindowRegistry {
    private final class Reference {
        weak var workspace: TabletWorkspace?
        init(_ workspace: TabletWorkspace) {
            self.workspace = workspace
        }
    }

    private static var references: [Reference] = []

    static func windows(in directory: URL) -> [TabletWorkspace] {
        references.removeAll { $0.workspace == nil }
        return references.compactMap(\.workspace).filter {
            $0.stateDirectory.standardizedFileURL == directory.standardizedFileURL
        }
    }

    static func register(_ workspace: TabletWorkspace) {
        references.removeAll { $0.workspace == nil }
        references.append(Reference(workspace))
    }
}
