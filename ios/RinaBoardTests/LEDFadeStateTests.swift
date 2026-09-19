import XCTest
@testable import RinaBoard
@testable import RinaCore

/// The preview's light-up / fade-out: a fade retargeted half-way carries on from the level it had reached.
final class LEDFadeStateTests: XCTestCase {
    private func frame(lit: [Int]) -> PackedFrame {
        var frame = PackedFrame()
        for led in lit { frame[led] = true }
        return frame
    }

    func testEditFadesInAndFinishes() {
        let fader = LEDFadeState()
        fader.noteEdit(at: 100)
        XCTAssertNotNil(fader.retarget(from: frame(lit: []), to: frame(lit: [5]), at: 100, animated: true))
        XCTAssertEqual(fader.levels(at: 100)[5], 0)
        let half = fader.levels(at: 100 + LEDFadeState.onDuration / 2)[5]
        XCTAssertEqual(half ?? -1, 0.5, accuracy: 0.001)
        XCTAssertTrue(fader.levels(at: 100 + LEDFadeState.onDuration).isEmpty)
    }

    func testInterruptedFadeContinuesFromItsLevel() {
        let fader = LEDFadeState()
        let on = frame(lit: [5]), off = frame(lit: [])
        fader.noteEdit(at: 100)
        _ = fader.retarget(from: off, to: on, at: 100, animated: true)
        let turn = 100 + LEDFadeState.onDuration / 2
        let before = fader.levels(at: turn)[5]
        fader.noteEdit(at: turn)
        _ = fader.retarget(from: on, to: off, at: turn, animated: true)
        XCTAssertEqual(fader.levels(at: turn)[5] ?? -1, before ?? -2, accuracy: 0.001)
        // Half lit, so going out takes half the fade-out time.
        XCTAssertTrue(fader.levels(at: turn + LEDFadeState.offDuration / 2).isEmpty)
        XCTAssertNotNil(fader.levels(at: turn + LEDFadeState.offDuration / 4)[5])
    }

    func testChangeWithoutATouchFadesFaster() {
        let fader = LEDFadeState()
        _ = fader.retarget(from: frame(lit: []), to: frame(lit: [5]), at: 100, animated: true)
        let bulkDuration = LEDFadeState.onDuration / LEDFadeState.bulkSpeed
        XCTAssertEqual(fader.levels(at: 100 + bulkDuration / 2)[5] ?? -1, 0.5, accuracy: 0.001)
        XCTAssertTrue(fader.levels(at: 100 + bulkDuration + 0.001).isEmpty)
    }

    func testUnanimatedChangeIsShownAtOnceAndDropsFadesInFlight() {
        let fader = LEDFadeState()
        _ = fader.retarget(from: frame(lit: []), to: frame(lit: [1, 2, 3]), at: 100, animated: true)
        XCTAssertEqual(fader.levels(at: 100).count, 3)
        XCTAssertNil(fader.retarget(from: frame(lit: []), to: frame(lit: [1]), at: 100.01, animated: false))
        XCTAssertTrue(fader.levels(at: 100.01).isEmpty)
    }
}
