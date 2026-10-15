import XCTest
@testable import RinaBoard
import RinaCore

@MainActor
final class WatchPresetLocalizationTests: XCTestCase {
    func testSnapshotSendsLocalizedPresetNamesWithTheirOriginalColors() throws {
        let suiteName = "WatchPresetLocalizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let sessions = BoardSessionStore()
        let store = BoardGroupStore(defaults: defaults)
        let coordinator = BoardGroupCoordinator(store: store, sessions: sessions)
        let fanOut = GroupControlFanOut(sessions: sessions, groups: store, coordinator: coordinator)
        let controlCenter = BoardControlCenterModel()
        let rawName = "AZALEA-粉色"
        let presetJSON = ##"{"parents":[{"id":1,"name":"AZALEA-粉色","color":"#ff88cc","desc":""}],"children":{}}"##
        controlCenter.colorPresets = try ColorPresets(jsonData: Data(presetJSON.utf8))
        let cycler = GroupAutoCycler(fanOut: fanOut, faceLibrary: FaceLibraryModel(), intervalProvider: { 3 })
        let service = WatchLinkService(deps: .init(
            sessions: sessions, controlCenter: controlCenter,
            lipSync: LipSyncModel(defaults: defaults), text: TextViewModel(),
            groupStore: store, fanOut: fanOut, groupAutoCycler: cycler,
            groupCoordinator: coordinator, controlTargetStorage: { "" }
        ))

        let swatch = try XCTUnwrap(service.snapshot().controls.presets.first)
        let localizedName = ColorPresets.displayName(rawName)
        XCTAssertNotEqual(localizedName, rawName, "this fixture has a translated spelling in every supported language")
        XCTAssertEqual(swatch.name, localizedName)
        XCTAssertEqual(swatch.hex, "#ff88cc")
    }
}
