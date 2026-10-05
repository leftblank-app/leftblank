import Foundation
import LeftBlankCore

extension TabletWorkspace {
    func schedulePreviewFollow() {
        previewFollowTask?.cancel()
        guard previewReading.followsWriting, layout == .split, panel == nil,
              !busy, editor?.markedTextRange == nil
        else {
            return
        }
        let session = generation
        previewFollowTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self, session == generation, previewReading.followsWriting,
                  layout == .split, panel == nil, !busy, editor?.markedTextRange == nil,
                  serviceReady, let sourceURL
            else {
                return
            }
            assistance.pendingPreview = .init(
                source: text,
                url: sourceURL,
                version: version,
                generation: generation,
                selection: selection,
            )
            followingPreviewNavigation = true
            sendPendingPreviewNavigation()
        }
    }
}
