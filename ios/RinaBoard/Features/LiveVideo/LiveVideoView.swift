import SwiftUI
import RinaCore

/// Live Video tab (design guide §30).
///
/// Intentionally a placeholder: a non-interactive board preview, nothing
/// else. No camera controls, capture controls or streaming settings are
/// present, so the UI never implies a pipeline that does not yet
/// exist — while the feature stays structurally ready.
struct LiveVideoView: View {
    @Environment(BoardConnection.self) private var connection

    var body: some View {
        NavigationStack {
            List {
                Section {
                    BoardPreviewRow(
                        frame: connection.currentFrame,
                        accessibilityDescription: NSLocalizedString("实时视频预览占位",
                                                                    comment: "live video placeholder preview")
                    )
                }

                Section {
                    ContentUnavailableView("实时视频",
                                           systemImage: "video.slash",
                                           description: Text("即将推出。"))
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .contentMargins(.top, 0, for: .scrollContent)
        }
    }
}
