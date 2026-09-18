import SwiftUI

/// "应用" category (design guide §34): preferences that only affect this app.
struct ApplicationSettingsView: View {
    @AppStorage(AppSettingsKey.showBoardPhoto) private var showBoardPhoto = true
    @AppStorage(AppSettingsKey.hapticsEnabled) private var hapticsEnabled = true
    @AppStorage(AppSettingsKey.keepScreenAwake) private var keepScreenAwake = false
    @AppStorage(AppSettingsKey.restoreLastTab) private var restoreLastTab = false
    @State private var language = AppLanguage.saved

    var body: some View {
        Form {
            Group {
                Section {
                    Toggle(isOn: $showBoardPhoto) {
                        Label("显示面板照片", systemImage: "photo")
                    }
                    Toggle(isOn: $hapticsEnabled) {
                        Label("触感反馈", systemImage: "hand.tap")
                    }
                    Toggle(isOn: $keepScreenAwake) {
                        Label("控制时保持屏幕常亮", systemImage: "sun.max")
                    }
                    Toggle(isOn: $restoreLastTab) {
                        Label("记住上次的标签页", systemImage: "square.on.square")
                    }
                    Picker(selection: $language) {
                        ForEach(AppLanguage.allCases) { option in
                            if let name = option.nativeName {
                                Text(verbatim: name).tag(option)
                            } else {
                                Text("跟随系统").tag(option)
                            }
                        }
                    } label: {
                        Label("语言", systemImage: "globe")
                    }
                    .onChange(of: language) { _, newValue in newValue.save() }
                } footer: {
                    if language.needsRelaunch {
                        Text("重新打开应用后将切换为所选语言。")
                    }
                }
            }
            .rinaTranslucentRows()
        }
        .listSectionSpacing(.compact)
        .rinaScrollBackground()
        .navigationTitle("应用")
    }
}
