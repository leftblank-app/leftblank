import LeftBlankCore
import SwiftUI

@main
struct LeftBlankApp: App {
    var body: some Scene {
        WindowGroup(id: "writing") {
            TabletScene()
        }
    }
}

private struct TabletScene: View {
    @SceneStorage("writingSession") private var sessionID = UUID().uuidString

    var body: some View {
        TabletSession(sessionID: UUID(uuidString: sessionID) ?? UUID()).id(sessionID)
    }
}

private struct TabletSession: View {
    @StateObject private var state: TabletSessionState
    @Environment(\.scenePhase) private var phase

    init(sessionID: UUID) {
        _state = StateObject(wrappedValue: TabletSessionState(sessionID: sessionID))
    }

    var body: some View {
        TabletRoot(workspace: state.workspace)
            .task {
                await state.workspace.start()
                await state.observer.start()
            }
            .task { await state.workspace.subscription.start() }
            .onOpenURL { url in Task { await state.workspace.importDocument(url) } }
            .onChange(of: state.workspace.cloudEnabled) { _, _ in
                Task { await state.observer.start() }
            }
            .onChange(of: phase) { _, phase in
                if phase == .active {
                    Task {
                        await state.workspace.subscription.refresh()
                        await state.workspace.refreshFromLibrary()
                        if state.workspace.document != nil, !state.workspace.serviceReady, !state.workspace.busy {
                            await state.workspace.connect()
                        }
                    }
                } else {
                    state.workspace.saveInBackground()
                }
            }
    }
}

@MainActor
private final class TabletSessionState: ObservableObject {
    let workspace: TabletWorkspace
    let observer: TabletLibraryObserver

    init(sessionID: UUID) {
        workspace = TabletWorkspace(sessionID: sessionID)
        observer = TabletLibraryObserver(workspace: workspace)
    }
}
