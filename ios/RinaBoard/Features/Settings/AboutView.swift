import SwiftUI

/// "关于" screen: version, project links, and every open-source project the
/// app and firmware build on.
///
/// Reached from the 关于 category of ``SettingsView``. Every link opens in the
/// system browser; the screen has no board dependency and works offline.
struct AboutView: View {
    private static let repositoryURL = URL(string: "https://github.com/Sager1145/Rina-Chan-board-370-leds")!
    private static let makerWorldURL = URL(string: "https://makerworld.com/zh/models/2569348-rina-chan-board-rina-board-rina-chan-board")!

    /// One open-source project this app or its firmware builds on. Names and
    /// licence identifiers are proper nouns, shown verbatim in every language.
    private struct Credit: Identifiable {
        let name: String
        let license: String
        let url: URL
        var id: String { name }

        init(_ name: String, _ license: String, _ url: String) {
            self.name = name
            self.license = license
            self.url = URL(string: url)!
        }
    }

    private struct CreditGroup: Identifiable {
        let title: LocalizedStringKey
        var footer: LocalizedStringKey?
        let credits: [Credit]
        var id: String { credits.map(\.name).joined() }
    }

    /// Every third-party project in the tree: the app links no remote Swift
    /// packages, so this is the two upstream boards, the bundled fonts, and
    /// `esp32s3_firmware/platformio.ini`'s platform and `lib_deps`. Keep in
    /// step with README §14.
    private static let creditGroups: [CreditGroup] = [
        CreditGroup(title: "致谢",
                    footer: "口型同步与预设 Live 分别参照 738NGX 与 flyAkari 的实现，用 Swift 重新编写。",
                    credits: [
            Credit("flyAkari / RinaChanBoard", "GPL-3.0", "https://github.com/flyAkari/RinaChanBoard"),
            Credit("738NGX / RinaChanBoard", "AGPL-3.0", "https://github.com/738NGX/RinaChanBoard"),
            Credit("hecomi / uLipSync", "MIT", "https://github.com/hecomi/uLipSync")
        ]),
        CreditGroup(title: "字体", credits: [
            Credit("Ark Pixel Font（方舟像素字体）", "SIL OFL 1.1", "https://github.com/TakWolf/ark-pixel-font"),
            Credit("GNU Unifont", "SIL OFL 1.1", "https://unifoundry.com/unifont/")
        ]),
        CreditGroup(title: "固件", credits: [
            Credit("Arduino core for ESP32", "LGPL-2.1", "https://github.com/espressif/arduino-esp32"),
            Credit("ESP-IDF", "Apache-2.0", "https://github.com/espressif/esp-idf"),
            Credit("NimBLE-Arduino", "Apache-2.0", "https://github.com/h2zero/NimBLE-Arduino"),
            Credit("ArduinoJson", "MIT", "https://github.com/bblanchon/ArduinoJson"),
            Credit("Adafruit NeoPixel", "LGPL-3.0", "https://github.com/adafruit/Adafruit_NeoPixel")
        ]),
        CreditGroup(title: "构建工具", credits: [
            Credit("PlatformIO", "Apache-2.0", "https://github.com/platformio/platformio-core"),
            Credit("pioarduino platform-espressif32", "Apache-2.0", "https://github.com/pioarduino/platform-espressif32"),
            Credit("NumPy", "BSD-3-Clause", "https://github.com/numpy/numpy")
        ])
    ]

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let build, !build.isEmpty else { return short }
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Group {
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

                ForEach(Self.creditGroups) { group in
                    Section {
                        ForEach(group.credits) { credit in
                            Link(destination: credit.url) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: credit.name)
                                    Text(verbatim: credit.license)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text(group.title)
                    } footer: {
                        if let footer = group.footer { Text(footer) }
                    }
                }

                Section {
                } footer: {
                    Text("《LoveLive!》相关名称、角色与音乐归各自权利人所有，不属于上述开源许可的范围。本项目是爱好者作品，与官方无关。")
                }
            }
            .rinaTranslucentRows()
        }
        .listSectionSpacing(.compact)
        .rinaScrollBackground()
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}
