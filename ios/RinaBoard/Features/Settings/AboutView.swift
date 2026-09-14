import SwiftUI

/// "关于" screen: version, project links and upstream credits.
///
/// Reached from the last section of ``SettingsView``. Every link opens in the
/// system browser; the screen has no board dependency and works offline.
struct AboutView: View {
    private static let repositoryURL = URL(string: "https://github.com/Sager1145/Rina-Chan-board-370-leds")!
    private static let makerWorldURL = URL(string: "https://makerworld.com/zh/models/2569348-rina-chan-board-rina-board-rina-chan-board")!
    private static let flyAkariURL = URL(string: "https://github.com/flyAkari/RinaChanBoard")!
    private static let n738NGXURL = URL(string: "https://github.com/738NGX/RinaChanBoard")!

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let build, !build.isEmpty else { return short }
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("应用") {
                    Text("RinaBoard").foregroundStyle(.secondary)
                }
                LabeledContent("版本") {
                    Text(version)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Link(destination: Self.repositoryURL) {
                    Label("GitHub 项目主页", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: Self.makerWorldURL) {
                    Label("MakerWorld 模型文件", systemImage: "cube")
                }
            } header: {
                Text("项目")
            }

            Section {
                Link(destination: Self.flyAkariURL) {
                    Label("flyAkari / RinaChanBoard", systemImage: "heart")
                }
                Link(destination: Self.n738NGXURL) {
                    Label("738NGX / RinaChanBoard", systemImage: "heart")
                }
            } header: {
                Text("致谢")
            }
        }
        .listSectionSpacing(.compact)
        .rinaScrollBackground()
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}
